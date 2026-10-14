// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title LCRD Credit Line
/// @notice A USDC lending pool with credit lines priced on-chain from an LCRD credit score.
///
/// Lenders deposit USDC and receive pool shares. LCRD scores a borrower off-chain
/// (0-100, from their financial activity). The underwriter submits that score and
/// the hash of the score report; the contract itself derives the risk tier, the
/// APR and the maximum line from LCRD's published policy, so every price can be
/// checked by anyone with `quote`. Only the report hash is stored, never personal
/// data. Borrowers draw and repay in USDC; interest accrues by the second and,
/// once repaid, raises the value of every share. A written-off line lowers it.
///
/// Pricing (LCRD policy 2026-10, unsecured credit), in basis points:
///   APR = 800 cost of funds
///       + score premium, sliding linearly from 2000 at score 0 to 300 at score 100
///       + 300 unsecured surcharge
///   clamped to [600, 3600].
/// Tiers: A = score 67-100, B = 34-66, C = 0-33. Unsecured lines are for tiers A
/// and B only and start small: 100 USDC (A) and 75 USDC (B).
///
/// Repayment history is recorded on-chain per borrower and rewarded:
///   - a cycle is completed when a loan that used at least 25% of the line and ran
///     at least 7 days is repaid in full (so dust loans cannot farm it);
///   - each completed cycle takes 50 bps off the APR (up to 200 bps after 4 cycles),
///     applied automatically when the cycle completes;
///   - each completed cycle raises the tier's maximum line by one starter amount, up
///     to 2,500 USDC (A) and 250 USDC (B);
///   - a write-off resets completed cycles to zero.
contract CreditLine {
    // ---------------------------------------------------------------- types --

    struct Line {
        uint128 limit; // max principal outstanding, in USDC base units
        uint128 principal; // principal outstanding
        uint128 interest; // interest accrued and not yet repaid
        uint32 aprBps; // simple annual rate, basis points, derived from the score
        uint8 tier; // LCRD risk tier: 1 = A, 2 = B, 3 = C
        uint8 score; // LCRD credit score, 0-100
        bool active; // can draw; repayments are always accepted
        uint64 lastAccrued; // timestamp of the last accrual
        bytes32 scoreRef; // hash of the off-chain score report backing this line
    }

    /// Repayment record, per borrower. Survives line updates; reset only by a write-off.
    struct History {
        uint32 repayments; // number of repayments made
        uint32 cyclesCompleted; // qualifying loans repaid in full (see contract notes)
        uint32 writeOffs; // lines written off
        uint64 firstBorrowAt; // first ever draw
        uint64 lastRepaidAt; // most recent repayment
        uint64 cycleStart; // when the current loan started (0 = no open loan)
        uint128 cyclePeak; // largest principal during the current loan
        uint128 totalBorrowed; // lifetime principal drawn
        uint128 totalRepaid; // lifetime principal + interest repaid
    }

    // ------------------------------------------------------------- storage --

    IERC20 public immutable usdc;

    address public owner;
    address public pendingOwner;
    address public underwriter;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    uint256 public totalPrincipal; // sum of principal across lines
    uint256 public totalRepaidInterest; // lifetime interest repaid to the pool
    uint256 public totalWrittenOff; // lifetime principal written off

    mapping(address => Line) public lines;
    mapping(address => History) public history;
    address[] public borrowers;

    uint256 private constant YEAR = 365 days;

    // ---- LCRD pricing policy (fixed in code, so it can be verified) ----
    string public constant POLICY_VERSION = "lcrd-unsecured-2026-10";
    uint256 public constant BASE_BPS = 800; // cost of funds
    uint256 public constant PREMIUM_AT_0_BPS = 2_000; // score-risk premium at score 0
    uint256 public constant PREMIUM_AT_100_BPS = 300; // ... and at score 100
    uint256 public constant UNSECURED_SURCHARGE_BPS = 300;
    uint256 public constant MIN_APR_BPS = 600;
    uint256 public constant MAX_APR_BPS = 3_600;
    uint8 public constant TIER_A_MIN_SCORE = 67;
    uint8 public constant TIER_B_MIN_SCORE = 34;
    uint256 public constant TIER_A_MAX_LIMIT = 100e6; // 100 USDC
    uint256 public constant TIER_B_MAX_LIMIT = 75e6; // 75 USDC
    uint256 public constant TIER_A_CEILING = 2_500e6; // line ceiling reachable through repayments
    uint256 public constant TIER_B_CEILING = 250e6;
    uint256 public constant CYCLE_DISCOUNT_BPS = 50; // APR reduction per completed cycle
    uint256 public constant MAX_CYCLE_DISCOUNT_BPS = 200;
    uint256 public constant CYCLE_MIN_DURATION = 7 days;
    uint256 public constant CYCLE_MIN_USE_DIVISOR = 4; // must draw at least limit / 4
    // Virtual shares and assets blunt the first-depositor share inflation attack.
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;

    uint256 private locked = 1;

    // -------------------------------------------------------------- events --

    event Deposited(address indexed lender, uint256 assets, uint256 shares);
    event Withdrawn(address indexed lender, uint256 assets, uint256 shares);
    event LineSet(address indexed borrower, uint256 limit, uint8 score, uint8 tier, uint256 aprBps, bytes32 scoreRef);
    event LineFrozen(address indexed borrower);
    event Borrowed(address indexed borrower, uint256 amount);
    event Repaid(address indexed borrower, address indexed payer, uint256 interestPaid, uint256 principalPaid);
    event WrittenOff(address indexed borrower, uint256 principal, uint256 interest);
    event CycleCompleted(address indexed borrower, uint32 cyclesCompleted, uint256 newAprBps);
    event UnderwriterChanged(address indexed underwriter);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // -------------------------------------------------------------- errors --

    error NotOwner();
    error NotUnderwriter();
    error NotPendingOwner();
    error Reentrancy();
    error ZeroAmount();
    error ZeroAddress();
    error BadScore();
    error TierNotEligible();
    error LineInactive();
    error OverLimit();
    error InsufficientLiquidity();
    error InsufficientShares();
    error NothingOwed();
    error TransferFailed();

    // ----------------------------------------------------------- modifiers --

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyUnderwriter() {
        if (msg.sender != underwriter) revert NotUnderwriter();
        _;
    }

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    constructor(IERC20 usdc_, address underwriter_) {
        if (address(usdc_) == address(0) || underwriter_ == address(0)) revert ZeroAddress();
        usdc = usdc_;
        owner = msg.sender;
        underwriter = underwriter_;
        emit OwnershipTransferred(address(0), msg.sender);
        emit UnderwriterChanged(underwriter_);
    }

    // --------------------------------------------------------- pool views --

    /// @notice USDC held by the pool and available to lend or withdraw.
    function cash() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @notice What the pool is worth to lenders: cash plus principal still out.
    /// Accrued but unpaid interest is not counted until it is actually repaid.
    function totalAssets() public view returns (uint256) {
        return cash() + totalPrincipal;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets * (totalShares + VIRTUAL_SHARES) / (totalAssets() + VIRTUAL_ASSETS);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * (totalAssets() + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES);
    }

    function borrowerCount() external view returns (uint256) {
        return borrowers.length;
    }

    /// @notice Principal plus interest owed right now, including interest not yet accrued in storage.
    function owed(address borrower) public view returns (uint256 principal, uint256 interest) {
        Line memory l = lines[borrower];
        return (l.principal, l.interest + _pending(l));
    }

    /// @notice How much the borrower can draw right now.
    function available(address borrower) external view returns (uint256) {
        Line memory l = lines[borrower];
        if (!l.active || l.principal >= l.limit) return 0;
        uint256 room = l.limit - l.principal;
        uint256 c = cash();
        return room < c ? room : c;
    }

    // ------------------------------------------------------------ lenders --

    function deposit(uint256 assets) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        shares = convertToShares(assets);
        if (shares == 0) revert ZeroAmount();
        _pull(msg.sender, assets);
        totalShares += shares;
        sharesOf[msg.sender] += shares;
        emit Deposited(msg.sender, assets, shares);
    }

    function withdraw(uint256 shares) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        if (sharesOf[msg.sender] < shares) revert InsufficientShares();
        assets = convertToAssets(shares);
        if (assets > cash()) revert InsufficientLiquidity();
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        _push(msg.sender, assets);
        emit Withdrawn(msg.sender, assets, shares);
    }

    // -------------------------------------------------------- underwriting --

    /// @notice LCRD's price for a score and a repayment record: the risk tier, the APR and the
    /// largest unsecured line. Tier C gets no unsecured line (maxLimit 0).
    function quote(uint8 score, uint32 cyclesCompleted) public pure returns (uint8 tier, uint32 aprBps, uint256 maxLimit) {
        if (score > 100) revert BadScore();
        uint256 starter;
        uint256 ceiling;
        if (score >= TIER_A_MIN_SCORE) (tier, starter, ceiling) = (1, TIER_A_MAX_LIMIT, TIER_A_CEILING);
        else if (score >= TIER_B_MIN_SCORE) (tier, starter, ceiling) = (2, TIER_B_MAX_LIMIT, TIER_B_CEILING);
        else tier = 3;
        maxLimit = starter * (1 + uint256(cyclesCompleted));
        if (maxLimit > ceiling) maxLimit = ceiling;

        uint256 premium = PREMIUM_AT_0_BPS - (PREMIUM_AT_0_BPS - PREMIUM_AT_100_BPS) * score / 100;
        uint256 discount = uint256(cyclesCompleted) * CYCLE_DISCOUNT_BPS;
        if (discount > MAX_CYCLE_DISCOUNT_BPS) discount = MAX_CYCLE_DISCOUNT_BPS;
        uint256 apr = BASE_BPS + premium + UNSECURED_SURCHARGE_BPS;
        apr = apr > discount ? apr - discount : 0;
        if (apr < MIN_APR_BPS) apr = MIN_APR_BPS;
        if (apr > MAX_APR_BPS) apr = MAX_APR_BPS;
        aprBps = uint32(apr);
    }

    /// @notice Open or update a borrower's line from their LCRD score. The contract derives the
    /// tier and APR and caps the limit by tier. Accrues interest at the old rate first.
    /// @param score LCRD credit score, 0-100.
    /// @param limit Requested line; must not exceed the tier's maximum.
    /// @param scoreRef keccak256 of the off-chain LCRD score report (no personal data on-chain).
    function setLine(address borrower, uint8 score, uint128 limit, bytes32 scoreRef) external onlyUnderwriter {
        if (borrower == address(0)) revert ZeroAddress();
        (uint8 tier, uint32 aprBps, uint256 maxLimit) = quote(score, history[borrower].cyclesCompleted);
        if (maxLimit == 0) revert TierNotEligible();
        if (limit > maxLimit) revert OverLimit();
        Line storage l = lines[borrower];
        if (l.lastAccrued == 0) {
            borrowers.push(borrower);
            l.lastAccrued = uint64(block.timestamp);
        } else {
            _accrue(l);
        }
        l.limit = limit;
        l.aprBps = aprBps;
        l.tier = tier;
        l.score = score;
        l.scoreRef = scoreRef;
        l.active = true;
        emit LineSet(borrower, limit, score, tier, aprBps, scoreRef);
    }

    /// @notice Stop new draws. Repayments stay open.
    function freeze(address borrower) external onlyUnderwriter {
        Line storage l = lines[borrower];
        _accrue(l);
        l.active = false;
        emit LineFrozen(borrower);
    }

    /// @notice Recognise a line as lost. Its principal leaves the pool's assets, so lenders bear the loss.
    function writeOff(address borrower) external onlyUnderwriter {
        Line storage l = lines[borrower];
        _accrue(l);
        uint256 principal = l.principal;
        uint256 interest = l.interest;
        if (principal == 0 && interest == 0) revert NothingOwed();
        totalPrincipal -= principal;
        totalWrittenOff += principal;
        l.principal = 0;
        l.interest = 0;
        l.active = false;
        History storage h = history[borrower];
        h.writeOffs += 1;
        h.cyclesCompleted = 0;
        h.cycleStart = 0;
        h.cyclePeak = 0;
        emit WrittenOff(borrower, principal, interest);
    }

    // ---------------------------------------------------------- borrowers --

    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Line storage l = lines[msg.sender];
        if (!l.active) revert LineInactive();
        _accrue(l);
        if (uint256(l.principal) + amount > l.limit) revert OverLimit();
        if (amount > cash()) revert InsufficientLiquidity();
        History storage h = history[msg.sender];
        if (h.firstBorrowAt == 0) h.firstBorrowAt = uint64(block.timestamp);
        if (h.cycleStart == 0) h.cycleStart = uint64(block.timestamp);
        l.principal += uint128(amount);
        if (l.principal > h.cyclePeak) h.cyclePeak = l.principal;
        h.totalBorrowed += uint128(amount);
        totalPrincipal += amount;
        _push(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    /// @notice Repay your own line. Interest is paid first, then principal; overpayment is not taken.
    function repay(uint256 amount) external nonReentrant returns (uint256 paid) {
        return _repay(msg.sender, amount);
    }

    /// @notice Repay someone else's line, e.g. an employer, a guarantor or a payment app.
    function repayFor(address borrower, uint256 amount) external nonReentrant returns (uint256 paid) {
        return _repay(borrower, amount);
    }

    function _repay(address borrower, uint256 amount) internal returns (uint256 paid) {
        if (amount == 0) revert ZeroAmount();
        Line storage l = lines[borrower];
        _accrue(l);
        uint256 interestDue = l.interest;
        uint256 principalDue = l.principal;
        if (interestDue + principalDue == 0) revert NothingOwed();

        uint256 toInterest = amount < interestDue ? amount : interestDue;
        uint256 rest = amount - toInterest;
        uint256 toPrincipal = rest < principalDue ? rest : principalDue;
        paid = toInterest + toPrincipal;

        l.interest = uint128(interestDue - toInterest);
        l.principal = uint128(principalDue - toPrincipal);
        totalPrincipal -= toPrincipal;
        totalRepaidInterest += toInterest;

        History storage h = history[borrower];
        h.repayments += 1;
        h.lastRepaidAt = uint64(block.timestamp);
        h.totalRepaid += uint128(paid);
        if (l.principal == 0 && l.interest == 0 && h.cycleStart != 0) {
            bool qualifies = block.timestamp - h.cycleStart >= CYCLE_MIN_DURATION
                && uint256(h.cyclePeak) * CYCLE_MIN_USE_DIVISOR >= l.limit;
            h.cycleStart = 0;
            h.cyclePeak = 0;
            if (qualifies) {
                h.cyclesCompleted += 1;
                (, uint32 aprBps,) = quote(l.score, h.cyclesCompleted);
                l.aprBps = aprBps;
                emit CycleCompleted(borrower, h.cyclesCompleted, aprBps);
            }
        }

        _pull(msg.sender, paid);
        emit Repaid(borrower, msg.sender, toInterest, toPrincipal);
    }

    // ------------------------------------------------------------- admin --

    function setUnderwriter(address underwriter_) external onlyOwner {
        if (underwriter_ == address(0)) revert ZeroAddress();
        underwriter = underwriter_;
        emit UnderwriterChanged(underwriter_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ----------------------------------------------------------- internal --

    function _pending(Line memory l) private view returns (uint256) {
        if (l.principal == 0 || l.lastAccrued == 0) return 0;
        return uint256(l.principal) * l.aprBps * (block.timestamp - l.lastAccrued) / (YEAR * 10_000);
    }

    function _accrue(Line storage l) private {
        if (l.lastAccrued == 0) return;
        uint256 add = _pending(l);
        if (add > 0) l.interest += uint128(add);
        l.lastAccrued = uint64(block.timestamp);
    }

    function _pull(address from, uint256 amount) private {
        uint256 before = usdc.balanceOf(address(this));
        if (!usdc.transferFrom(from, address(this), amount)) revert TransferFailed();
        if (usdc.balanceOf(address(this)) - before != amount) revert TransferFailed();
    }

    function _push(address to, uint256 amount) private {
        if (!usdc.transfer(to, amount)) revert TransferFailed();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title LCRD Credit Line
/// @notice A USDC lending pool with underwritten, per-borrower credit lines.
///
/// Lenders deposit USDC and receive pool shares. The underwriter opens a credit
/// line for a borrower (limit, APR, risk tier) based on an LCRD credit score
/// computed off-chain; only a hash of that score report is stored here, never
/// personal data. Borrowers draw and repay in USDC. Interest accrues by the
/// second and, once repaid, raises the value of every share. A written-off
/// line lowers it.
contract CreditLine {
    // ---------------------------------------------------------------- types --

    struct Line {
        uint128 limit; // max principal outstanding, in USDC base units
        uint128 principal; // principal outstanding
        uint128 interest; // interest accrued and not yet repaid
        uint32 aprBps; // simple annual rate, basis points
        uint8 tier; // LCRD risk tier, 1 (best) .. 5
        bool active; // can draw; repayments are always accepted
        uint64 lastAccrued; // timestamp of the last accrual
        bytes32 scoreRef; // hash of the off-chain score report backing this line
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
    address[] public borrowers;

    uint256 private constant YEAR = 365 days;
    uint256 private constant MAX_APR_BPS = 10_000; // 100%
    // Virtual shares and assets blunt the first-depositor share inflation attack.
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;

    uint256 private locked = 1;

    // -------------------------------------------------------------- events --

    event Deposited(address indexed lender, uint256 assets, uint256 shares);
    event Withdrawn(address indexed lender, uint256 assets, uint256 shares);
    event LineSet(address indexed borrower, uint256 limit, uint256 aprBps, uint8 tier, bytes32 scoreRef);
    event LineFrozen(address indexed borrower);
    event Borrowed(address indexed borrower, uint256 amount);
    event Repaid(address indexed borrower, address indexed payer, uint256 interestPaid, uint256 principalPaid);
    event WrittenOff(address indexed borrower, uint256 principal, uint256 interest);
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
    error AprTooHigh();
    error BadTier();
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

    /// @notice Open or update a borrower's line. Accrues interest at the old rate first.
    /// @param scoreRef keccak256 of the off-chain LCRD score report (no personal data on-chain).
    function setLine(address borrower, uint128 limit, uint32 aprBps, uint8 tier, bytes32 scoreRef)
        external
        onlyUnderwriter
    {
        if (borrower == address(0)) revert ZeroAddress();
        if (aprBps > MAX_APR_BPS) revert AprTooHigh();
        if (tier == 0 || tier > 5) revert BadTier();
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
        l.scoreRef = scoreRef;
        l.active = true;
        emit LineSet(borrower, limit, aprBps, tier, scoreRef);
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
        l.principal += uint128(amount);
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

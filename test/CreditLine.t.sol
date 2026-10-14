// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreditLine, IERC20} from "../src/CreditLine.sol";

/// Minimal 6-decimal USDC stand-in.
contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public constant decimals = 6;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CreditLineTest is Test {
    MockUSDC usdc;
    CreditLine pool;

    address underwriter = makeAddr("underwriter");
    address lender = makeAddr("lender");
    address lender2 = makeAddr("lender2");
    address alice = makeAddr("alice");
    address payer = makeAddr("payer");

    uint256 constant USDC = 1e6;
    bytes32 constant SCORE = keccak256("lcrd-score-report:alice:2026-10-14");

    function setUp() public {
        usdc = new MockUSDC();
        pool = new CreditLine(IERC20(address(usdc)), underwriter);
        for (uint256 i = 0; i < 4; i++) {
            address a = [lender, lender2, alice, payer][i];
            usdc.mint(a, 10_000 * USDC);
            vm.prank(a);
            usdc.approve(address(pool), type(uint256).max);
        }
    }

    function _fund(uint256 amount) internal {
        vm.prank(lender);
        pool.deposit(amount);
    }

    // score 100 -> tier A, APR 8% + 3% + 3% = 14%
    function _open(uint256 limit, uint8 score) internal {
        vm.prank(underwriter);
        pool.setLine(alice, score, uint128(limit), SCORE);
    }

    function test_DepositAndWithdraw() public {
        _fund(1_000 * USDC);
        assertEq(pool.cash(), 1_000 * USDC);
        uint256 shares = pool.sharesOf(lender);
        vm.prank(lender);
        uint256 out = pool.withdraw(shares);
        assertApproxEqAbs(out, 1_000 * USDC, 1);
        assertEq(pool.totalShares(), 0);
    }

    // ---- pricing ----

    function test_QuoteMatchesLcrdPolicy() public view {
        (uint8 tier, uint32 apr, uint256 maxLimit) = pool.quote(71, 0);
        assertEq(tier, 1); // A
        assertEq(apr, 1_893); // 800 + (2000 - 1700*71/100 = 793) + 300
        assertEq(maxLimit, 100 * USDC);

        (tier, apr, maxLimit) = pool.quote(100, 0);
        assertEq(tier, 1);
        assertEq(apr, 1_400);

        (tier, apr, maxLimit) = pool.quote(50, 0);
        assertEq(tier, 2); // B
        assertEq(apr, 2_250); // 800 + 1150 + 300
        assertEq(maxLimit, 75 * USDC);

        (tier, apr, maxLimit) = pool.quote(20, 0);
        assertEq(tier, 3); // C
        assertEq(maxLimit, 0);
        assertEq(apr, 2_760); // still priced, but not eligible for an unsecured line
    }

    function test_TierBoundaries() public view {
        (uint8 t,,) = pool.quote(67, 0);
        assertEq(t, 1);
        (t,,) = pool.quote(66, 0);
        assertEq(t, 2);
        (t,,) = pool.quote(34, 0);
        assertEq(t, 2);
        (t,,) = pool.quote(33, 0);
        assertEq(t, 3);
    }

    function testFuzz_AprWithinBoundsAndMonotonic(uint8 a, uint8 b) public view {
        a = uint8(bound(a, 0, 100));
        b = uint8(bound(b, 0, 100));
        (, uint32 aprA,) = pool.quote(a, 0);
        (, uint32 aprB,) = pool.quote(b, 0);
        assertGe(aprA, 600);
        assertLe(aprA, 3_600);
        if (a <= b) assertGe(aprA, aprB); // a better score never costs more
    }

    function test_SetLineDerivesTierAndApr() public {
        _open(50 * USDC, 71);
        (uint128 limit,,, uint32 apr, uint8 tier, uint8 score, bool active,,) = pool.lines(alice);
        assertEq(limit, 50 * USDC);
        assertEq(apr, 1_893);
        assertEq(tier, 1);
        assertEq(score, 71);
        assertTrue(active);
    }

    function test_RevertTierCNotEligible() public {
        vm.prank(underwriter);
        vm.expectRevert(CreditLine.TierNotEligible.selector);
        pool.setLine(alice, 30, uint128(10 * USDC), SCORE);
    }

    function test_RevertLimitAboveTierCap() public {
        vm.prank(underwriter);
        vm.expectRevert(CreditLine.OverLimit.selector);
        pool.setLine(alice, 50, uint128(76 * USDC), SCORE); // tier B cap is 75
    }

    function test_RevertScoreAbove100() public {
        vm.prank(underwriter);
        vm.expectRevert(CreditLine.BadScore.selector);
        pool.setLine(alice, 101, uint128(1 * USDC), SCORE);
    }

    function test_OnlyUnderwriterSetsLines() public {
        vm.prank(alice);
        vm.expectRevert(CreditLine.NotUnderwriter.selector);
        pool.setLine(alice, 80, 1, SCORE);
    }

    // ---- lending ----

    function test_BorrowWithinLimit() public {
        _fund(1_000 * USDC);
        _open(80 * USDC, 80);
        vm.prank(alice);
        pool.borrow(60 * USDC);
        (uint256 p,) = pool.owed(alice);
        assertEq(p, 60 * USDC);
        assertEq(pool.totalPrincipal(), 60 * USDC);
        assertEq(pool.available(alice), 20 * USDC);
    }

    function test_RevertOverLimit() public {
        _fund(1_000 * USDC);
        _open(80 * USDC, 80);
        vm.prank(alice);
        vm.expectRevert(CreditLine.OverLimit.selector);
        pool.borrow(81 * USDC);
    }

    function test_RevertWithoutLine() public {
        _fund(1_000 * USDC);
        vm.prank(alice);
        vm.expectRevert(CreditLine.LineInactive.selector);
        pool.borrow(1 * USDC);
    }

    function test_RevertInsufficientLiquidity() public {
        _fund(50 * USDC);
        _open(100 * USDC, 90);
        vm.prank(alice);
        vm.expectRevert(CreditLine.InsufficientLiquidity.selector);
        pool.borrow(60 * USDC);
    }

    function test_InterestAccruesAndRepaymentRaisesShareValue() public {
        _fund(1_000 * USDC);
        _open(100 * USDC, 100); // 14% APR
        vm.prank(alice);
        pool.borrow(100 * USDC);

        vm.warp(block.timestamp + 365 days);
        (uint256 p, uint256 i) = pool.owed(alice);
        assertEq(p, 100 * USDC);
        assertEq(i, 14 * USDC);

        vm.prank(alice);
        pool.repay(p + i);
        (p, i) = pool.owed(alice);
        assertEq(p + i, 0);
        assertEq(pool.totalRepaidInterest(), 14 * USDC);

        uint256 shares = pool.sharesOf(lender);
        vm.prank(lender);
        uint256 out = pool.withdraw(shares);
        assertApproxEqAbs(out, 1_014 * USDC, 2);
    }

    function test_RepayPaysInterestFirstAndCapsOverpayment() public {
        _fund(1_000 * USDC);
        _open(100 * USDC, 100); // 14%
        vm.prank(alice);
        pool.borrow(50 * USDC);
        vm.warp(block.timestamp + 365 days); // 7 USDC interest

        vm.prank(alice);
        pool.repay(5 * USDC);
        (uint256 p, uint256 i) = pool.owed(alice);
        assertEq(p, 50 * USDC);
        assertEq(i, 2 * USDC);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = pool.repay(1_000 * USDC);
        assertEq(paid, 52 * USDC);
        assertEq(before - usdc.balanceOf(alice), 52 * USDC);
    }

    function test_RepayFor() public {
        _fund(1_000 * USDC);
        _open(100 * USDC, 90);
        vm.prank(alice);
        pool.borrow(100 * USDC);
        vm.prank(payer);
        pool.repayFor(alice, 100 * USDC);
        (uint256 p,) = pool.owed(alice);
        assertEq(p, 0);
        assertEq(usdc.balanceOf(payer), 9_900 * USDC);
    }

    function test_FreezeStopsDrawsButNotRepayments() public {
        _fund(1_000 * USDC);
        _open(100 * USDC, 90);
        vm.prank(alice);
        pool.borrow(10 * USDC);
        vm.prank(underwriter);
        pool.freeze(alice);
        vm.prank(alice);
        vm.expectRevert(CreditLine.LineInactive.selector);
        pool.borrow(1 * USDC);
        vm.prank(alice);
        pool.repay(10 * USDC);
    }

    function test_WriteOffLowersShareValue() public {
        _fund(1_000 * USDC);
        _open(100 * USDC, 90);
        vm.prank(alice);
        pool.borrow(100 * USDC);
        vm.prank(underwriter);
        pool.writeOff(alice);
        assertEq(pool.totalPrincipal(), 0);
        assertEq(pool.totalWrittenOff(), 100 * USDC);
        assertApproxEqAbs(pool.convertToAssets(pool.sharesOf(lender)), 900 * USDC, 1);
    }

    function test_SecondLenderGetsFairShares() public {
        _fund(1_000 * USDC);
        _open(100 * USDC, 100);
        vm.prank(alice);
        pool.borrow(100 * USDC);
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        pool.repay(114 * USDC); // pool now worth 1,014

        vm.prank(lender2);
        pool.deposit(1_014 * USDC);
        assertApproxEqRel(pool.sharesOf(lender2), pool.sharesOf(lender), 1e12);
    }

    function test_DonationDoesNotStealFromNextDepositor() public {
        vm.prank(lender);
        pool.deposit(1);
        vm.prank(lender);
        usdc.transfer(address(pool), 1_000 * USDC);
        vm.prank(lender2);
        uint256 shares = pool.deposit(100 * USDC);
        assertGt(shares, 0);
        vm.prank(lender2);
        uint256 out = pool.withdraw(shares);
        assertApproxEqRel(out, 100 * USDC, 0.01e18);
    }

    function test_OwnershipTwoStep() public {
        address next = makeAddr("next");
        pool.transferOwnership(next);
        assertEq(pool.owner(), address(this));
        vm.prank(next);
        pool.acceptOwnership();
        assertEq(pool.owner(), next);
    }

    function testFuzz_RepayNeverTakesMoreThanOwed(uint96 borrowAmt, uint96 payAmt, uint32 elapsed, uint8 score) public {
        score = uint8(bound(score, 34, 100));
        borrowAmt = uint96(bound(borrowAmt, 1, 75 * USDC));
        payAmt = uint96(bound(payAmt, 1, 5_000 * USDC));
        _fund(1_000 * USDC);
        _open(75 * USDC, score);
        vm.prank(alice);
        pool.borrow(borrowAmt);
        vm.warp(block.timestamp + bound(elapsed, 0, 730 days));
        (uint256 p, uint256 i) = pool.owed(alice);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = pool.repay(payAmt);
        assertLe(paid, p + i);
        assertEq(before - usdc.balanceOf(alice), paid);
    }

    // ---- repayment history ----

    function test_HistoryRecordsEveryRepayment() public {
        _fund(1_000 * USDC);
        _open(100 * USDC, 90);
        vm.prank(alice);
        pool.borrow(40 * USDC);
        vm.prank(alice);
        pool.repay(10 * USDC);
        vm.prank(payer);
        pool.repayFor(alice, 5 * USDC);
        (uint32 repayments, uint32 cycles,, uint64 firstBorrowAt, uint64 lastRepaidAt,,, uint128 borrowed, uint128 repaid) =
            pool.history(alice);
        assertEq(repayments, 2);
        assertEq(cycles, 0);
        assertEq(firstBorrowAt, block.timestamp);
        assertEq(lastRepaidAt, block.timestamp);
        assertEq(borrowed, 40 * USDC);
        assertEq(repaid, 15 * USDC);
    }

    function test_CycleCompletesAndLowersApr() public {
        _fund(1_000 * USDC);
        _open(100 * USDC, 100); // 14.00%
        vm.prank(alice);
        pool.borrow(50 * USDC); // >= 25% of the line
        vm.warp(block.timestamp + 8 days);
        (uint256 p, uint256 i) = pool.owed(alice);
        vm.prank(alice);
        pool.repay(p + i);
        (, uint32 cycles,,,,,,,) = pool.history(alice);
        assertEq(cycles, 1);
        (,,, uint32 apr,,,,,) = pool.lines(alice);
        assertEq(apr, 1_350); // 50 bps cheaper, applied automatically
        // ... and the line may now grow: tier A maximum is two starter amounts.
        (,, uint256 maxLimit) = pool.quote(100, 1);
        assertEq(maxLimit, 200 * USDC);
        vm.prank(underwriter);
        pool.setLine(alice, 100, uint128(200 * USDC), SCORE);
    }

    function test_DustLoanDoesNotCountAsCycle() public {
        _fund(1_000 * USDC);
        _open(100 * USDC, 100);
        vm.prank(alice);
        pool.borrow(10 * USDC); // under 25% of the line
        vm.warp(block.timestamp + 30 days);
        (uint256 p, uint256 i) = pool.owed(alice);
        vm.prank(alice);
        pool.repay(p + i);
        (, uint32 cycles,,,,,,,) = pool.history(alice);
        assertEq(cycles, 0);
    }

    function test_QuickRepayDoesNotCountAsCycle() public {
        _fund(1_000 * USDC);
        _open(100 * USDC, 100);
        vm.prank(alice);
        pool.borrow(60 * USDC);
        vm.warp(block.timestamp + 1 days); // under 7 days
        (uint256 p, uint256 i) = pool.owed(alice);
        vm.prank(alice);
        pool.repay(p + i);
        (, uint32 cycles,,,,,,,) = pool.history(alice);
        assertEq(cycles, 0);
    }

    function test_WriteOffResetsCycles() public {
        _fund(1_000 * USDC);
        _open(100 * USDC, 100);
        vm.prank(alice);
        pool.borrow(50 * USDC);
        vm.warp(block.timestamp + 8 days);
        (uint256 p, uint256 i) = pool.owed(alice);
        vm.prank(alice);
        pool.repay(p + i);
        vm.prank(alice);
        pool.borrow(50 * USDC);
        vm.prank(underwriter);
        pool.writeOff(alice);
        (, uint32 cycles, uint32 writeOffs,,,,,,) = pool.history(alice);
        assertEq(cycles, 0);
        assertEq(writeOffs, 1);
    }

    function test_CycleRewardsAreCapped() public view {
        (, uint32 apr, uint256 maxLimit) = pool.quote(100, 10);
        assertEq(apr, 1_200); // discount capped at 200 bps
        assertEq(maxLimit, 1_100 * USDC); // 100 * (1 + 10), under the 2,500 ceiling
        (, apr, maxLimit) = pool.quote(100, 40);
        assertEq(maxLimit, 2_500 * USDC); // ceiling
        (,, maxLimit) = pool.quote(50, 10);
        assertEq(maxLimit, 250 * USDC); // tier B ceiling
    }
}

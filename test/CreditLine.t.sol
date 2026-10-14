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

    function _open(uint256 limit, uint32 apr) internal {
        vm.prank(underwriter);
        pool.setLine(alice, uint128(limit), apr, 2, SCORE);
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

    function test_BorrowWithinLimit() public {
        _fund(1_000 * USDC);
        _open(200 * USDC, 1_200);
        vm.prank(alice);
        pool.borrow(150 * USDC);
        (uint256 p,) = pool.owed(alice);
        assertEq(p, 150 * USDC);
        assertEq(pool.totalPrincipal(), 150 * USDC);
        assertEq(pool.available(alice), 50 * USDC);
    }

    function test_RevertOverLimit() public {
        _fund(1_000 * USDC);
        _open(200 * USDC, 1_200);
        vm.prank(alice);
        vm.expectRevert(CreditLine.OverLimit.selector);
        pool.borrow(201 * USDC);
    }

    function test_RevertWithoutLine() public {
        _fund(1_000 * USDC);
        vm.prank(alice);
        vm.expectRevert(CreditLine.LineInactive.selector);
        pool.borrow(1 * USDC);
    }

    function test_RevertInsufficientLiquidity() public {
        _fund(100 * USDC);
        _open(500 * USDC, 1_200);
        vm.prank(alice);
        vm.expectRevert(CreditLine.InsufficientLiquidity.selector);
        pool.borrow(150 * USDC);
    }

    function test_InterestAccruesAndRepaymentRaisesShareValue() public {
        _fund(1_000 * USDC);
        _open(500 * USDC, 1_000); // 10% APR
        vm.prank(alice);
        pool.borrow(500 * USDC);

        vm.warp(block.timestamp + 365 days);
        (uint256 p, uint256 i) = pool.owed(alice);
        assertEq(p, 500 * USDC);
        assertEq(i, 50 * USDC);

        vm.prank(alice);
        pool.repay(p + i);
        (p, i) = pool.owed(alice);
        assertEq(p + i, 0);
        assertEq(pool.totalRepaidInterest(), 50 * USDC);

        uint256 shares = pool.sharesOf(lender);
        vm.prank(lender);
        uint256 out = pool.withdraw(shares);
        assertApproxEqAbs(out, 1_050 * USDC, 2);
    }

    function test_RepayPaysInterestFirstAndCapsOverpayment() public {
        _fund(1_000 * USDC);
        _open(500 * USDC, 1_000);
        vm.prank(alice);
        pool.borrow(100 * USDC);
        vm.warp(block.timestamp + 365 days); // 10 USDC interest

        vm.prank(alice);
        pool.repay(5 * USDC);
        (uint256 p, uint256 i) = pool.owed(alice);
        assertEq(p, 100 * USDC);
        assertEq(i, 5 * USDC);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = pool.repay(1_000 * USDC);
        assertEq(paid, 105 * USDC);
        assertEq(before - usdc.balanceOf(alice), 105 * USDC);
    }

    function test_RepayFor() public {
        _fund(1_000 * USDC);
        _open(500 * USDC, 0);
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
        _open(500 * USDC, 0);
        vm.prank(alice);
        pool.borrow(100 * USDC);
        vm.prank(underwriter);
        pool.freeze(alice);
        vm.prank(alice);
        vm.expectRevert(CreditLine.LineInactive.selector);
        pool.borrow(1 * USDC);
        vm.prank(alice);
        pool.repay(100 * USDC);
    }

    function test_WriteOffLowersShareValue() public {
        _fund(1_000 * USDC);
        _open(500 * USDC, 0);
        vm.prank(alice);
        pool.borrow(400 * USDC);
        vm.prank(underwriter);
        pool.writeOff(alice);
        assertEq(pool.totalPrincipal(), 0);
        assertEq(pool.totalWrittenOff(), 400 * USDC);
        assertApproxEqAbs(pool.convertToAssets(pool.sharesOf(lender)), 600 * USDC, 1);
    }

    function test_OnlyUnderwriterSetsLines() public {
        vm.prank(alice);
        vm.expectRevert(CreditLine.NotUnderwriter.selector);
        pool.setLine(alice, 1, 0, 1, SCORE);
    }

    function test_SetLineValidates() public {
        vm.startPrank(underwriter);
        vm.expectRevert(CreditLine.AprTooHigh.selector);
        pool.setLine(alice, 1, 10_001, 1, SCORE);
        vm.expectRevert(CreditLine.BadTier.selector);
        pool.setLine(alice, 1, 100, 6, SCORE);
        vm.stopPrank();
    }

    function test_SecondLenderGetsFairShares() public {
        _fund(1_000 * USDC);
        _open(500 * USDC, 1_000);
        vm.prank(alice);
        pool.borrow(500 * USDC);
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        pool.repay(550 * USDC); // pool now worth 1,050

        vm.prank(lender2);
        pool.deposit(1_050 * USDC);
        assertApproxEqRel(pool.sharesOf(lender2), pool.sharesOf(lender), 1e12);
    }

    function test_DonationDoesNotStealFromNextDepositor() public {
        // Attacker deposits 1 unit, then donates a large amount to the pool.
        vm.prank(lender);
        pool.deposit(1);
        vm.prank(lender);
        usdc.transfer(address(pool), 1_000 * USDC);
        vm.prank(lender2);
        uint256 shares = pool.deposit(100 * USDC);
        assertGt(shares, 0);
        vm.prank(lender2);
        uint256 out = pool.withdraw(shares);
        assertApproxEqRel(out, 100 * USDC, 0.01e18); // within 1%
    }

    function test_OwnershipTwoStep() public {
        address next = makeAddr("next");
        pool.transferOwnership(next);
        assertEq(pool.owner(), address(this));
        vm.prank(next);
        pool.acceptOwnership();
        assertEq(pool.owner(), next);
    }

    function testFuzz_RepayNeverTakesMoreThanOwed(uint96 borrowAmt, uint96 payAmt, uint32 elapsed) public {
        borrowAmt = uint96(bound(borrowAmt, 1, 500 * USDC));
        payAmt = uint96(bound(payAmt, 1, 5_000 * USDC));
        _fund(1_000 * USDC);
        _open(500 * USDC, 2_500);
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
}

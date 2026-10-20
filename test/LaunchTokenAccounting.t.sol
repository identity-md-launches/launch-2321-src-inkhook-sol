// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// ERC20 model over a closed actor set. No mint/deal changes balances after initial distribution.
contract LaunchTokenHandler is Test {
    LaunchToken public token;
    address[4] public actors;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;
    uint256 public successfulTransfers;
    uint256 public rejectedTransfers;

    constructor(LaunchToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        for (uint256 i; i < 4; i++) {
            balances[actors[i]] = token.balanceOf(actors[i]);
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount, bool fullBalance) public {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        amount = fullBalance ? balances[from] : bound(amount, 0, balances[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        balances[from] -= amount;
        balances[to] += amount;
        successfulTransfers++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) public {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        amount = unlimited ? type(uint256).max : amount;
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        allowances[owner][spender] = amount;
    }

    function spend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) public {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        address to = actors[toSeed % 4];
        uint256 allowance = allowances[owner][spender];
        uint256 maximum = balances[owner] < allowance ? balances[owner] : allowance;
        amount = bound(amount, 0, maximum);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        balances[owner] -= amount;
        balances[to] += amount;
        if (allowance != type(uint256).max) allowances[owner][spender] -= amount;
        successfulTransfers++;
    }

    /// Each failure checks the specific error; unchanged ghosts require every balance/approval to roll back.
    function reject(uint256 ownerSeed, uint256 spenderSeed, bool insufficientBalance) public {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        if (insufficientBalance) {
            // Force transferFrom past the allowance check, so a balance failure must also restore allowance.
            uint256 tooMuch = balances[owner] + 1;
            vm.prank(owner);
            token.approve(spender, tooMuch);
            allowances[owner][spender] = tooMuch;
            vm.prank(spender);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector, owner, balances[owner], tooMuch
                )
            );
            token.transferFrom(owner, actors[(ownerSeed % 4 + 1) % 4], tooMuch);
        } else {
            vm.prank(owner);
            token.approve(spender, 0);
            allowances[owner][spender] = 0;
            vm.prank(spender);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1)
            );
            token.transferFrom(owner, actors[(ownerSeed % 4 + 1) % 4], 1);
        }
        rejectedTransfers++;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.fuzz.runs = 1000
contract LaunchTokenAccountingTest is Test {
    LaunchToken internal token;
    LaunchTokenHandler internal handler;
    address[4] internal actors;

    function setUp() public {
        token = new LaunchToken();
        for (uint256 i; i < 4; i++) {
            actors[i] = makeAddr(string(abi.encodePacked("INK holder ", bytes1(uint8(i)))));
            token.transfer(actors[i], 250_000_000e18);
        }
        handler = new LaunchTokenHandler(token, actors);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.spend.selector;
        selectors[3] = handler.reject.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// SHOULD-HOLD: fixed supply equals the complete ledger, regardless of transfer/approval order.
    function invariant_balancesConserveFixedSupply() public view {
        uint256 total;
        for (uint256 i; i < 4; i++) {
            assertEq(token.balanceOf(actors[i]), handler.balances(actors[i]));
            total += token.balanceOf(actors[i]);
        }
        assertEq(total, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// SHOULD-HOLD: only approvals and successful spends can change allowances; infinite approval persists.
    function invariant_allowancesFollowApprovalsAndSuccessfulSpends() public view {
        for (uint256 i; i < 4; i++) {
            for (uint256 j; j < 4; j++) {
                assertEq(token.allowance(actors[i], actors[j]), handler.allowances(actors[i], actors[j]));
            }
        }
    }

    function test_zeroOneFullBalanceAndSelfTransfers() public {
        handler.transfer(0, 1, 0, false);
        handler.transfer(0, 1, 1, false);
        handler.transfer(1, 1, 0, true);
        handler.transfer(1, 2, 0, true);
        assertEq(token.balanceOf(actors[1]), 0);
        handler.transfer(1, 0, 0, true);
        invariant_balancesConserveFixedSupply();
    }

    function test_finiteInfiniteAndRevokedApprovals() public {
        handler.approve(0, 1, 7, false);
        handler.spend(0, 1, 2, 7);
        assertEq(token.allowance(actors[0], actors[1]), 0);
        handler.approve(0, 1, 0, true);
        handler.spend(0, 1, 0, 1); // self transfer still spends, but an infinite allowance stays infinite
        assertEq(token.allowance(actors[0], actors[1]), type(uint256).max);
        handler.approve(0, 1, 0, false);
        handler.reject(0, 1, false);
        handler.reject(0, 1, true);
        assertEq(handler.rejectedTransfers(), 2);
        invariant_balancesConserveFixedSupply();
        invariant_allowancesFollowApprovalsAndSuccessfulSpends();
    }

    function test_zeroAddressesAndMaximumSpendCannotDestroyTokens() public {
        uint256 balance = token.balanceOf(actors[0]);
        vm.startPrank(actors[0]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), balance);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), type(uint256).max);
        token.approve(actors[1], type(uint256).max);
        vm.stopPrank();
        vm.startPrank(actors[1]);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, actors[0], balance, type(uint256).max
            )
        );
        token.transferFrom(actors[0], actors[1], type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(actors[0], address(0), 1);
        // OpenZeppelin rejects the zero allowance owner before reaching the transfer sender check.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), actors[1], 0);
        vm.stopPrank();
        assertEq(token.balanceOf(actors[0]), balance);
        assertEq(token.allowance(actors[0], actors[1]), type(uint256).max);
        assertEq(token.totalSupply(), 1e27);
    }

    function testFuzz_roundTripsHaveNoTransferTax(uint256 amount) public {
        amount = bound(amount, 0, token.balanceOf(actors[0]));
        uint256 a = token.balanceOf(actors[0]);
        uint256 b = token.balanceOf(actors[1]);
        vm.prank(actors[0]);
        token.transfer(actors[1], amount);
        assertEq(token.balanceOf(actors[1]), b + amount);
        vm.prank(actors[1]);
        token.transfer(actors[0], amount);
        assertEq(token.balanceOf(actors[0]), a);
        assertEq(token.balanceOf(actors[1]), b);
        assertEq(token.totalSupply(), 1e27);
    }
}

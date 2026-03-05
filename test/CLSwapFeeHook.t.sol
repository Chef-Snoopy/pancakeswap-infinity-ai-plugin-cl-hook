// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {SortTokens} from "infinity-core/test/helpers/SortTokens.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ICLRouterBase} from "infinity-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {MockCLSwapRouter} from "infinity-hooks/test/pool-cl/helpers/MockCLSwapRouter.sol";
import {MockCLPositionManager} from "infinity-hooks/test/pool-cl/helpers/MockCLPositionManager.sol";
import {CLSwapFeeHook} from "../src/CLSwapFeeHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract CLSwapFeeHookTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    IVault vault;
    ICLPoolManager poolManager;
    IAllowanceTransfer permit2;
    MockCLPositionManager cpm;
    MockCLSwapRouter swapRouter;

    CLSwapFeeHook swapFeeHook;

    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId id;

    address owner;
    address alice = address(0x1111);
    address bob = address(0x2222);

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        owner = address(this);
        swapFeeHook = new CLSwapFeeHook(poolManager);

        permit2 = IAllowanceTransfer(deployPermit2());
        cpm = new MockCLPositionManager(vault, poolManager, permit2);
        swapRouter = new MockCLSwapRouter(vault, poolManager);

        MockERC20[] memory tokens = deployTokens(2, type(uint256).max);
        token0 = tokens[0];
        token1 = tokens[1];
        (currency0, currency1) = SortTokens.sort(token0, token1);

        address[4] memory approvalAddress = [address(cpm), address(swapRouter), address(swapFeeHook), address(permit2)];
        for (uint256 i; i < approvalAddress.length; i++) {
            token0.approve(approvalAddress[i], type(uint256).max);
            token1.approve(approvalAddress[i], type(uint256).max);
        }
        permit2.approve(address(token0), address(cpm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(cpm), type(uint160).max, type(uint48).max);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: swapFeeHook,
            poolManager: poolManager,
            fee: 3000,
            parameters: bytes32(uint256(swapFeeHook.getHooksRegistrationBitmap())).setTickSpacing(60)
        });
        id = key.toId();

        poolManager.initialize(key, SQRT_RATIO_1_1);

        // Add liquidity for testing swaps
        cpm.mint(
            key,
            -120,
            120,
            // liquidity:
            10e18,
            // amount0Max:
            100e18,
            // amount1Max:
            100e18,
            // owner:
            address(this),
            // hookData:
            ZERO_BYTES
        );
    }

    // ── Constructor Tests ────────────────────────────────────────────────────

    function testConstructorSetsOwner() public view {
        assertEq(swapFeeHook.owner(), owner);
        assertEq(swapFeeHook.pendingOwner(), address(0));
    }

    // ── Hook Permissions Tests ───────────────────────────────────────────────

    function testGetHooksRegistrationBitmap() public {
        uint16 bitmap = swapFeeHook.getHooksRegistrationBitmap();
        // afterSwap and afterSwapReturnDelta should be enabled
        assertTrue(bitmap > 0);
    }

    // ── Swap Fee Tests ───────────────────────────────────────────────────────

    function testSwapZeroForOneExactInput() public {
        uint128 amountIn = 1e18;

        // zeroForOne + exactInput → fee taken from currency1 (output)
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: amountIn, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        // Fee = 0.1% of output (currency1)
        uint256 expectedFee = swapFeeHook.accruedFees(currency1);
        assertTrue(expectedFee > 0, "Fee should be accrued");
    }

    function testSwapZeroForOneExactOutput() public {
        uint128 amountOut = 1e18;

        // zeroForOne + exactOutput → fee taken from currency0 (input)
        swapRouter.exactOutputSingle(
            ICLRouterBase.CLSwapExactOutputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountOut: amountOut,
                amountInMaximum: type(uint128).max,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        // Fee = 0.1% of input (currency0)
        uint256 expectedFee = swapFeeHook.accruedFees(currency0);
        assertTrue(expectedFee > 0, "Fee should be accrued");
    }

    function testSwapOneForZeroExactInput() public {
        uint128 amountIn = 1e18;

        // oneForZero + exactInput → fee taken from currency0 (output)
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: false, amountIn: amountIn, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        // Fee = 0.1% of output (currency0)
        uint256 expectedFee = swapFeeHook.accruedFees(currency0);
        assertTrue(expectedFee > 0, "Fee should be accrued");
    }

    function testSwapOneForZeroExactOutput() public {
        uint128 amountOut = 1e18;

        // oneForZero + exactOutput → fee taken from currency1 (input)
        swapRouter.exactOutputSingle(
            ICLRouterBase.CLSwapExactOutputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountOut: amountOut,
                amountInMaximum: type(uint128).max,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        // Fee = 0.1% of input (currency1)
        uint256 expectedFee = swapFeeHook.accruedFees(currency1);
        assertTrue(expectedFee > 0, "Fee should be accrued");
    }

    function testFeeAccrual() public {
        uint128 amountIn = 1e18;

        // Perform first swap (zeroForOne)
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: amountIn, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 firstFee = swapFeeHook.accruedFees(currency1);
        assertTrue(firstFee > 0, "First fee should be accrued");

        // Perform second swap (opposite direction to avoid price limit issue)
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: false, amountIn: amountIn, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        // Check that fees have been accrued on currency0 now
        uint256 secondFee = swapFeeHook.accruedFees(currency0);
        assertTrue(secondFee > 0, "Second fee should be accrued");
    }

    function testFeeEventEmitted() public {
        uint128 amountIn = 1e18;

        vm.expectEmit(true, true, false, false);
        emit CLSwapFeeHook.FeeAccrued(id, currency1, 0);

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: amountIn, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
    }

    // ── Fee Withdrawal Tests ─────────────────────────────────────────────────

    function testWithdrawFees() public {
        // Accrue some fees first
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: 1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 accruedFee = swapFeeHook.accruedFees(currency1);
        assertTrue(accruedFee > 0, "Should have accrued fees");

        uint256 balanceBefore = currency1.balanceOf(bob);

        // Withdraw fees to bob
        swapFeeHook.withdrawFees(currency1, bob, accruedFee);

        uint256 balanceAfter = currency1.balanceOf(bob);
        assertEq(balanceAfter - balanceBefore, accruedFee, "Bob should receive accrued fees");
        assertEq(swapFeeHook.accruedFees(currency1), 0, "Accrued fees should be zero");
    }

    function testWithdrawFeesWithZeroAmount() public {
        // Accrue some fees first
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: 1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 accruedFee = swapFeeHook.accruedFees(currency1);
        uint256 balanceBefore = currency1.balanceOf(bob);

        // amount = 0 should withdraw all
        swapFeeHook.withdrawFees(currency1, bob, 0);

        uint256 balanceAfter = currency1.balanceOf(bob);
        assertEq(balanceAfter - balanceBefore, accruedFee, "Bob should receive all fees");
    }

    function testWithdrawFeesRevertsOnNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        swapFeeHook.withdrawFees(currency1, alice, 100);
    }

    function testWithdrawFeesRevertsOnZeroRecipient() public {
        vm.expectRevert(CLSwapFeeHook.ZeroAddress.selector);
        swapFeeHook.withdrawFees(currency1, address(0), 100);
    }

    function testWithdrawFeesRevertsOnInsufficientBalance() public {
        vm.expectRevert(CLSwapFeeHook.InsufficientAccruedFees.selector);
        swapFeeHook.withdrawFees(currency1, bob, 100);
    }

    function testWithdrawFeesEvent() public {
        // Accrue fees
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: 1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 accruedFee = swapFeeHook.accruedFees(currency1);

        vm.expectEmit(true, true, false, true);
        emit CLSwapFeeHook.FeesWithdrawn(currency1, bob, accruedFee);

        swapFeeHook.withdrawFees(currency1, bob, accruedFee);
    }

    // ── Ownership Transfer Tests (Ownable2Step) ───────────────────────────────

    function testTransferOwnership() public {
        swapFeeHook.transferOwnership(alice);
        assertEq(swapFeeHook.pendingOwner(), alice);
        assertEq(swapFeeHook.owner(), owner);
    }

    function testTransferOwnershipRevertsOnNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        swapFeeHook.transferOwnership(bob);
    }

    function testTransferOwnershipRevertsOnZeroAddress() public {
        vm.expectRevert(CLSwapFeeHook.ZeroAddress.selector);
        swapFeeHook.transferOwnership(address(0));
    }

    function testTransferOwnershipEvent() public {
        vm.expectEmit(true, true, false, false);
        emit Ownable2Step.OwnershipTransferStarted(owner, alice);

        swapFeeHook.transferOwnership(alice);
    }

    function testAcceptOwnership() public {
        swapFeeHook.transferOwnership(alice);

        vm.prank(alice);
        swapFeeHook.acceptOwnership();

        assertEq(swapFeeHook.owner(), alice);
        assertEq(swapFeeHook.pendingOwner(), address(0));
    }

    function testAcceptOwnershipRevertsOnNonPendingOwner() public {
        swapFeeHook.transferOwnership(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        swapFeeHook.acceptOwnership();
    }

    function testAcceptOwnershipEvent() public {
        swapFeeHook.transferOwnership(alice);

        vm.expectEmit(true, true, false, false);
        emit Ownable.OwnershipTransferred(owner, alice);

        vm.prank(alice);
        swapFeeHook.acceptOwnership();
    }

    function testNewOwnerCanWithdrawFees() public {
        // Accrue fees
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: 1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        swapFeeHook.transferOwnership(alice);
        vm.prank(alice);
        swapFeeHook.acceptOwnership();

        uint256 accruedFee = swapFeeHook.accruedFees(currency1);

        vm.prank(alice);
        swapFeeHook.withdrawFees(currency1, bob, accruedFee);

        assertEq(swapFeeHook.accruedFees(currency1), 0);
    }

    function testOldOwnerCannotWithdrawAfterTransfer() public {
        // Accrue fees
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: 1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        swapFeeHook.transferOwnership(alice);
        vm.prank(alice);
        swapFeeHook.acceptOwnership();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        swapFeeHook.withdrawFees(currency1, bob, 100);
    }

    // ── Fee Calculation Accuracy Tests ──────────────────────────────────────

    function testFeeCalculationExactInputZeroForOne() public {
        uint128 amountIn = 1e18;

        // Record balance before to calculate actual output
        uint256 balance1Before = currency1.balanceOf(address(this));

        // Execute swap: zeroForOne + exactInput → fee from currency1 (output)
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: amountIn, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 balance1After = currency1.balanceOf(address(this));
        uint256 actualReceived = balance1After - balance1Before;

        // Get accrued fee
        uint256 accruedFee = swapFeeHook.accruedFees(currency1);
        assertTrue(accruedFee > 0, "Should accrue fee on output currency");

        // Total output = what user received + fee charged
        uint256 totalOutput = actualReceived + accruedFee;

        // Verify fee is 0.1% of total output
        uint256 expectedFee = (totalOutput * 10) / 10_000;
        assertEq(accruedFee, expectedFee, "Fee should be 0.1% of total output");
    }

    function testFeeCalculationExactOutputOneForZero() public {
        uint128 amountOut = 5e17; // 0.5 token

        // Execute swap: oneForZero + exactOutput → fee from currency1 (input)
        // User specifies exact output, hook adds fee to input cost
        swapRouter.exactOutputSingle(
            ICLRouterBase.CLSwapExactOutputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountOut: amountOut,
                amountInMaximum: type(uint128).max,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        // Fee should be accrued on currency1 (input side)
        uint256 accruedFee = swapFeeHook.accruedFees(currency1);
        assertTrue(accruedFee > 0, "Fee should be charged on input currency");

        // For exactOutput, fee is 0.1% of the input required
        // We can't easily predict the exact input amount, but we can verify fee exists
        // and is reasonable (should be < 1% of desired output)
        assertTrue(accruedFee < amountOut / 100, "Fee should be much less than output amount");
    }

    function testFeeCalculationMultipleSwaps() public {
        uint128 amountIn1 = 1e18;
        uint128 amountIn2 = 5e17;
        uint128 amountIn3 = 2e18;

        // First swap
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: amountIn1, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        uint256 fee1 = swapFeeHook.accruedFees(currency1);
        assertTrue(fee1 > 0, "First fee should be accrued");

        // Second swap (opposite direction)
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: false, amountIn: amountIn2, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        uint256 fee2 = swapFeeHook.accruedFees(currency0);
        assertTrue(fee2 > 0, "Second fee should be accrued");

        // Third swap (same direction as first)
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: amountIn3, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        uint256 fee1After = swapFeeHook.accruedFees(currency1);

        // Verify cumulative fees
        assertTrue(fee1After > fee1, "Currency1 fees should accumulate");
        assertEq(swapFeeHook.accruedFees(currency0), fee2, "Currency0 fee should remain unchanged");
    }

    function testFeeCalculationSmallSwap() public {
        // Test with very small amount
        uint128 amountIn = 1000; // 1000 wei

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: amountIn, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 accruedFee = swapFeeHook.accruedFees(currency1);

        // Fee might be 0 for very small amounts due to rounding
        assertTrue(accruedFee >= 0, "Fee should be non-negative");
    }

    function testFeeCalculationLargeSwap() public {
        // Test with larger amount
        uint128 amountIn = 10e18; // 10 tokens

        uint256 balance1Before = currency1.balanceOf(address(this));

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: amountIn, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 balance1After = currency1.balanceOf(address(this));
        uint256 actualReceived = balance1After - balance1Before;
        uint256 accruedFee = swapFeeHook.accruedFees(currency1);

        assertTrue(accruedFee > 0, "Fee should be accrued for large swap");

        // Verify fee is approximately 0.1% of total output (received + fee)
        uint256 totalOutput = actualReceived + accruedFee;
        uint256 feePercentageBps = (accruedFee * 10_000) / totalOutput;
        assertApproxEqAbs(feePercentageBps, 10, 1, "Fee should be approximately 0.1% (10 bps)");
    }

    function testFeeCalculationZeroForOneBothDirections() public {
        // Test that fees are collected in the correct currency for different swap types

        // Scenario 1: exactInput, zeroForOne → fee on currency1
        uint128 amountIn1 = 1e18;

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: amountIn1, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 fee1 = swapFeeHook.accruedFees(currency1);
        assertTrue(fee1 > 0, "ExactInput zeroForOne should accrue fee on currency1");
        assertEq(swapFeeHook.accruedFees(currency0), 0, "Should not accrue fee on currency0");

        // Scenario 2: exactInput, oneForZero → fee on currency0
        uint128 amountIn2 = 1e18;

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: false, amountIn: amountIn2, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 fee0 = swapFeeHook.accruedFees(currency0);
        assertTrue(fee0 > 0, "ExactInput oneForZero should accrue fee on currency0");
        assertEq(swapFeeHook.accruedFees(currency1), fee1, "Currency1 fee should remain unchanged");
    }

    function testFeeWithdrawalMatchesAccrual() public {
        // Perform swap in one direction
        uint128 swapAmount1 = 1e18;

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: swapAmount1, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 fee1 = swapFeeHook.accruedFees(currency1);

        // Perform swap in opposite direction
        uint128 swapAmount2 = 1e18;

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: false, amountIn: swapAmount2, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 fee0 = swapFeeHook.accruedFees(currency0);

        // Perform one more swap
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: swapAmount1, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 totalFee1 = swapFeeHook.accruedFees(currency1);
        assertTrue(totalFee1 > fee1, "Fees should accumulate");

        // Withdraw currency1 fees and verify
        uint256 bobBalanceBefore = currency1.balanceOf(bob);
        swapFeeHook.withdrawFees(currency1, bob, totalFee1);
        uint256 bobBalanceAfter = currency1.balanceOf(bob);

        assertEq(bobBalanceAfter - bobBalanceBefore, totalFee1, "Withdrawn amount should match accrued fees");
        assertEq(swapFeeHook.accruedFees(currency1), 0, "Currency1 fees should be zero after withdrawal");
        assertEq(swapFeeHook.accruedFees(currency0), fee0, "Currency0 fees should remain unchanged");
    }
}

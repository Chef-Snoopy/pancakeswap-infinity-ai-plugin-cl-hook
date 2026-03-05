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

    address admin;
    address alice = address(0x1111);
    address bob = address(0x2222);

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        admin = address(this);
        swapFeeHook = new CLSwapFeeHook(poolManager, vault);

        permit2 = IAllowanceTransfer(deployPermit2());
        cpm = new MockCLPositionManager(vault, poolManager, permit2);
        swapRouter = new MockCLSwapRouter(vault, poolManager);

        MockERC20[] memory tokens = deployTokens(2, type(uint256).max);
        token0 = tokens[0];
        token1 = tokens[1];
        (currency0, currency1) = SortTokens.sort(token0, token1);

        address[4] memory approvalAddress =
            [address(cpm), address(swapRouter), address(swapFeeHook), address(permit2)];
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

    function testConstructorSetsAdmin() public {
        assertEq(swapFeeHook.admin(), admin);
        assertEq(swapFeeHook.pendingAdmin(), address(0));
    }

    function testConstructorRevertsOnZeroVault() public {
        vm.expectRevert(CLSwapFeeHook.ZeroAddress.selector);
        new CLSwapFeeHook(poolManager, IVault(address(0)));
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
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
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
                poolKey: key,
                zeroForOne: false,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
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
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 firstFee = swapFeeHook.accruedFees(currency1);
        assertTrue(firstFee > 0, "First fee should be accrued");

        // Perform second swap (opposite direction to avoid price limit issue)
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
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
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
    }

    // ── Fee Withdrawal Tests ─────────────────────────────────────────────────

    function testWithdrawFees() public {
        // Accrue some fees first
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 1e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
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
                poolKey: key,
                zeroForOne: true,
                amountIn: 1e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
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

    function testWithdrawFeesRevertsOnNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert(CLSwapFeeHook.OnlyAdmin.selector);
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
                poolKey: key,
                zeroForOne: true,
                amountIn: 1e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 accruedFee = swapFeeHook.accruedFees(currency1);
        
        vm.expectEmit(true, true, false, true);
        emit CLSwapFeeHook.FeesWithdrawn(currency1, bob, accruedFee);
        
        swapFeeHook.withdrawFees(currency1, bob, accruedFee);
    }

    // ── Admin Transfer Tests ─────────────────────────────────────────────────

    function testInitiateAdminTransfer() public {
        swapFeeHook.initiateAdminTransfer(alice);
        assertEq(swapFeeHook.pendingAdmin(), alice);
        assertEq(swapFeeHook.admin(), admin);
    }

    function testInitiateAdminTransferRevertsOnNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert(CLSwapFeeHook.OnlyAdmin.selector);
        swapFeeHook.initiateAdminTransfer(bob);
    }

    function testInitiateAdminTransferRevertsOnZeroAddress() public {
        vm.expectRevert(CLSwapFeeHook.ZeroAddress.selector);
        swapFeeHook.initiateAdminTransfer(address(0));
    }

    function testInitiateAdminTransferEvent() public {
        vm.expectEmit(true, false, false, false);
        emit CLSwapFeeHook.AdminTransferInitiated(alice);
        
        swapFeeHook.initiateAdminTransfer(alice);
    }

    function testAcceptAdminTransfer() public {
        swapFeeHook.initiateAdminTransfer(alice);
        
        vm.prank(alice);
        swapFeeHook.acceptAdminTransfer();
        
        assertEq(swapFeeHook.admin(), alice);
        assertEq(swapFeeHook.pendingAdmin(), address(0));
    }

    function testAcceptAdminTransferRevertsOnNonPendingAdmin() public {
        swapFeeHook.initiateAdminTransfer(alice);
        
        vm.prank(bob);
        vm.expectRevert(CLSwapFeeHook.NotPendingAdmin.selector);
        swapFeeHook.acceptAdminTransfer();
    }

    function testAcceptAdminTransferEvent() public {
        swapFeeHook.initiateAdminTransfer(alice);
        
        vm.expectEmit(true, true, false, false);
        emit CLSwapFeeHook.AdminTransferred(admin, alice);
        
        vm.prank(alice);
        swapFeeHook.acceptAdminTransfer();
    }

    function testNewAdminCanWithdrawFees() public {
        // Accrue fees
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 1e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        // Transfer admin
        swapFeeHook.initiateAdminTransfer(alice);
        vm.prank(alice);
        swapFeeHook.acceptAdminTransfer();

        // New admin withdraws fees
        uint256 accruedFee = swapFeeHook.accruedFees(currency1);
        
        vm.prank(alice);
        swapFeeHook.withdrawFees(currency1, bob, accruedFee);
        
        assertEq(swapFeeHook.accruedFees(currency1), 0);
    }

    function testOldAdminCannotWithdrawAfterTransfer() public {
        // Accrue fees
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 1e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        // Transfer admin
        swapFeeHook.initiateAdminTransfer(alice);
        vm.prank(alice);
        swapFeeHook.acceptAdminTransfer();

        // Old admin cannot withdraw
        vm.expectRevert(CLSwapFeeHook.OnlyAdmin.selector);
        swapFeeHook.withdrawFees(currency1, bob, 100);
    }
}

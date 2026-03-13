// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {Constants} from "infinity-core/src/pool-bin/libraries/Constants.sol";
import {SortTokens} from "infinity-core/test/helpers/SortTokens.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IBinRouterBase} from "infinity-periphery/src/pool-bin/interfaces/IBinRouterBase.sol";
import {IBinPositionManager} from "infinity-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {MockBinPositionManager} from "infinity-hooks/test/pool-bin/helpers/MockBinPositionManager.sol";
import {MockBinSwapRouter} from "infinity-hooks/test/pool-bin/helpers/MockBinSwapRouter.sol";
import {Deployers} from "infinity-hooks/test/pool-bin/helpers/Deployers.sol";
import {BinSwapFeeHook} from "../src/BinSwapFeeHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract BinSwapFeeHookTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using BinPoolParametersHelper for bytes32;

    uint24 constant ACTIVE_ID = 2 ** 23; // 1:1 region

    IVault vault;
    IBinPoolManager poolManager;
    IAllowanceTransfer permit2;
    MockBinPositionManager bpm;
    MockBinSwapRouter swapRouter;

    BinSwapFeeHook swapFeeHook;

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
        token0 = deployToken("MockToken0", "MT0", type(uint256).max);
        token1 = deployToken("MockToken1", "MT1", type(uint256).max);
        (currency0, currency1) = SortTokens.sort(token0, token1);

        (vault, poolManager) = createFreshManager();
        owner = address(this);
        swapFeeHook = new BinSwapFeeHook(poolManager);

        permit2 = IAllowanceTransfer(deployPermit2());
        bpm = new MockBinPositionManager(vault, poolManager, permit2);
        swapRouter = new MockBinSwapRouter(vault, poolManager);

        address[4] memory approvalAddress = [address(bpm), address(swapRouter), address(swapFeeHook), address(permit2)];
        for (uint256 i; i < approvalAddress.length; i++) {
            token0.approve(approvalAddress[i], type(uint256).max);
            token1.approve(approvalAddress[i], type(uint256).max);
        }
        permit2.approve(address(token0), address(bpm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(bpm), type(uint160).max, type(uint48).max);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: swapFeeHook,
            poolManager: poolManager,
            fee: 0,
            parameters: bytes32(uint256(swapFeeHook.getHooksRegistrationBitmap())).setBinStep(60)
        });
        id = key.toId();

        poolManager.initialize(key, ACTIVE_ID);

        // Add liquidity around active bin
        uint256 numBins = 5;
        int256[] memory deltaIds = new int256[](numBins);
        deltaIds[0] = -2;
        deltaIds[1] = -1;
        deltaIds[2] = 0;
        deltaIds[3] = 1;
        deltaIds[4] = 2;
        uint256[] memory distributionX = new uint256[](numBins);
        distributionX[0] = 0;
        distributionX[1] = 0;
        distributionX[2] = Constants.PRECISION / 3;
        distributionX[3] = Constants.PRECISION / 3;
        distributionX[4] = Constants.PRECISION / 3;
        uint256[] memory distributionY = new uint256[](numBins);
        distributionY[0] = Constants.PRECISION / 3;
        distributionY[1] = Constants.PRECISION / 3;
        distributionY[2] = Constants.PRECISION / 3;
        distributionY[3] = 0;
        distributionY[4] = 0;
        bpm.addLiquidity(
            IBinPositionManager.BinAddLiquidityParams({
                poolKey: key,
                amount0: 3 * 1e18,
                amount1: 3 * 1e18,
                amount0Max: 3 * 1e18,
                amount1Max: 3 * 1e18,
                activeIdDesired: ACTIVE_ID,
                idSlippage: 0,
                deltaIds: deltaIds,
                distributionX: distributionX,
                distributionY: distributionY,
                to: address(this),
                hookData: ZERO_BYTES
            })
        );
    }

    // ── Constructor Tests ────────────────────────────────────────────────────

    function testConstructorSetsOwner() public view {
        assertEq(swapFeeHook.owner(), owner);
        assertEq(swapFeeHook.pendingOwner(), address(0));
    }

    // ── Hook Permissions Tests ───────────────────────────────────────────────

    function testGetHooksRegistrationBitmap() public view {
        uint16 bitmap = swapFeeHook.getHooksRegistrationBitmap();
        assertTrue(bitmap > 0);
    }

    // ── Swap Fee Tests ───────────────────────────────────────────────────────

    /// swapForY true + exactInput → unspecified = currency1 (output) → fee on currency1
    function testSwapSwapForYExactInput_FeeOnCurrency1() public {
        swapRouter.exactInputSingle(
            IBinRouterBase.BinSwapExactInputSingleParams({
                poolKey: key, swapForY: true, amountIn: 1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        uint256 fee = swapFeeHook.accruedFees(currency1);
        assertTrue(fee > 0, "Fee should be accrued on currency1");
    }

    /// swapForY false + exactInput → unspecified = currency0 (output) → fee on currency0
    function testSwapSwapForXExactInput_FeeOnCurrency0() public {
        swapRouter.exactInputSingle(
            IBinRouterBase.BinSwapExactInputSingleParams({
                poolKey: key, swapForY: false, amountIn: 1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        uint256 fee = swapFeeHook.accruedFees(currency0);
        assertTrue(fee > 0, "Fee should be accrued on currency0");
    }

    /// swapForY true + exactOutput → unspecified = currency0 (input) → fee on currency0
    function testSwapSwapForYExactOutput_FeeOnCurrency0() public {
        swapRouter.exactOutputSingle(
            IBinRouterBase.BinSwapExactOutputSingleParams({
                poolKey: key, swapForY: true, amountOut: 1e18, amountInMaximum: type(uint128).max, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        uint256 fee = swapFeeHook.accruedFees(currency0);
        assertTrue(fee > 0, "Fee should be accrued on currency0");
    }

    /// swapForY false + exactOutput → unspecified = currency1 (input) → fee on currency1
    function testSwapSwapForXExactOutput_FeeOnCurrency1() public {
        swapRouter.exactOutputSingle(
            IBinRouterBase.BinSwapExactOutputSingleParams({
                poolKey: key, swapForY: false, amountOut: 1e18, amountInMaximum: type(uint128).max, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        uint256 fee = swapFeeHook.accruedFees(currency1);
        assertTrue(fee > 0, "Fee should be accrued on currency1");
    }

    function testFeeAccrual() public {
        swapRouter.exactInputSingle(
            IBinRouterBase.BinSwapExactInputSingleParams({
                poolKey: key, swapForY: true, amountIn: 1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        uint256 firstFee = swapFeeHook.accruedFees(currency1);
        assertTrue(firstFee > 0, "First fee should be accrued");

        swapRouter.exactInputSingle(
            IBinRouterBase.BinSwapExactInputSingleParams({
                poolKey: key, swapForY: false, amountIn: 1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
        uint256 secondFee = swapFeeHook.accruedFees(currency0);
        assertTrue(secondFee > 0, "Second fee should be accrued");
    }

    function testFeeEventEmitted() public {
        vm.expectEmit(true, true, false, false);
        emit BinSwapFeeHook.FeeAccrued(id, currency1, 0);

        swapRouter.exactInputSingle(
            IBinRouterBase.BinSwapExactInputSingleParams({
                poolKey: key, swapForY: true, amountIn: 1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );
    }

    // ── Fee Withdrawal Tests ─────────────────────────────────────────────────

    function testWithdrawFees() public {
        swapRouter.exactInputSingle(
            IBinRouterBase.BinSwapExactInputSingleParams({
                poolKey: key, swapForY: true, amountIn: 1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 accruedFee = swapFeeHook.accruedFees(currency1);
        assertTrue(accruedFee > 0, "Should have accrued fees");

        uint256 balanceBefore = currency1.balanceOf(bob);
        swapFeeHook.withdrawFees(currency1, bob, accruedFee);
        uint256 balanceAfter = currency1.balanceOf(bob);

        assertEq(balanceAfter - balanceBefore, accruedFee, "Bob should receive accrued fees");
        assertEq(swapFeeHook.accruedFees(currency1), 0, "Accrued fees should be zero");
    }

    function testWithdrawFeesWithZeroAmount() public {
        swapRouter.exactInputSingle(
            IBinRouterBase.BinSwapExactInputSingleParams({
                poolKey: key, swapForY: true, amountIn: 1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 accruedFee = swapFeeHook.accruedFees(currency1);
        uint256 balanceBefore = currency1.balanceOf(bob);
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
        vm.expectRevert(BinSwapFeeHook.ZeroAddress.selector);
        swapFeeHook.withdrawFees(currency1, address(0), 100);
    }

    function testWithdrawFeesRevertsOnInsufficientBalance() public {
        vm.expectRevert(BinSwapFeeHook.InsufficientAccruedFees.selector);
        swapFeeHook.withdrawFees(currency1, bob, 100);
    }

    function testWithdrawFeesEvent() public {
        swapRouter.exactInputSingle(
            IBinRouterBase.BinSwapExactInputSingleParams({
                poolKey: key, swapForY: true, amountIn: 1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 accruedFee = swapFeeHook.accruedFees(currency1);
        vm.expectEmit(true, true, false, true);
        emit BinSwapFeeHook.FeesWithdrawn(currency1, bob, accruedFee);
        swapFeeHook.withdrawFees(currency1, bob, accruedFee);
    }

    // ── Ownership Transfer Tests ─────────────────────────────────────────────

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
        vm.expectRevert(BinSwapFeeHook.ZeroAddress.selector);
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
        swapRouter.exactInputSingle(
            IBinRouterBase.BinSwapExactInputSingleParams({
                poolKey: key, swapForY: true, amountIn: 1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
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
        swapRouter.exactInputSingle(
            IBinRouterBase.BinSwapExactInputSingleParams({
                poolKey: key, swapForY: true, amountIn: 1e18, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        swapFeeHook.transferOwnership(alice);
        vm.prank(alice);
        swapFeeHook.acceptOwnership();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        swapFeeHook.withdrawFees(currency1, bob, 100);
    }

    // ── Fee magnitude ───────────────────────────────────────────────────────

    function testFeeIsReasonable() public {
        uint128 amountIn = 1e18;
        swapRouter.exactInputSingle(
            IBinRouterBase.BinSwapExactInputSingleParams({
                poolKey: key, swapForY: true, amountIn: amountIn, amountOutMinimum: 0, hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        uint256 accrued = swapFeeHook.accruedFees(currency1);
        assertTrue(accrued > 0, "Fee should be accrued");
        assertLe(accrued, 1e18, "Fee should not exceed swap size");
    }
}

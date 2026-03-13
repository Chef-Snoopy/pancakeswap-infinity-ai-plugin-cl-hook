// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BinBaseHook} from "infinity-hooks/src/pool-bin/BinBaseHook.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title BinSwapFeeHook
/// @notice PancakeSwap Infinity Bin hook that charges a 0.1% protocol fee on every swap.
/// @dev Fee is taken from the *unspecified* token:
///        - exactInput  → deducted from user's output (user receives less)
///        - exactOutput → added to user's cost     (user pays more)
///      afterSwap returns the fee amount so the PoolManager deducts it from the user's
///      settlement. The hook simultaneously mints vault ERC-6909 claims to itself to
///      settle its own delta. Accrued claims are withdrawn by the owner at any time
///      via withdrawFees(), which burns the claims and calls vault.take().
contract BinSwapFeeHook is BinBaseHook, Ownable2Step {
    using PoolIdLibrary for PoolKey;

    // ── Constants ───────────────────────────────────────────────────────────

    /// @notice 0.1% fee — 10 bps (10 / 10_000)
    uint256 private constant FEE_BIPS = 10;
    uint256 private constant FEE_DENOMINATOR = 10_000;

    // ── State ────────────────────────────────────────────────────────────────

    /// @notice Accumulated vault ERC-6909 credits per currency, claimable by owner
    mapping(Currency currency => uint256 amount) public accruedFees;

    // ── Events ───────────────────────────────────────────────────────────────

    event FeeAccrued(PoolId indexed poolId, Currency indexed currency, uint256 amount);
    event FeesWithdrawn(Currency indexed currency, address indexed recipient, uint256 amount);

    // ── Errors ───────────────────────────────────────────────────────────────

    error ZeroAddress();
    error InsufficientAccruedFees();

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(IBinPoolManager _poolManager) BinBaseHook(_poolManager) Ownable(msg.sender) {}

    // ── Permissions ───────────────────────────────────────────────────────────

    /// @notice Returns the hook's registration bitmap
    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeMint: false,
                afterMint: false,
                beforeBurn: false,
                afterBurn: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: true,
                afterMintReturnDelta: false,
                afterBurnReturnDelta: false
            })
        );
    }

    // ── Hook Callback ────────────────────────────────────────────────────────

    /// @notice Deducts 0.1% from the unspecified token of every swap.
    /// @param key             Pool key.
    /// @param swapForY        If true, swap X for Y (token0 for token1); else Y for X.
    /// @param amountSpecified Negative = exactInput, positive = exactOutput.
    /// @param delta           Actual balance changes from the swap (from the pool's perspective).
    /// @return                Function selector, and fee amount to deduct from unspecified token.
    function afterSwap(
        address,
        PoolKey calldata key,
        bool swapForY,
        int128 amountSpecified,
        BalanceDelta delta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, int128) {
        // ── 1. Identify the unspecified currency ───────────────────────────
        //
        // swapForY + exactInput  → unspecified = currency1 (output)
        // swapForY + exactOutput → unspecified = currency0 (input)
        // swapX for Y + exactInput  → unspecified = currency1
        // Pattern: unspecified is currency1 when (swapForY == exactInput)
        bool exactInput = amountSpecified < 0;
        bool unspecifiedIsCurrency1 = (swapForY == exactInput);

        Currency feeCurrency = unspecifiedIsCurrency1 ? key.currency1 : key.currency0;
        int128 unspecifiedDelta = unspecifiedIsCurrency1 ? delta.amount1() : delta.amount0();

        // ── 2. Compute absolute unspecified amount ──────────────────────────
        uint256 unspecifiedAbs =
            unspecifiedDelta < 0 ? uint256(uint128(-unspecifiedDelta)) : uint256(uint128(unspecifiedDelta));

        // ── 3. Calculate fee ────────────────────────────────────────────────
        uint256 fee = (unspecifiedAbs * FEE_BIPS) / FEE_DENOMINATOR;
        if (fee == 0) return (this.afterSwap.selector, 0);

        // ── 4. Delta accounting ─────────────────────────────────────────────
        accruedFees[feeCurrency] += fee;
        vault.mint(address(this), feeCurrency, fee);

        emit FeeAccrued(key.toId(), feeCurrency, fee);

        return (this.afterSwap.selector, int128(uint128(fee)));
    }

    // ── Vault Lock Callback ──────────────────────────────────────────────────

    /// @notice Executed by the vault during fee withdrawal (see withdrawFees).
    /// @dev Burns the hook's ERC-6909 claims and forwards underlying tokens to recipient.
    function lockAcquired(bytes calldata data) external override vaultOnly returns (bytes memory) {
        (Currency currency, address recipient, uint256 amount) = abi.decode(data, (Currency, address, uint256));

        vault.burn(address(this), currency, amount);
        vault.take(currency, recipient, amount);

        return abi.encode(true);
    }

    // ── Owner: Fee Withdrawal ────────────────────────────────────────────────

    /// @notice Withdraw accumulated protocol fees to `recipient`.
    /// @param currency  Token to withdraw.
    /// @param recipient Destination address; must not be zero.
    /// @param amount    How much to withdraw; pass 0 to withdraw entire balance.
    function withdrawFees(Currency currency, address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();

        uint256 available = accruedFees[currency];
        if (amount == 0) amount = available;
        if (amount > available) revert InsufficientAccruedFees();

        accruedFees[currency] = available - amount;

        vault.lock(abi.encode(currency, recipient, amount));

        emit FeesWithdrawn(currency, recipient, amount);
    }

    /// @notice Override to disallow transferring ownership to zero address.
    function transferOwnership(address newOwner) public virtual override(Ownable2Step) {
        if (newOwner == address(0)) revert ZeroAddress();
        super.transferOwnership(newOwner);
    }
}

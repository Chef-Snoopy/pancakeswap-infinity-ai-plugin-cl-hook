// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {CLSwapFeeHook} from "../src/CLSwapFeeHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

/**
 * Deploy CLSwapFeeHook (0.1% swap fee hook for PancakeSwap Infinity CL).
 *
 * Prerequisites:
 *   - Copy .env.example to .env and set RPC_URL, PRIVATE_KEY, CL_POOL_MANAGER
 *   - CL_POOL_MANAGER must be the existing Infinity CL PoolManager address on the target chain
 *
 * Deploy:
 *   forge script script/DeployCLSwapFeeHook.s.sol:DeployCLSwapFeeHook --rpc-url $RPC_URL --broadcast
 *
 * Deploy and verify (Etherscan):
 *   forge script script/DeployCLSwapFeeHook.s.sol:DeployCLSwapFeeHook \
 *     --rpc-url $RPC_URL --broadcast --verify
 *
 * Verify after deploy:
 *   forge verify-contract <HOOK_ADDRESS> CLSwapFeeHook --chain-id <CHAIN_ID> \
 *     --constructor-args $(cast abi-encode "constructor(address)" "$CL_POOL_MANAGER")
 */
contract DeployCLSwapFeeHook is Script {
    function run() public {
        address clPoolManager = vm.envAddress("CL_POOL_MANAGER");

        vm.startBroadcast();

        CLSwapFeeHook hook = new CLSwapFeeHook(ICLPoolManager(clPoolManager));

        vm.stopBroadcast();

        console.log("CLSwapFeeHook deployed at:", address(hook));
        console.log("Admin:", hook.admin());
    }
}

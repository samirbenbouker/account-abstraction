// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {MinimalAccount} from "src/ethereum/MinimalAccount.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

/**
 * @title DeployMinimal
 * @notice Foundry deployment script for the `MinimalAccount` contract.
 * @dev
 *  - This script is intended to be run with `forge script`.
 *  - It deploys a `MinimalAccount` using network-specific configuration
 *    provided by `HelperConfig`.
 *  - Ownership of the deployed account is transferred to the configured EOA.
 */
contract DeployMinimal is Script {
    /**
     * @notice Entry point for `forge script`.
     * @dev
     *  - Intentionally left empty.
     *  - Deployment logic is contained in `deployMinimalAccount`
     *    so it can be reused by tests or other scripts.
     */
    function run() public {}

    /**
     * @notice Deploys a `MinimalAccount` using the current network configuration.
     * @dev
     *  Steps:
     *   1. Instantiate `HelperConfig` to load per-network parameters.
     *   2. Fetch the active `NetworkConfig` (e.g. EntryPoint address, deployer account).
     *   3. Broadcast transactions using the configured deployer account.
     *   4. Deploy `MinimalAccount` with the configured EntryPoint.
     *   5. Transfer ownership of the account to the configured EOA.
     *
     * @return helperConfig The HelperConfig instance used for deployment.
     * @return minimalAccount The newly deployed MinimalAccount contract.
     */
    function deployMinimalAccount() public returns (HelperConfig, MinimalAccount) {
        // @dev Load helper config which resolves network-specific values.
        HelperConfig helperConfig = new HelperConfig();

        // @dev Retrieve the active network configuration (entry point, deployer, etc).
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();

        // @dev Start broadcasting transactions from the configured deployer account.
        vm.startBroadcast(config.account);

        // @dev Deploy the MinimalAccount pointing to the network's EntryPoint.
        MinimalAccount minimalAccount = new MinimalAccount(config.entryPoint);

        // @dev Transfer ownership to the configured EOA (account abstraction owner).
        minimalAccount.transferOwnership(config.account);

        // @dev Stop broadcasting transactions.
        vm.stopBroadcast();

        // @dev Return deployed instances for reuse in tests or other scripts.
        return (helperConfig, minimalAccount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";

/**
 * @title HelperConfig
 * @notice Centralized network configuration helper for scripts and tests.
 * @dev
 *  - Provides per-chain configuration such as EntryPoint address and deployer/owner account.
 *  - Designed to be reused across `script/` and `test/` folders.
 *  - Automatically deploys mock contracts (EntryPoint) for local Anvil/Foundry networks.
 */
contract HelperConfig is Script {
    //////////////
    /// ERRORS ///
    //////////////
    /// @notice Reverts when no configuration exists for the active chain ID.
    error HelperConfig__InvalidChainId();

    //////////////////////
    /// STRUCTS ///
    //////////////////////
    /**
     * @notice Network-specific configuration used by deployment scripts.
     * @param entryPoint ERC-4337 EntryPoint address for the network.
     * @param account EOA used for broadcasting transactions / ownership.
     */
    struct NetworkConfig {
        address entryPoint;
        address account;
    }

    //////////////////////
    /// CONSTANTS ///
    //////////////////////
    /// @notice Ethereum Sepolia testnet chain ID.
    uint256 constant ETH_SEPOLIA_CHAIN_ID = 11155111;
    /// @notice zkSync Sepolia testnet chain ID.
    uint256 constant ZKSYNC_SEPOLIA_CHAIN_ID = 300;
    /// @notice Arbitrum One mainnet chain ID.
    uint256 constant ARBITRUM_MAINNET_CHAIN_ID = 42_161;
    /// @notice Local Anvil / Foundry chain ID.
    uint256 constant LOCAL_CHAIN_ID = 31337;

    /// @notice Burner wallet used for public testnets.
    /// @dev Never use for production funds.
    address constant BURNER_WALLET = 0xdBe588e8A3082b25E3Ee08b42f93FF44E80Fa057;

    //address constant FOUNDRY_DEFAULT_WALLET = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    /// @notice Default Anvil wallet (index 0) used for local development.
    address constant ANVIL_DEFAULT_WALLET = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    //////////////////////
    /// STORAGE ///
    //////////////////////
    /// @notice Cached local network configuration (Anvil).
    NetworkConfig public localNetworkConfig;

    /// @notice Mapping of chainId to network configuration.
    mapping(uint256 chainId => NetworkConfig) public networkConfigs;

    //////////////////////
    /// CONSTRUCTOR ///
    //////////////////////
    /**
     * @notice Initializes known network configurations.
     * @dev
     *  - Preloads configs for public networks.
     *  - Local network config is created lazily on first access.
     */
    constructor() {
        networkConfigs[ETH_SEPOLIA_CHAIN_ID] = getEthSepoliaConfig();
        networkConfigs[ZKSYNC_SEPOLIA_CHAIN_ID] = getZksyncSepoliaConfig();
        networkConfigs[ARBITRUM_MAINNET_CHAIN_ID] = getArbMainnetConfig();
    }

    //////////////////////
    /// EXTERNAL / PUBLIC ///
    //////////////////////
    /**
     * @notice Returns the active network configuration based on `block.chainid`.
     * @return NetworkConfig for the current chain.
     */
    function getConfig() public returns (NetworkConfig memory) {
        return getConfigByChainId(block.chainid);
    }

    /**
     * @notice Returns network configuration for a given chain ID.
     * @param chainId The chain ID to resolve configuration for.
     * @return NetworkConfig matching the chain ID.
     */
    function getConfigByChainId(uint256 chainId) public returns (NetworkConfig memory) {
        if (chainId == LOCAL_CHAIN_ID) {
            // @dev Lazily deploy mocks for local development.
            return getOrCreateNetworkConfig();
        } else if (networkConfigs[chainId].account != address(0)) {
            // @dev Return preconfigured public network settings.
            return networkConfigs[chainId];
        } else {
            revert HelperConfig__InvalidChainId();
        }
    }

    //////////////////////
    /// NETWORK CONFIGS ///
    //////////////////////
    /**
     * @notice Ethereum Sepolia network configuration.
     */
    function getEthSepoliaConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            entryPoint: 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789,
            account: BURNER_WALLET
        });
    }

    /**
     * @notice Arbitrum One mainnet configuration.
     */
    function getArbMainnetConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            entryPoint: 0x0000000071727De22E5E9d8BAf0edAc6f37da032,
            //usdc: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            account: BURNER_WALLET
        });
    }

    /**
     * @notice zkSync Sepolia network configuration.
     * @dev EntryPoint is set to address(0) since zkSync uses native AA
     *      and does not rely on the ERC-4337 EntryPoint contract.
     */
    function getZksyncSepoliaConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({entryPoint: address(0), account: BURNER_WALLET});
    }

    //////////////////////
    /// LOCAL DEV ///
    //////////////////////
    /**
     * @notice Returns or deploys local (Anvil) network configuration.
     * @dev
     *  - Deploys a mock ERC-4337 EntryPoint contract on first call.
     *  - Caches the result to avoid redeploying on subsequent calls.
     *
     * @return NetworkConfig for the local development chain.
     */
    function getOrCreateNetworkConfig() public returns (NetworkConfig memory) {
        // @dev Return cached config if already initialized.
        if (localNetworkConfig.account != address(0)) {
            return localNetworkConfig;
        }

        // deploy a mock entry point contract
        console2.log("Deploying mocks...");
        vm.startBroadcast(ANVIL_DEFAULT_WALLET);
        EntryPoint entryPoint = new EntryPoint();
        vm.stopBroadcast();

        // @dev Cache local configuration.
        localNetworkConfig = NetworkConfig({
            entryPoint: address(entryPoint),
            account: ANVIL_DEFAULT_WALLET
        });

        return localNetworkConfig;
    }
}

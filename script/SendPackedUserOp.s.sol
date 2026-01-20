// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MinimalAccount} from "src/ethereum/MinimalAccount.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

/**
 * @title SendPackedUserOp
 * @notice Foundry script that builds, signs, and submits an ERC-4337 PackedUserOperation.
 * @dev
 *  - Demonstrates how to manually construct a UserOperation for a `MinimalAccount`.
 *  - Encodes a call to `MinimalAccount.execute`, which itself calls an ERC20 `approve`.
 *  - Signs the UserOperation using Foundry cheatcodes and submits it via EntryPoint.
 */
contract SendPackedUserOp is Script {
    using MessageHashUtils for bytes32;

    //////////////////////
    /// CONSTANTS ///
    //////////////////////
    /// @notice USDC contract address on Arbitrum One.
    address constant ARBITRUM_MAINNET_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// @notice Default Anvil wallet used for local testing.
    address constant ANVIL_DEFAULT_WALLET = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    /// @notice Deployed MinimalAccount address on Arbitrum (example).
    /// @dev Replace with your own deployed account address when running the script.
    address constant MINIMAL_ACCOUNT_ARBITRUM = 0x03Ad95a54f02A40180D45D76789C448024145aaF;

    //////////////////////
    /// SCRIPT ENTRY ///
    //////////////////////
    /**
     * @notice Builds and submits a single PackedUserOperation via EntryPoint.
     * @dev
     *  Flow:
     *   1. Load network configuration (EntryPoint + account).
     *   2. Encode an ERC20 `approve` call.
     *   3. Wrap it in `MinimalAccount.execute`.
     *   4. Generate and sign a PackedUserOperation.
     *   5. Submit it to EntryPoint using `handleOps`.
     */
    function run() public {
        // @dev Load network-specific configuration.
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();

        // @dev Target contract for the inner call (USDC).
        address dest = ARBITRUM_MAINNET_USDC;
        uint256 value = 0;

        // @dev Encode ERC20 approve(spender, amount).
        // use your mainnet arbitrum wallet
        bytes memory functionData =
            abi.encodeWithSelector(IERC20.approve.selector, ANVIL_DEFAULT_WALLET, 1e18);

        // @dev Encode MinimalAccount.execute(dest, value, functionData).
        bytes memory executeCalldata =
            abi.encodeWithSelector(MinimalAccount.execute.selector, dest, value, functionData);

        // this minimal account address its from cyfrin updraft, deploy using script and put your address here
        PackedUserOperation memory userOp =
            generateSignedUserOperation(executeCalldata, config, MINIMAL_ACCOUNT_ARBITRUM);

        // @dev EntryPoint expects an array of UserOperations.
        PackedUserOperation;
        ops[0] = userOp;

        // @dev Broadcast the transaction that submits the UserOperation.
        vm.startBroadcast();
        IEntryPoint(config.entryPoint).handleOps(ops, payable(config.account));
        vm.stopBroadcast();
    }

    //////////////////////
    /// USEROP HELPERS ///
    //////////////////////
    /**
     * @notice Generates and signs a PackedUserOperation.
     * @dev
     *  Steps:
     *   1. Fetch the current nonce from EntryPoint.
     *   2. Build an unsigned UserOperation.
     *   3. Compute the UserOperation hash.
     *   4. Sign the hash and attach the signature.
     *
     * @param callData Encoded calldata for `MinimalAccount.execute`.
     * @param config Network configuration (EntryPoint + signer account).
     * @param minimalAccount Address of the smart account (sender).
     * @return userOp Fully signed PackedUserOperation.
     */
    function generateSignedUserOperation(
        bytes memory callData,
        HelperConfig.NetworkConfig memory config,
        address minimalAccount
    ) public view returns (PackedUserOperation memory) {
        // 1. Generate the unsigned data
        uint256 nonce = IEntryPoint(config.entryPoint).getNonce(minimalAccount, 0);
        PackedUserOperation memory userOp = _generateUnsignedUserOperation(callData, minimalAccount, nonce);

        // 2. Get the userOp hash (as defined by ERC-4337 EntryPoint)
        bytes32 userOpHash = IEntryPoint(config.entryPoint).getUserOpHash(userOp);
        bytes32 digest = userOpHash.toEthSignedMessageHash();

        // 3. Sign it and return it
        // foundry using vm.sign what we can do its,
        // pass the address from account,
        // and foundry will check if have's his private key
        uint8 v;
        bytes32 r;
        bytes32 s;

        // @dev Default private key for Anvil (chainId 31337).
        uint256 ANVIL_DEFAULT_PRIVATE_KEY =
            0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

        if (block.chainid == 31337) {
            // @dev Sign using known Anvil private key.
            (v, r, s) = vm.sign(ANVIL_DEFAULT_PRIVATE_KEY, digest);
        } else {
            // @dev Sign using the configured account (must be unlocked in Foundry).
            (v, r, s) = vm.sign(config.account, digest);
        }

        // @dev Signature format: r || s || v (ERC-4337 expected order).
        userOp.signature = abi.encodePacked(r, s, v);
        return userOp;
    }

    /**
     * @notice Builds an unsigned PackedUserOperation with fixed gas parameters.
     * @dev
     *  - Gas fields are packed according to ERC-4337 spec.
     *  - No initCode or paymaster is used in this example.
     *
     * @param callData Encoded calldata for execution.
     * @param sender Address of the smart account.
     * @param nonce Current nonce for the account.
     * @return userOp Unsigned PackedUserOperation.
     */
    function _generateUnsignedUserOperation(bytes memory callData, address sender, uint256 nonce)
        internal
        pure
        returns (PackedUserOperation memory)
    {
        uint128 verificationGasLimit = 16_777_216;
        uint128 callGasLimit = verificationGasLimit;
        uint128 maxPriorityFeePerGas = 256;
        uint128 maxFeePerGas = maxPriorityFeePerGas;

        return PackedUserOperation({
            sender: sender,
            nonce: nonce,
            initCode: hex"",
            callData: callData,
            accountGasLimits: bytes32(uint256(verificationGasLimit) << 128 | callGasLimit),
            preVerificationGas: verificationGasLimit,
            gasFees: bytes32(uint256(maxPriorityFeePerGas) << 128 | maxFeePerGas),
            paymasterAndData: hex"",
            signature: hex""
        });
    }
}

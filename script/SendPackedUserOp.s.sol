// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MinimalAccount} from "src/ethereum/MinimalAccount.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

contract SendPackedUserOp is Script {
    using MessageHashUtils for bytes32;

    address constant ARBITRUM_MAINNET_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ANVIL_DEFAULT_WALLET = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant MINIMAL_ACCOUNT_ARBITRUM = 0x03Ad95a54f02A40180D45D76789C448024145aaF;

    function run() public {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        address dest = ARBITRUM_MAINNET_USDC;
        uint256 value = 0;
        // use your mainnet arbitrum wallet
        bytes memory functionData = abi.encodeWithSelector(IERC20.approve.selector, ANVIL_DEFAULT_WALLET, 1e18);
        bytes memory executeCalldata =
            abi.encodeWithSelector(MinimalAccount.execute.selector, dest, value, functionData);
        // this minimal account address its from cyfrin updraft, deploy using script and put your address here
        PackedUserOperation memory userOp =
            generateSignedUserOperation(executeCalldata, config, MINIMAL_ACCOUNT_ARBITRUM);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        vm.startBroadcast();
        IEntryPoint(config.entryPoint).handleOps(ops, payable(config.account));
        vm.stopBroadcast();
    }

    function generateSignedUserOperation(
        bytes memory callData,
        HelperConfig.NetworkConfig memory config,
        address minimalAccount
    ) public view returns (PackedUserOperation memory) {
        // 1. Generate the unsigned data
        uint256 nonce = IEntryPoint(config.entryPoint).getNonce(minimalAccount, 0);
        PackedUserOperation memory userOp = _generateUnsignedUserOperation(callData, minimalAccount, nonce);

        // 2. Get the userOp hash
        bytes32 userOpHash = IEntryPoint(config.entryPoint).getUserOpHash(userOp);
        bytes32 digest = userOpHash.toEthSignedMessageHash();

        // 3. Sign it and return it
        // foundry using vm.sign what we can do its,
        // pass the address from account,
        // and foundry will check if have's his private key
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint256 ANVIL_DEFAULT_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        if (block.chainid == 31337) {
            (v, r, s) = vm.sign(ANVIL_DEFAULT_PRIVATE_KEY, digest);
        } else {
            (v, r, s) = vm.sign(config.account, digest);
        }
        userOp.signature = abi.encodePacked(r, s, v); // note the order
        return userOp;
    }

    function _generateUnsignedUserOperation(bytes memory callData, address sender, uint256 nonce)
        internal
        pure
        returns (PackedUserOperation memory)
    {
        uint128 verificationGasLimit = 16777216;
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

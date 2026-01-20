// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ZkMinimalAccount} from "src/zksync/ZkMinimalAccount.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    Transaction,
    MemoryTransactionHelper
} from "@foundry-era-contracts/src/system-contracts/contracts/libraries/MemoryTransactionHelper.sol";
import {BOOTLOADER_FORMAL_ADDRESS} from "@foundry-era-contracts/src/system-contracts/contracts/Constants.sol";
import {
    ACCOUNT_VALIDATION_SUCCESS_MAGIC
} from "@foundry-era-contracts/src/system-contracts/contracts/interfaces/IAccount.sol";

contract ZkMinimalAccountTest is Test {
    using MessageHashUtils for bytes32;

    ZkMinimalAccount minimalAccount;
    ERC20Mock usdc;

    uint256 constant AMOUNT = 1 ether;
    bytes32 constant EMPTY_BYTES32 = bytes32(0);
    address constant ANVIL_DEFAULT_WALLET = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    function setUp() public {
        minimalAccount = new ZkMinimalAccount();
        minimalAccount.transferOwnership(ANVIL_DEFAULT_WALLET);
        usdc = new ERC20Mock();

        vm.deal(address(minimalAccount), AMOUNT);
    }

    function testZkOwnerCanExecuteCommands() public {
        address dest = address(usdc);
        uint256 value = 0;
        bytes memory functionData = abi.encodeWithSelector(usdc.mint.selector, address(minimalAccount), AMOUNT);

        uint8 transactionType = 113;
        Transaction memory transaction =
            _createUnsigendTransaction(minimalAccount.owner(), transactionType, dest, value, functionData);

        vm.prank(minimalAccount.owner());
        minimalAccount.executeTransaction(EMPTY_BYTES32, EMPTY_BYTES32, transaction);

        assertEq(usdc.balanceOf(address(minimalAccount)), AMOUNT);
    }

    function testZkValidateTransaction() public {
        address dest = address(usdc);
        uint256 value = 0;
        bytes memory functionData = abi.encodeWithSelector(usdc.mint.selector, address(minimalAccount), AMOUNT);

        uint8 transactionType = 113;
        Transaction memory transaction =
            _createUnsigendTransaction(minimalAccount.owner(), transactionType, dest, value, functionData);
        transaction = _signTransaction(transaction);

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        bytes4 magic = minimalAccount.validateTransaction(EMPTY_BYTES32, EMPTY_BYTES32, transaction);

        assertEq(magic, ACCOUNT_VALIDATION_SUCCESS_MAGIC);
    }

    ///////////////
    /// HELPERS ///
    ///////////////
    function _signTransaction(Transaction memory transaction) internal view returns (Transaction memory) {
        bytes32 unsigendTransactionHash = MemoryTransactionHelper.encodeHash(transaction);
        bytes32 digest = unsigendTransactionHash.toEthSignedMessageHash();

        // we dont check if local or external because currently script with zkSync dont works, and can assume will run only localy
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint256 ANVIL_DEFAULT_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        (v, r, s) = vm.sign(ANVIL_DEFAULT_PRIVATE_KEY, digest);

        Transaction memory signedTransaction = transaction;
        signedTransaction.signature = abi.encodePacked(r, s, v);

        return signedTransaction;
    }

    function _createUnsigendTransaction(
        address from,
        uint8 transactionType,
        address to,
        uint256 value,
        bytes memory data
    ) internal view returns (Transaction memory) {
        uint256 nonce = vm.getNonce(address(minimalAccount));
        bytes32[] memory factoryDeps = new bytes32[](0);

        return Transaction({
            txType: transactionType,
            from: uint256(uint160(from)),
            to: uint256(uint160(to)),
            gasLimit: 16777216,
            gasPerPubdataByteLimit: 16777216,
            maxFeePerGas: 16777216,
            maxPriorityFeePerGas: 16777216,
            paymaster: 0,
            nonce: nonce,
            value: value,
            reserved: [uint256(0), uint256(0), uint256(0), uint256(0)],
            data: data,
            signature: hex"",
            factoryDeps: factoryDeps,
            paymasterInput: hex"",
            reservedDynamic: hex""
        });
    }
}

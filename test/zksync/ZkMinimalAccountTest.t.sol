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

/**
 * @title ZkMinimalAccountTest
 * @notice Test suite for `ZkMinimalAccount` (zkSync Era native AA account).
 * @dev
 *  Covers:
 *   - Owner path execution (calling `executeTransaction` as owner).
 *   - Bootloader validation path (`validateTransaction` called by bootloader).
 *
 *  Notes:
 *   - zkSync native AA uses `Transaction` (type 113 / 0x71) instead of ERC-4337 UserOperation.
 *   - The bootloader is the entry point system contract that performs validation and execution.
 */
contract ZkMinimalAccountTest is Test {
    using MessageHashUtils for bytes32;

    ///////////////////////
    /// TEST FIXTURES ///
    ///////////////////////
    /// @notice The zkSync native AA account under test.
    ZkMinimalAccount minimalAccount;
    /// @notice Mock ERC20 used to validate execution (mint).
    ERC20Mock usdc;

    ///////////////////////
    /// CONSTANTS ///
    ///////////////////////
    /// @notice Mint amount used across tests.
    uint256 constant AMOUNT = 1 ether;
    /// @notice Convenience constant passed for unused hash params in AA interface.
    bytes32 constant EMPTY_BYTES32 = bytes32(0);
    /// @notice Default Anvil wallet used as owner in local tests.
    address constant ANVIL_DEFAULT_WALLET = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    /**
     * @notice Deploys a fresh account + ERC20 mock and funds the account with ETH.
     * @dev
     *  - Deploys `ZkMinimalAccount`.
     *  - Sets owner to the Anvil default wallet (so we can sign/execute in tests).
     *  - Funds the account so validation can pass balance checks and execution can pay fees if needed.
     */
    function setUp() public {
        minimalAccount = new ZkMinimalAccount();
        minimalAccount.transferOwnership(ANVIL_DEFAULT_WALLET);

        usdc = new ERC20Mock();

        // @dev Provide ETH to the account to satisfy fee/balance checks.
        vm.deal(address(minimalAccount), AMOUNT);
    }

    /**
     * @notice Owner can execute transactions via the owner pathway.
     * @dev
     *  - Builds a type 113 zkSync Transaction that calls ERC20Mock.mint via account execution.
     *  - Calls `executeTransaction` as the owner (allowed by `requireFromBootLoaderOrOwner`).
     *  - Verifies the mint succeeded.
     */
    function testZkOwnerCanExecuteCommands() public {
        // Arrange: target call
        address dest = address(usdc);
        uint256 value = 0;
        bytes memory functionData =
            abi.encodeWithSelector(usdc.mint.selector, address(minimalAccount), AMOUNT);

        // Arrange: create zkSync transaction (type 113)
        uint8 transactionType = 113;
        Transaction memory transaction =
            _createUnsigendTransaction(minimalAccount.owner(), transactionType, dest, value, functionData);

        // Act: call executeTransaction as owner (not bootloader)
        vm.prank(minimalAccount.owner());
        minimalAccount.executeTransaction(EMPTY_BYTES32, EMPTY_BYTES32, transaction);

        // Assert: ERC20 minted to account
        assertEq(usdc.balanceOf(address(minimalAccount)), AMOUNT);
    }

    /**
     * @notice validateTransaction returns the success magic value for a correctly signed transaction.
     * @dev
     *  - Builds a type 113 transaction calling ERC20Mock.mint.
     *  - Signs it using the test private key.
     *  - Calls `validateTransaction` as the bootloader address (required).
     *  - Expects `ACCOUNT_VALIDATION_SUCCESS_MAGIC` on success.
     */
    function testZkValidateTransaction() public {
        // Arrange: target call
        address dest = address(usdc);
        uint256 value = 0;
        bytes memory functionData =
            abi.encodeWithSelector(usdc.mint.selector, address(minimalAccount), AMOUNT);

        // Arrange: create + sign zkSync transaction (type 113)
        uint8 transactionType = 113;
        Transaction memory transaction =
            _createUnsigendTransaction(minimalAccount.owner(), transactionType, dest, value, functionData);
        transaction = _signTransaction(transaction);

        // Act: bootloader calls validation
        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        bytes4 magic = minimalAccount.validateTransaction(EMPTY_BYTES32, EMPTY_BYTES32, transaction);

        // Assert: success magic returned
        assertEq(magic, ACCOUNT_VALIDATION_SUCCESS_MAGIC);
    }

    ///////////////
    /// HELPERS ///
    ///////////////

    /**
     * @notice Signs a zkSync `Transaction` using Foundry's `vm.sign`.
     * @dev
     *  - Computes the transaction hash using `MemoryTransactionHelper.encodeHash`.
     *  - Produces an ECDSA signature `(r,s,v)` and packs it into `transaction.signature`.
     *  - This test assumes local execution only (Anvil private key is used).
     *
     * @param transaction Unsigned transaction object.
     * @return signedTransaction The same transaction with `signature` populated.
     */
    function _signTransaction(Transaction memory transaction) internal view returns (Transaction memory) {
        bytes32 unsigendTransactionHash = MemoryTransactionHelper.encodeHash(transaction);
        //bytes32 digest = unsigendTransactionHash.toEthSignedMessageHash();

        // we dont check if local or external because currently script with zkSync dont works, and can assume will run only localy
        uint8 v;
        bytes32 r;
        bytes32 s;

        // @dev Default Anvil private key (ONLY for local testing).
        uint256 ANVIL_DEFAULT_PRIVATE_KEY =
            0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

        // @dev Sign the digest expected by the account implementation.
        (v, r, s) = vm.sign(ANVIL_DEFAULT_PRIVATE_KEY, digest);

        Transaction memory signedTransaction = transaction;
        signedTransaction.signature = abi.encodePacked(r, s, v);

        return signedTransaction;
    }

    /**
     * @notice Creates an unsigned zkSync type 113 `Transaction`.
     * @dev
     *  - Uses `vm.getNonce(address(minimalAccount))` to derive the current nonce.
     *  - Sets `factoryDeps` to empty (no deployments).
     *  - Sets large gas parameters for simplicity in tests.
     *
     * @param from The address that is considered the transaction signer/sender (owner).
     * @param transactionType zkSync transaction type (113 for native AA).
     * @param to Target address the account will call.
     * @param value ETH value to send with the call.
     * @param data Calldata for the call.
     * @return transaction Unsigned transaction ready to be signed.
     */
    function _createUnsigendTransaction(
        address from,
        uint8 transactionType,
        address to,
        uint256 value,
        bytes memory data
    ) internal view returns (Transaction memory) {
        // @dev Nonce for zkSync AA transactions (kept in NonceHolder system contract).
        uint256 nonce = vm.getNonce(address(minimalAccount));

        // @dev Empty factory deps means no contract bytecode dependencies are included.
        bytes32;

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

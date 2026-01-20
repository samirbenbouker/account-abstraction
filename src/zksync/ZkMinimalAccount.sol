// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {
    IAccount,
    ACCOUNT_VALIDATION_SUCCESS_MAGIC
} from "@foundry-era-contracts/src/system-contracts/contracts/interfaces/IAccount.sol";
import {
    Transaction,
    MemoryTransactionHelper
} from "@foundry-era-contracts/src/system-contracts/contracts/libraries/MemoryTransactionHelper.sol";
import {
    SystemContractsCaller
} from "@foundry-era-contracts/src/system-contracts/contracts/libraries/SystemContractsCaller.sol";
import {
    NONCE_HOLDER_SYSTEM_CONTRACT,
    BOOTLOADER_FORMAL_ADDRESS,
    DEPLOYER_SYSTEM_CONTRACT
} from "@foundry-era-contracts/src/system-contracts/contracts/Constants.sol";
import {INonceHolder} from "@foundry-era-contracts/src/system-contracts/contracts/interfaces/INonceHolder.sol";
import {Utils} from "@foundry-era-contracts/src/system-contracts/contracts/libraries/Utils.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 *     Lifecycle of a type 113 (0x71) transaction
 *     msg.sender is the bootloader system contract (entry point)
 *
 *     Phase1 Validation
 *     1. The user send the transaction to the "zkSync API client" (sort of a "light node")
 *     2. The zkSync API Client check to see the nonce is unique by querying the NonceHolder system contrat
 *     3. The zkSync API Client calls validateTransaction, which MUST update the nonce
 *     4. The zkSync API Client checks the nonce is updated
 *     5. The zkSync API Client calls payForTransaction, or prepareForPaymaster & validateAndPayForPaymasterTransaction
 *     6. The zkSync API Client verifies that the bootloader (entry point) gets paid
 *
 *     Phase2 Execution
 *     7. The zkSync API Client passes the validated transaction to the main node / sequencer (as of today, they are the same)
 *     8. The main node calls executeTransaction
 *     9. If a paymaster was used, the postTransaction is called
 */
contract ZkMinimalAccount is IAccount, Ownable {
    using MemoryTransactionHelper for Transaction;

    //////////////
    /// ERRORS ///
    //////////////
    error ZkMinimalAccount__NotEnoughBalance();
    error ZkMinimalAccount__NotFromBootLoader();
    error ZkMinimalAccount__ExecutionFailed();
    error ZkMinimalAccount__NotFromBootLoaderOrOwner();
    error ZkMinimalAccount__FailedToPay();
    error ZkMinimalAccount__NotImplemented();

    /////////////////
    /// MODIFIERS ///
    /////////////////
    modifier requireFromBootLoader() {
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS) {
            revert ZkMinimalAccount__NotFromBootLoader();
        }
        _;
    }

    modifier requireFromBootLoaderOrOwner() {
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS && msg.sender != owner()) {
            revert ZkMinimalAccount__NotFromBootLoaderOrOwner();
        }
        _;
    }

    constructor() Ownable(msg.sender) {}

    receive() external payable {}

    //////////////////////////
    /// EXTERNAL FUNCTIONS ///
    //////////////////////////

    /**
     *     @notice must increase the nonce
     *     @notice must validate the transaction (check the owner sigend transaction)
     *     @notice also check to see if we have enough money in our account
     */
    function validateTransaction(
        bytes32,
        /*_txHash*/
        bytes32,
        /*_suggestedSignedHash*/
        Transaction calldata _transaction
    )
        external
        payable
        requireFromBootLoader
        returns (bytes4 magic)
    {
        _validateTransaction(_transaction);
    }

    function executeTransaction(
        bytes32,
        /*_txHash*/
        bytes32,
        /*_suggestedSignedHash*/
        Transaction calldata _transaction
    )
        external
        payable
        requireFromBootLoaderOrOwner
    {
        _validateTransaction(_transaction);
        _executeTransaction(_transaction);
    }

    // There is no point in providing possible signed hash in the `executeTransactionFromOutside` method,
    // since it typically should not be trusted.
    function executeTransactionFromOutside(Transaction calldata _transaction) external payable {
        _executeTransaction(_transaction);
    }

    function payForTransaction(bytes32 _txHash, bytes32 _suggestedSignedHash, Transaction calldata _transaction)
        external
        payable
    {
        (bool success) = _transaction.payToTheBootloader();

        if (!success) {
            revert ZkMinimalAccount__FailedToPay();
        }
    }

    function prepareForPaymaster(bytes32 _txHash, bytes32 _possibleSignedHash, Transaction calldata _transaction)
        external
        payable
    {
        revert ZkMinimalAccount__NotImplemented();
    }

    //////////////////////////
    /// INTERNAL FUNCTIONS ///
    //////////////////////////
    function _validateTransaction(Transaction memory _transaction) internal returns (bytes4 magic) {
        // Call nonceHolder
        // increment nonce
        // call(x, y, z) -> system contract call
        // We will increment nonce using system contract calls, where:
        // NONCE_HOLDER_SYSTEM_CONTRACT = nonce holder contract address
        // (_transaction.nonce) = current nonce we have in this contract
        SystemContractsCaller.systemCallWithPropagatedRevert(
            uint32(gasleft()),
            address(NONCE_HOLDER_SYSTEM_CONTRACT),
            0,
            abi.encodeCall(INonceHolder.incrementMinNonceIfEquals, (_transaction.nonce))
        );

        // Check for fee to pay
        uint256 totalRequiredBalance = _transaction.totalRequiredBalance();
        if (totalRequiredBalance > address(this).balance) {
            revert ZkMinimalAccount__NotEnoughBalance();
        }

        // Check the signature
        bytes32 txHash = _transaction.encodeHash(); // encode hash using MemoryTransactionHelper to correct hash
        //bytes32 convertedHash = MessageHashUtils.toEthSignedMessageHash(txHash);
        address signer = ECDSA.recover(convertedHash, _transaction.signature);
        bool isValidSigner = signer == owner();

        if (isValidSigner) {
            magic = ACCOUNT_VALIDATION_SUCCESS_MAGIC;
        } else {
            magic = bytes4(0);
        }

        // return the "magic" number
        return magic;
    }

    function _executeTransaction(Transaction memory _transaction) internal {
        address to = address(uint160(_transaction.to));
        uint128 value = Utils.safeCastToU128(_transaction.value);
        bytes memory data = _transaction.data;

        if (to == address(DEPLOYER_SYSTEM_CONTRACT)) {
            uint32 gas = Utils.safeCastToU32(gasleft());
            SystemContractsCaller.systemCallWithPropagatedRevert(gas, to, value, data);
        } else {
            bool success;
            // In zkSync when we want to make a execution, we need to make a low level call
            assembly {
                success := call(gas(), to, value, add(data, 0x20), mload(data), 0, 0)
            }

            if (!success) {
                revert ZkMinimalAccount__ExecutionFailed();
            }
        }
    }
}

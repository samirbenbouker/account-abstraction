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
 * @title ZkMinimalAccount
 * @notice Minimal zkSync Era native account-abstraction wallet implementing `IAccount`.
 * @dev
 *  - This contract is designed for zkSync Era’s native AA flow (type 113 / 0x71 tx).
 *  - The bootloader is the entry point that calls `validateTransaction` and `executeTransaction`.
 *  - The owner is the EOA that authorizes transactions via signature.
 *
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
    /// @notice Reverts when the account does not have enough ETH to cover required value + fees.
    error ZkMinimalAccount__NotEnoughBalance();
    /// @notice Reverts when a function restricted to the zkSync bootloader is called by any other address.
    error ZkMinimalAccount__NotFromBootLoader();
    /// @notice Reverts when a low-level call execution fails.
    error ZkMinimalAccount__ExecutionFailed();
    /// @notice Reverts when a function restricted to bootloader OR owner is called by another address.
    error ZkMinimalAccount__NotFromBootLoaderOrOwner();
    /// @notice Reverts when the bootloader fee payment fails.
    error ZkMinimalAccount__FailedToPay();
    /// @notice Reverts for unimplemented AA hooks (e.g., paymaster preparation).
    error ZkMinimalAccount__NotImplemented();
    /// @notice Reverts when a transaction signature is invalid for the current owner.
    error ZkMinimalAccount__InvalidSignature();

    /////////////////
    /// MODIFIERS ///
    /////////////////
    /**
     * @notice Ensures the caller is the zkSync bootloader (entry point).
     * @dev On zkSync Era native AA, validation/execution is invoked by the bootloader contract.
     */
    modifier requireFromBootLoader() {
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS) {
            revert ZkMinimalAccount__NotFromBootLoader();
        }
        _;
    }

    /**
     * @notice Ensures the caller is either the zkSync bootloader or the account owner.
     * @dev Allows the owner to trigger execution directly (useful for testing / admin-like flows),
     *      while preserving the standard bootloader pathway.
     */
    modifier requireFromBootLoaderOrOwner() {
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS && msg.sender != owner()) {
            revert ZkMinimalAccount__NotFromBootLoaderOrOwner();
        }
        _;
    }

    /**
     * @notice Initializes the account owner.
     * @dev Sets Ownable owner to the deployer (`msg.sender`) at construction time.
     */
    constructor() Ownable(msg.sender) {}

    /**
     * @notice Allows the account to receive ETH (for fees/value).
     * @dev Native transfers and funding are supported via this receive hook.
     */
    receive() external payable {}

    //////////////////////////
    /// EXTERNAL FUNCTIONS ///
    //////////////////////////

    /**
     * @notice Validates a zkSync Era AA transaction (phase 1).
     * @dev Requirements from zkSync:
     *  - MUST increment the nonce (via NonceHolder system contract).
     *  - MUST validate authorization (e.g., owner signature).
     *  - SHOULD ensure sufficient balance to cover required amount.
     *
     * @param _transaction The zkSync AA transaction struct to validate.
     * @return magic Magic value signaling validation success to the bootloader.
     *
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
        // @dev Delegates validation logic to internal helper.
        _validateTransaction(_transaction);
    }

    /**
     * @notice Executes a validated transaction (phase 2).
     * @dev Called by the bootloader during normal AA flow, or by the owner (bypass) where allowed.
     *      This function re-validates to protect the owner-path and ensure consistent rules.
     *
     * @param _transaction The zkSync AA transaction struct to execute.
     */
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
        // @dev Re-run validation before execution.
        _validateTransaction(_transaction);
        _executeTransaction(_transaction);
    }

    /**
     * @notice Executes a transaction submitted directly by an external caller (not bootloader).
     * @dev There is no point in providing possible signed hash in the `executeTransactionFromOutside` method,
     *      since it typically should not be trusted.
     *
     * @param _transaction The zkSync AA transaction struct to validate & execute.
     */
    function executeTransactionFromOutside(Transaction calldata _transaction) external payable {
        // @dev Validate signature and basic requirements; expect magic success.
        bytes4 maigc = _validateTransaction(_transaction);
        if(magic != ACCOUNT_VALIDATION_SUCCESS_MAGIC) {
            revert ZkMinimalAccount__InvalidSignature();
        }
        
        // @dev Execute the call after successful validation.
        _executeTransaction(_transaction);
    }

    /**
     * @notice Pays the bootloader for the transaction (gas fee handling).
     * @dev The bootloader expects payment during validation flow.
     *
     * @param _txHash Transaction hash (unused in this implementation).
     * @param _suggestedSignedHash Suggested signed hash (unused in this implementation).
     * @param _transaction The zkSync AA transaction struct used to compute and pay fees.
     */
    function payForTransaction(bytes32 _txHash, bytes32 _suggestedSignedHash, Transaction calldata _transaction)
        external
        payable
    {
        // @dev Uses helper to pay fee to bootloader.
        (bool success) = _transaction.payToTheBootloader();

        if (!success) {
            revert ZkMinimalAccount__FailedToPay();
        }
    }

    /**
     * @notice Hook for paymaster flows (not implemented).
     * @dev In zkSync Era, paymasters can sponsor fees; this hook would prepare state for paymaster validation.
     *
     * @param _txHash Transaction hash (unused).
     * @param _possibleSignedHash Possible signed hash (unused).
     * @param _transaction The zkSync AA transaction (unused here).
     */
    function prepareForPaymaster(bytes32 _txHash, bytes32 _possibleSignedHash, Transaction calldata _transaction)
        external
        payable
    {
        revert ZkMinimalAccount__NotImplemented();
    }

    //////////////////////////
    /// INTERNAL FUNCTIONS ///
    //////////////////////////

    /**
     * @notice Validates a transaction and increments nonce via the NonceHolder system contract.
     * @dev Steps:
     *  1) Increment nonce (system contract call).
     *  2) Check sufficient balance for `totalRequiredBalance()`.
     *  3) Validate signature against `owner()`.
     *
     * @param _transaction The transaction to validate (copied into memory).
     * @return magic Magic value expected by the bootloader:
     *  - `ACCOUNT_VALIDATION_SUCCESS_MAGIC` on success
     *  - `bytes4(0)` on failure
     */
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
        // @dev txHash is produced using zkSync's expected encoding (MemoryTransactionHelper).
        bytes32 txHash = _transaction.encodeHash(); // encode hash using MemoryTransactionHelper to correct hash
        //bytes32 convertedHash = MessageHashUtils.toEthSignedMessageHash(txHash);
        // @dev Recover signer from the signed hash and compare to owner.
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

    /**
     * @notice Executes the transaction's call.
     * @dev
     *  - If `to` is the Deployer system contract, uses a system call (required by zkSync for deployments).
     *  - Otherwise performs a low-level `call` to the target with provided value and calldata.
     *
     * @param _transaction The transaction to execute (copied into memory).
     */
    function _executeTransaction(Transaction memory _transaction) internal {
        // @dev `to` is stored as uint256 in zkSync Transaction struct; cast down to address.
        address to = address(uint160(_transaction.to));
        // @dev zkSync requires value to be uint128 in some system contexts; safe cast.
        uint128 value = Utils.safeCastToU128(_transaction.value);
        bytes memory data = _transaction.data;

        if (to == address(DEPLOYER_SYSTEM_CONTRACT)) {
            // @dev Deployments go through the deployer system contract via systemCallWithPropagatedRevert.
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

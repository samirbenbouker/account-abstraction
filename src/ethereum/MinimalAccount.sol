// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IAccount} from "@account-abstraction/contracts/interfaces/IAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {SIG_VALIDATION_FAILED, SIG_VALIDATION_SUCCESS} from "@account-abstraction/contracts/core/Helpers.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title MinimalAccount
 * @notice Minimal ERC-4337 style smart account implementing `IAccount`.
 * @dev
 *  - Works with an ERC-4337 `EntryPoint` contract (the canonical "gateway" that calls `validateUserOp`).
 *  - Owner signatures authorize execution and user operations.
 *  - This is a minimal reference design: signature validation + execution + prefund payment.
 */
contract MinimalAccount is IAccount, Ownable {
    //////////////
    /// ERRORS ///
    //////////////
    /// @notice Reverts when a function restricted to the EntryPoint is called by another address.
    error MinimalAccount__NotFromEntryPoint();
    /// @notice Reverts when a function restricted to EntryPoint OR owner is called by another address.
    error MinimalAccount__NotFromEntryPointOrOwner();
    /// @notice Reverts when the low-level call in `execute` fails, returning the revert data.
    /// @param revertData The returned revert bytes from the failed call.
    error MinimalAccount__CallFailed(bytes revertData);

    ///////////////////////
    /// STATE VARIABLES ///
    ///////////////////////
    /// @notice The ERC-4337 EntryPoint this account trusts for validation/execution flow.
    /// @dev Immutable to prevent swapping the EntryPoint after deployment.
    IEntryPoint private immutable i_entryPoint;

    /////////////////
    /// MODIFIER ///
    ////////////////
    /**
     * @notice Restricts access to the EntryPoint only.
     * @dev Used for functions that must only be callable through the ERC-4337 flow.
     */
    modifier requireFromEntryPoint() {
        _requireFromEntryPoint();
        _;
    }

    /**
     * @notice Restricts access to the EntryPoint or the owner.
     * @dev Allows owner direct calls (useful for testing/admin), while preserving the EntryPoint pathway.
     */
    modifier requireFromEntryPointOrOwner() {
        _requireFromEntryPointOrOwner();
        _;
    }

    /////////////////
    /// FUNCTIONS ///
    /////////////////
    /**
     * @notice Sets the trusted EntryPoint and initializes ownership.
     * @param entryPoint Address of the ERC-4337 EntryPoint contract.
     */
    constructor(address entryPoint) Ownable(msg.sender) {
        i_entryPoint = IEntryPoint(entryPoint);
    }

    /**
     * @notice Allows the contract to receive ETH.
     * @dev Used to fund the account for gas prefunds and value transfers.
     */
    receive() external payable {}

    //////////////////////////
    /// EXTERNAL FUNCTIONS ///
    //////////////////////////

    /**
     * @notice Executes a call from this account to a destination.
     * @dev Can only be called by the EntryPoint or the owner.
     *
     * @param dest The target contract or EOA to call.
     * @param value ETH value (wei) to send with the call.
     * @param functionData Calldata to send to `dest`.
     */
    function execute(address dest, uint256 value, bytes calldata functionData) external requireFromEntryPointOrOwner {
        (bool success, bytes memory result) = dest.call{value: value}(functionData);
        if (!success) {
            revert MinimalAccount__CallFailed(result);
        }
    }

    /**
     * @notice Validates a UserOperation for ERC-4337.
     * @dev Called by the EntryPoint during `handleOps`.
     *  - Validates the signature for this account.
     *  - Pays missing prefund (if any) back to the EntryPoint.
     *
     * @param userOp The packed user operation submitted to EntryPoint.
     * @param userOpHash Hash of the user operation (per EntryPoint rules).
     * @param missingAccountFunds Amount the EntryPoint requests to prefund this operation.
     * @return validationData ERC-4337 validation data (0 for success, or SIG_VALIDATION_FAILED).
     */
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        requireFromEntryPoint
        returns (uint256 validationData)
    {
        // @dev Validate owner signature.
        validationData = _validateSignature(userOp, userOpHash);
        // _validateNonce()
        // @dev Pay prefund if EntryPoint indicates missing funds.
        _payPrefund(missingAccountFunds);
    }

    //////////////////////////
    /// INTERNAL FUNCTIONS ///
    //////////////////////////

    /**
     * @notice Validates the UserOperation signature against the account owner.
     * @dev
     *  - `userOpHash` is an EIP-191 digest input (per ERC-4337 conventions).
     *  - We convert to an Ethereum Signed Message hash and recover the signer.
     *  - Only the current `owner()` is considered valid.
     *
     * @param userOp The user operation containing the signature.
     * @param userOpHash Hash to be signed (provided by EntryPoint).
     * @return validationData `SIG_VALIDATION_SUCCESS` if valid, else `SIG_VALIDATION_FAILED`.
     *
     * // userOpHash will be EIP-191 version of the signed hash
     * // where we need to use MessageHashUtils to digest this hash to correct bytes
     * // after that will be use ECDSA recover for get signer address to check if its the owner of this contract
     */
    function _validateSignature(PackedUserOperation calldata userOp, bytes32 userOpHash)
        internal
        view
        returns (uint256 validationData)
    {
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        address signer = ECDSA.recover(ethSignedMessageHash, userOp.signature);

        if (signer != owner()) {
            return SIG_VALIDATION_FAILED;
        }

        return SIG_VALIDATION_SUCCESS;
    }

    /**
     * @notice Pays missing prefund back to the EntryPoint.
     * @dev
     *  - `missingAccountFunds` is calculated by EntryPoint and represents how much ETH it expects
     *    this account to provide for the operation.
     *  - Uses a low-level call to `msg.sender` (EntryPoint) with max gas.
     *
     * @param missingAccountFunds Amount (wei) requested by EntryPoint.
     */
    function _payPrefund(uint256 missingAccountFunds) internal {
        if (missingAccountFunds != 0) {
            (bool success,) = payable(msg.sender).call{value: missingAccountFunds, gas: type(uint256).max}("");
            // @dev Intentionally ignore `success` (some minimal examples do this);
            //      leaving `(success);` to silence compiler warnings.
            (success);
        }
    }

    /**
     * @notice Reverts if caller is not the trusted EntryPoint.
     * @dev Used by `requireFromEntryPoint` modifier.
     */
    function _requireFromEntryPoint() internal view {
        if (msg.sender != address(i_entryPoint)) {
            revert MinimalAccount__NotFromEntryPoint();
        }
    }

    /**
     * @notice Reverts if caller is neither the trusted EntryPoint nor the owner.
     * @dev Used by `requireFromEntryPointOrOwner` modifier.
     */
    function _requireFromEntryPointOrOwner() internal view {
        if (msg.sender != address(i_entryPoint) && msg.sender != owner()) {
            revert MinimalAccount__NotFromEntryPointOrOwner();
        }
    }

    ///////////////
    /// GETTERS ///
    ///////////////

    /**
     * @notice Returns the trusted EntryPoint address.
     * @return The EntryPoint contract address.
     */
    function getEntryPoint() external view returns (address) {
        return address(i_entryPoint);
    }
}

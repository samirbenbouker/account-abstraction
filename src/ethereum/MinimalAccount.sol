// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IAccount} from "@account-abstraction/contracts/interfaces/IAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {SIG_VALIDATION_FAILED, SIG_VALIDATION_SUCCESS} from "@account-abstraction/contracts/core/Helpers.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract MinimalAccount is IAccount, Ownable {
    //////////////
    /// ERRORS ///
    //////////////
    error MinimalAccount__NotFromEntryPoint();
    error MinimalAccount__NotFromEntryPointOrOwner();
    error MinimalAccount__CallFailed(bytes);

    ///////////////////////
    /// STATE VARIABLES ///
    ///////////////////////
    IEntryPoint private immutable i_entryPoint;

    /////////////////
    /// MODIFIER ///
    ////////////////
    modifier requireFromEntryPoint() {
        _requireFromEntryPoint();
        _;
    }

    modifier requireFromEntryPointOrOwner() {
        _requireFromEntryPointOrOwner();
        _;
    }

    /////////////////
    /// FUNCTIONS ///
    /////////////////
    constructor(address entryPoint) Ownable(msg.sender) {
        i_entryPoint = IEntryPoint(entryPoint);
    }

    receive() external payable {}

    //////////////////////////
    /// EXTERNAL FUNCTIONS ///
    //////////////////////////
    function execute(address dest, uint256 value, bytes calldata functionData) external requireFromEntryPointOrOwner {
        (bool success, bytes memory result) = dest.call{value: value}(functionData);
        if (!success) {
            revert MinimalAccount__CallFailed(result);
        }
    }

    // A signature is valid, if it's the MinimalAccount owner
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        requireFromEntryPoint
        returns (uint256 validationData)
    {
        validationData = _validateSignature(userOp, userOpHash);
        // _validateNonce()
        _payPrefund(missingAccountFunds);
    }

    //////////////////////////
    /// INTERNAL FUNCTIONS ///
    //////////////////////////

    // userOpHash will be EIP-191 version of the signed hash
    // where we need to use MessageHashUtils to digest this hash to correct bytes
    // after that will be use ECDSA recover for get signer address to check if its the owner of this contract
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

    function _payPrefund(uint256 missingAccountFunds) internal {
        if (missingAccountFunds != 0) {
            (bool success,) = payable(msg.sender).call{value: missingAccountFunds, gas: type(uint256).max}("");
            (success);
        }
    }

    function _requireFromEntryPoint() internal view {
        if (msg.sender != address(i_entryPoint)) {
            revert MinimalAccount__NotFromEntryPoint();
        }
    }

    function _requireFromEntryPointOrOwner() internal view {
        if (msg.sender != address(i_entryPoint) && msg.sender != owner()) {
            revert MinimalAccount__NotFromEntryPointOrOwner();
        }
    }

    ///////////////
    /// GETTERS ///
    ///////////////
    function getEntryPoint() external view returns (address) {
        return address(i_entryPoint);
    }
}

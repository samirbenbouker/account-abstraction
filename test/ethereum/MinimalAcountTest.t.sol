// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MinimalAccount} from "src/ethereum/MinimalAccount.sol";
import {DeployMinimal} from "script/DeployMinimal.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {SendPackedUserOp, PackedUserOperation} from "script/SendPackedUserOp.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

/**
 * @title MinimalAccountTest
 * @notice Test suite for `MinimalAccount` (ERC-4337 smart account).
 * @dev
 *  Covers:
 *   - Owner direct execution.
 *   - Unauthorized execution protection.
 *   - UserOperation signing correctness (recover signer).
 *   - `validateUserOp` behavior and return value.
 *   - End-to-end execution through EntryPoint (`handleOps`).
 */
contract MinimalAccountTest is Test {
    using MessageHashUtils for bytes32;

    ///////////////////////
    /// TEST FIXTURES ///
    ///////////////////////
    /// @notice Helper that returns network-specific addresses/config (EntryPoint, account).
    HelperConfig helperConfig;
    /// @notice The smart account under test.
    MinimalAccount minimalAccount;
    /// @notice Mock ERC20 used to validate call execution (mint).
    ERC20Mock usdc;
    /// @notice Script helper used to generate and sign PackedUserOperations.
    SendPackedUserOp sendPackedUserOp;

    /// @notice Random address used to represent an unauthorized caller / bundler.
    address randomUser = makeAddr("randomUser");

    /// @notice Amount used across tests (also used as funding in some cases).
    uint256 constant AMOUNT = 1e18;

    /**
     * @notice Deploys the MinimalAccount, initializes mocks, and prepares helpers.
     * @dev
     *  - Uses the `DeployMinimal` script to keep deployment logic consistent with scripts.
     *  - Creates an ERC20Mock used as the call target.
     *  - Instantiates `SendPackedUserOp` helper to build signed UserOps for tests.
     */
    function setUp() public {
        DeployMinimal deployMinimal = new DeployMinimal();
        (helperConfig, minimalAccount) = deployMinimal.deployMinimalAccount();

        usdc = new ERC20Mock();
        sendPackedUserOp = new SendPackedUserOp();
    }

    /**
     *     USDC Mint
     *     msg.sender -> MinimalAccount
     *     approve some amount
     *     USDC contract
     *     come from the entrypoint
     */

    /**
     * @notice Owner can call `execute` directly (bypassing EntryPoint).
     * @dev This test ensures the owner path in `requireFromEntryPointOrOwner` works.
     *
     * Scenario:
     *  - Call `MinimalAccount.execute` to invoke `ERC20Mock.mint`.
     *  - Expect balance to increase by AMOUNT.
     */
    function testOwnerCanExecuteCommands() public {
        // Assert initial state
        assertEq(usdc.balanceOf(address(minimalAccount)), 0);

        // Arrange target call
        address dest = address(usdc);
        uint256 value = 0;
        bytes memory functionData =
            abi.encodeWithSelector(ERC20Mock.mint.selector, address(minimalAccount), AMOUNT);

        // Act: impersonate the owner and execute
        vm.prank(minimalAccount.owner());
        minimalAccount.execute(dest, value, functionData);

        // Assert: tokens minted to smart account
        assertEq(usdc.balanceOf(address(minimalAccount)), AMOUNT);
    }

    /**
     * @notice Non-owner cannot call `execute` directly.
     * @dev Ensures `requireFromEntryPointOrOwner` correctly rejects unauthorized callers.
     */
    function testNonOwnerCannotExecuteCommands() public {
        // Assert initial state
        assertEq(usdc.balanceOf(address(minimalAccount)), 0);

        // Arrange target call
        address dest = address(usdc);
        uint256 value = 0;
        bytes memory functionData =
            abi.encodeWithSelector(ERC20Mock.mint.selector, address(minimalAccount), AMOUNT);

        // Act + Assert: unauthorized caller reverts
        vm.prank(randomUser);
        vm.expectRevert(MinimalAccount.MinimalAccount__NotFromEntryPointOrOwner.selector);
        minimalAccount.execute(dest, value, functionData);
    }

    /**
     * @notice Signed PackedUserOperation can be recovered back to the owner address.
     * @dev
     *  - Builds a UserOp that calls `MinimalAccount.execute(...)`.
     *  - Uses EntryPoint hashing + EIP-191 signed digest.
     *  - Recovers signer and checks it matches `minimalAccount.owner()`.
     */
    function testRecoverSignedOp() public {
        // Arrange
        address dest = address(usdc);
        uint256 value = 0;

        // in this function data, what will need to do its:
        // Metmask -> EntryPoint -> MinimalAccount -> Usdc
        // we need to pass functionData to EntryPoint where this functionData contains call to MinimalAccount too
        bytes memory functionData =
            abi.encodeWithSelector(ERC20Mock.mint.selector, address(minimalAccount), AMOUNT);

        // @dev Wrap the mint call in MinimalAccount.execute, since EntryPoint calls the account.
        bytes memory executeCallData =
            abi.encodeWithSelector(MinimalAccount.execute.selector, dest, value, functionData);

        // @dev Build and sign the PackedUserOperation.
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        PackedUserOperation memory packedUserOp =
            sendPackedUserOp.generateSignedUserOperation(executeCallData, config, address(minimalAccount));

        // @dev Compute the UserOp hash as EntryPoint defines it.
        bytes32 userOperationHash = IEntryPoint(config.entryPoint).getUserOpHash(packedUserOp);

        // Act: recover signer from signature
        address actualSigner =
            ECDSA.recover(userOperationHash.toEthSignedMessageHash(), packedUserOp.signature);

        // Assert: recovered signer is the account owner
        assertEq(actualSigner, minimalAccount.owner());
    }

    /**
     * @notice validateUserOp returns success when signature is valid.
     * @dev
     *  Steps:
     *   1. Build + sign a UserOp calling `execute`.
     *   2. Call `validateUserOp` from EntryPoint address (required).
     *   3. Assert returned validationData equals 0 (success).
     *
     * Notes:
     *  - This test focuses on signature validation correctness.
     *  - Missing funds is set non-zero to also trigger prefund path.
     */
    // 1. Sign user ops
    // 2. Call Validate userops
    // 3. Assert the return is correct
    function testValidationOfUserOp() public {
        // Arrange
        address dest = address(usdc);
        uint256 value = 0;

        bytes memory functionData =
            abi.encodeWithSelector(ERC20Mock.mint.selector, address(minimalAccount), AMOUNT);

        bytes memory executeCallData =
            abi.encodeWithSelector(MinimalAccount.execute.selector, dest, value, functionData);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        PackedUserOperation memory packedUserOp =
            sendPackedUserOp.generateSignedUserOperation(executeCallData, config, address(minimalAccount));

        bytes32 userOperationHash = IEntryPoint(config.entryPoint).getUserOpHash(packedUserOp);

        // @dev Simulate the EntryPoint requesting prefund from the account.
        uint256 missingAccountFunds = 1e18;

        // Act
        // we prank with entry point because validateUserOp only can be called by entryPoint
        vm.prank(config.entryPoint);
        uint256 validationData =
            minimalAccount.validateUserOp(packedUserOp, userOperationHash, missingAccountFunds);

        // Assert
        assertEq(validationData, 0); // in this case 0 will be SUCCESS
    }

    /**
     * @notice EntryPoint can execute the account's operation via handleOps (end-to-end).
     * @dev
     *  - Builds a signed UserOp that mints ERC20 to the MinimalAccount.
     *  - Funds the account with ETH so it can pay the prefund/fees.
     *  - Calls EntryPoint.handleOps from a "bundler" (randomUser).
     *  - Confirms the mint occurred.
     */
    function testEntryPointCanExecuteCommands() public {
        // Arrange
        address dest = address(usdc);
        uint256 value = 0;

        bytes memory functionData =
            abi.encodeWithSelector(ERC20Mock.mint.selector, address(minimalAccount), AMOUNT);

        bytes memory executeCallData =
            abi.encodeWithSelector(MinimalAccount.execute.selector, dest, value, functionData);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        PackedUserOperation memory packedUserOp =
            sendPackedUserOp.generateSignedUserOperation(executeCallData, config, address(minimalAccount));

        //bytes32 userOperationHash = IEntryPoint(config.entryPoint).getUserOpHash(packedUserOp);

        // @dev Fund the account so it can pay prefund / fees when EntryPoint processes the op.
        // in this case random user will be us fee for execute this operation
        vm.deal(address(minimalAccount), AMOUNT);

        // @dev EntryPoint expects an array of operations.
        PackedUserOperation;
        ops[0] = packedUserOp;

        // Act
        // @dev Sender must match the smart account address.
        assertEq(packedUserOp.sender, address(minimalAccount));

        // @dev Simulate a bundler submitting the operations to EntryPoint.
        vm.prank(randomUser);
        IEntryPoint(config.entryPoint).handleOps(ops, payable(randomUser)); // there will put who pais the fee

        // Assert: operation executed and token minted
        assertEq(usdc.balanceOf(address(minimalAccount)), AMOUNT);
    }
}

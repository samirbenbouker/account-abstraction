# Account Abstraction Examples (ERC-4337 & zkSync Native AA)

This repository contains **minimal, well-documented implementations of Account Abstraction** using:

* ✅ **ERC-4337 (EntryPoint-based AA)**
* ✅ **zkSync Era Native Account Abstraction (type 113 transactions)**

The goal is to **learn, compare, and test** both models side-by-side using **Foundry**.

---

## ✨ What This Repo Demonstrates

### ERC-4337 (Ethereum / Arbitrum style)

* `MinimalAccount.sol` smart account
* Manual construction of `PackedUserOperation`
* Signature validation via `validateUserOp`
* Execution through `EntryPoint.handleOps`
* Prefund / gas payment handling
* End-to-end tests simulating a bundler

### zkSync Native AA

* `ZkMinimalAccount.sol` implementing `IAccount`
* Type `113 (0x71)` transactions
* Bootloader-based validation & execution
* Nonce handling via `NonceHolder` system contract
* Native fee payment to bootloader
* zkSync-specific transaction hashing & signing

---

## 📁 Project Structure

```text
src/
├── ethereum/
│   └── MinimalAccount.sol        # ERC-4337 smart account
│
├── zksync/
│   └── ZkMinimalAccount.sol      # zkSync native AA account

script/
├── DeployMinimal.s.sol           # Deploys MinimalAccount
├── HelperConfig.s.sol            # Network & EntryPoint configuration
└── SendPackedUserOp.s.sol        # Builds + signs + submits UserOps

test/
├── MinimalAccountTest.t.sol      # ERC-4337 account tests
└── ZkMinimalAccountTest.t.sol    # zkSync native AA tests
```

---

## 🔍 Key Differences: ERC-4337 vs zkSync Native AA

| Feature           | ERC-4337                 | zkSync Native AA                   |
| ----------------- | ------------------------ | ---------------------------------- |
| Entry point       | `EntryPoint` contract    | Bootloader system contract         |
| Transaction type  | `UserOperation`          | `Transaction` (type 113)           |
| Validation return | `SIG_VALIDATION_SUCCESS` | `ACCOUNT_VALIDATION_SUCCESS_MAGIC` |
| Nonce storage     | EntryPoint               | NonceHolder system contract        |
| Fee payment       | Prefund to EntryPoint    | Direct payment to bootloader       |
| Paymasters        | Yes                      | Yes (native)                       |

---

## 🛠 Requirements

* [Foundry](https://book.getfoundry.sh/)
* Solidity `^0.8.20`

Install dependencies:

```bash
forge install
```

---

## 🧪 Run Tests

### Run all tests

```bash
forge test
```

### Run only ERC-4337 tests

```bash
forge test --match-path test/MinimalAccountTest.t.sol
```

### Run only zkSync AA tests

```bash
forge test --match-path test/ZkMinimalAccountTest.t.sol
```

---

## 🚀 Deployment (ERC-4337)

Deploy a `MinimalAccount` using Foundry scripts:

```bash
forge script script/DeployMinimal.s.sol --broadcast
```

The script:

* Loads network configuration from `HelperConfig`
* Deploys `MinimalAccount`
* Transfers ownership to the configured EOA

---

## 📦 Sending a UserOperation (ERC-4337)

The `SendPackedUserOp` script demonstrates:

1. Encoding a target call (`ERC20.approve`)
2. Wrapping it in `MinimalAccount.execute`
3. Building a `PackedUserOperation`
4. Signing it using Foundry (`vm.sign`)
5. Submitting it via `EntryPoint.handleOps`

```bash
forge script script/SendPackedUserOp.s.sol --broadcast
```

---

## 🧠 Design Philosophy

* **Minimal**: only core AA logic, no abstractions hiding mechanics
* **Explicit**: hashes, signatures, gas fields are visible
* **Test-driven**: tests act as executable documentation
* **Educational**: heavy comments where behavior is non-obvious

This repo is ideal for:

* Learning Account Abstraction deeply
* Understanding how bundlers work
* Comparing ERC-4337 vs zkSync native AA
* Building your own smart account

---

## ⚠️ Security Notes

* Private keys in scripts/tests are **Anvil defaults**
* Never use these keys in production
* Contracts are **educational**, not audited

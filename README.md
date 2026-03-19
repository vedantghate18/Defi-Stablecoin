# Foundry DeFi Stablecoin

**Author:** Vedant Ghate

A minimal, algorithmic, decentralized stablecoin system implemented using Foundry.

## Overview

This project implements a decentralized stablecoin (DSC) governed by a custom engine (`DSCEngine`). The stablecoin is designed to maintain a 1:1 peg with the US Dollar. The system achieves stability through overcollateralization (200% threshold) and algorithmic minting, using exogenous cryptocurrency assets (ETH and BTC) as collateral.

### Core Properties
*   **Collateral**: Exogenous (e.g., wETH, wBTC)
*   **Minting**: Algorithmic (Strictly strictly controlled by `DSCEngine`)
*   **Relative Stability**: Pegged to 1 USD ($1)

## Architecture

The system consists of two primary smart contracts:

1.  **`DecentralizedStablecoin.sol`**: An `ERC20Burnable` and `Ownable` token contract. It represents the actual stablecoin. The ownership is transferred to the `DSCEngine`, making the engine the only entity capable of minting and burning the tokens.
2.  **`DSCEngine.sol`**: The core logic and hub of the stablecoin system. It contains all the rules for depositing, minting, redeeming, burning, and liquidating.

## Features

### Collateralization & Minting
Users deposit supported collateral tokens (like wETH or wBTC) into the `DSCEngine` to back their stablecoin positions. Based on the USD value of their collateral (determined via Chainlink Price Feeds), users can mint `DSC`. The protocol enforces a **200% overcollateralization** rule, meaning the value of collateral must always be at least double the value of the minted DSC.

### Redeeming & Burning
Users can burn their outstanding `DSC` debt to redeem their underlying collateral. The engine ensures that any withdrawal or redemption leaves the user's account with a safe "Health Factor".

### Health Factor ($H_f$)
The protocol continuously monitors user's positions through a Health Factor metric. A $H_f >= 1$ implies the position is safely collateralized. If $H_f$ drops below 1, the user is subject to liquidation.

### Liquidations
If the value of a user's collateral drops significantly (due to price volatility of ETH/BTC) and their health factor falls below 1, their position becomes undercollateralized. To protect the protocol from insolvency, anyone can act as a liquidator. Liquidators burn their own `DSC` to cover the undercollateralized user's debt. In return, they receive the user's collateral along with a **10% Liquidation Bonus**.

## Development & Usage 

This project is built with **Foundry**. 

### Prerequisites

*   [Foundry](https://getfoundry.sh/) installed locally.

### Setup

```bash
# Clone the repo
git clone <repository_url>
cd foundry-defi-StableCoin

# Install dependencies & libraries
forge install smartcontractkit/chainlink-brownie-contracts --no-commit
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge install

# Compile the contracts
forge build

# Run the test suite
forge test
```

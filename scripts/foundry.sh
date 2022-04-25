#!/usr/bin/env bash

# Test contracts ending with exactly "Test" don't require any forking
forge test --match-contract "$1.*Test$" -vvvv

# Test contracts ending with exactly "TestAvax" require Avalanche RPC and block number: 2022-04-25
forge test --match-contract "$1.*TestAvax$" --fork-url $AVAX_API --fork-block-number 13897000 -vvvv

# Test contracts ending with exactly "TestEth" require Ethereum RPC and block number: 2022-04-24
forge test --match-contract "$1.*TestEth$" --fork-url $ALCHEMY_API --fork-block-number 14650000 -vvvv

# Test contracts ending with exactly "TestMovr" require Moonriver RPC and block number: 2022-04-21
forge test --match-contract "$1.*TestMovr$" --fork-url $MOVR_API --fork-block-number 1730000 -vvvv
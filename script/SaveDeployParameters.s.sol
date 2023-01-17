// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./utils/BaseScript.sol";
import "../contracts/bridge/utils/BridgeConfigV3Lens.sol";

contract SaveDeployParameters is BridgeConfigV3Lens, BaseScript {
    using stdJson for string;

    // 2023-01-05 (Mainnet)
    uint256 internal constant ETH_BLOCK_NUMBER = 16_342_000;

    function run() external {
        saveChainConfig("avalanche");
        saveChainConfig("arbitrum");
    }

    function saveChainConfig(string memory chain) public {
        uint256 chainId = _loadChainId(chain);
        require(chainId != 0, "Chain not found");
        address bridge = loadDeploymentAddress(chain, "SynapseBridge");
        require(bridge != address(0), "Bridge not found");
        address wgas = loadDeploymentAddress(chain, "WGAS");
        require(wgas != address(0), "WGAS not found");

        string memory fullConfig = "full";
        string memory tokensConfig = "";
        fullConfig.serialize("bridge", bridge);
        fullConfig.serialize("wgas", wgas);

        string memory ethRPC = vm.envString("ALCHEMY_API");
        vm.createSelectFork(ethRPC, ETH_BLOCK_NUMBER);
        (LocalBridgeConfig.BridgeTokenConfig[] memory tokens, address[] memory pools) = getChainConfig(chainId);
        string[] memory ids = new string[](tokens.length);

        for (uint256 i = 0; i < tokens.length; ++i) {
            ids[i] = tokens[i].id;
            string memory token = tokens[i].id;
            token.serialize("token", tokens[i].token);
            token.serialize("tokenType", uint256(tokens[i].tokenType));
            token.serialize("bridgeToken", tokens[i].bridgeToken);
            token.serialize("bridgeFee", tokens[i].bridgeFee);
            token.serialize("minFee", bytes32(tokens[i].minFee));
            // Save JSON for a token
            token = token.serialize("maxFee", bytes32(tokens[i].maxFee));
            tokensConfig = string("tokens").serialize(tokens[i].id, token);
        }
        fullConfig.serialize("ids", ids);
        fullConfig.serialize("tokens", tokensConfig);
        fullConfig = fullConfig.serialize("pools", pools);

        vm.writeJson(fullConfig, _concat("./script/router_", chain, ".json"));
    }
}
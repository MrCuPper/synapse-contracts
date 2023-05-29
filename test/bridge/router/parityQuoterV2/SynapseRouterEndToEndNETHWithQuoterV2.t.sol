// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SynapseRouterSuite, SynapseRouterEndToEndNETHTest} from "../SynapseRouterEndToEndNETH.t.sol";
import {SwapQuoterV2Setup} from "./SwapQuoterV2Setup.t.sol";

contract SynapseRouterEndToEndNETHWithQuoterV2Test is SwapQuoterV2Setup, SynapseRouterEndToEndNETHTest {
    function deploySwapQuoter(
        address router_,
        address weth_,
        address owner
    ) internal override(SwapQuoterV2Setup, SynapseRouterSuite) returns (address quoter_) {
        return SwapQuoterV2Setup.deploySwapQuoter(router_, weth_, owner);
    }

    // Tests from the parent class are inherited, and they will be using SwapQuoterV2 instead of SwapQuoter
}

// SPDX-License-Identifier: MIT

pragma solidity >=0.8.11;

import {ERC20Burnable} from "@openzeppelin/contracts-solc8/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20} from "@synapseprotocol/sol-lib/contracts/solc8/erc20/IERC20.sol";

import {IBridgeRouter} from "../../router/interfaces/IBridgeRouter.sol";

interface IBridge {
    /// @dev NOT_SUPPORTED would be default value
    enum TokenType {
        NOT_SUPPORTED,
        MINT_BURN,
        DEPOSIT_WITHDRAW
    }

    struct SwapParams {
        uint256 minAmountOut;
        address[] path;
        address[] adapters;
        uint256 deadline;
    }

    struct SwapResult {
        IERC20 tokenReceived;
        uint256 amountReceived;
    }

    event BridgeTokenRegistered(
        address indexed bridgeToken,
        address indexed bridgeWrapper,
        TokenType tokenType
    );

    event Recovered(address indexed asset, uint256 amount);

    // -- VIEWS

    function getBridgeToken(IERC20 token) external view returns (IERC20);

    function getUnderlyingToken(IERC20 token) external view returns (IERC20);

    function bridgeTokenType(address token) external view returns (TokenType);

    // -- BRIDGE EVENTS OUT: Reworked

    event BridgedOutEVM(
        address indexed to,
        uint256 chainId,
        IERC20 token,
        uint256 amount,
        SwapParams swapParams
    );

    event BridgedOutNonEVM(
        bytes32 indexed to,
        uint256 chainId,
        IERC20 token,
        uint256 amount
    );

    // -- BRIDGE EVENTS IN --

    event TokenBridgedIn(
        address indexed to,
        IERC20 tokenBridged,
        uint256 amountBridged,
        uint256 bridgeFee,
        bool isMint,
        IERC20 tokenReceived,
        uint256 amountReceived,
        bool airdropGiven,
        bytes32 indexed kappa
    );

    // -- BRIDGE OUT FUNCTIONS: to EVM chains --

    function bridgeToEVM(
        address to,
        uint256 chainId,
        IERC20 token,
        SwapParams calldata destinationSwapParams
    ) external returns (uint256 amountBridged);

    // -- BRIDGE OUT FUNCTIONS: to non-EVM chains --

    function bridgeToNonEVM(
        bytes32 to,
        uint256 chainId,
        IERC20 token
    ) external returns (uint256 amountBridged);

    // -- BRIDGE IN FUNCTIONS --

    function bridgeIn(
        address to,
        IERC20 token,
        uint256 amount,
        uint256 fee,
        SwapParams calldata destinationSwapParams,
        bytes32 kappa
    ) external;

    // -- RESTRICTED FUNCTIONS --

    function registerBridgeToken(
        address bridgeToken,
        address bridgeWrapper,
        TokenType tokenType
    ) external;

    function recoverGAS() external;

    function recoverERC20(IERC20 token) external;

    function setRouter(IBridgeRouter _router) external;
}

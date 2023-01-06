// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../interfaces/IWETH9.sol";
import "../interfaces/ISynapseBridge.sol";
import "../interfaces/ISwapQuoter.sol";
import "./LocalBridgeConfig.sol";
import "./SynapseAdapter.sol";

/**
 * @notice SynapseRouter contract that can be used together with SynapseBridge on any chain.
 * On every supported chain SynapseRouter and SwapQuoter contracts need to be deployed.
 * Chain pools, that are present in the global BridgeConfig should be added to SwapQuoter.
 * router.setSwapQuoter(swapQuoter) should be executed to link these contracts.
 * SynapseRouter should be using the same WETH contract that SynapseBridge is (or will be) using.
 * All supported bridge tokens should be added to SynapseRouter contract.
 *
 * @dev Bridging workflow with SynapseRouter contract.
 * Suppose `routerO` and `routerD` are SynapseRouter deployments on origin and destination chain respectively.
 * Suppose user wants to send `tokenIn` on origin chain, and receive `tokenOut` on destination chain.
 * Suppose for this transaction `bridgeToken` needs to be used.
 * Bridge token address is `bridgeTokenO` and `bridgeTokenD` on origin and destination chain respectively.
 * There might or might not be a swap on origin and destination chains.
 * Following set of actions is required:
 * 1. originQuery = routerO.getAmountOut(tokenIn, bridgeTokenO, amountIn)
 * 2. Adjust originQuery.minAmountOut and originQuery.deadline using user defined slippage and deadline
 * 3. fee = BridgeConfig.calculateSwapFee(bridgeTokenD, destChainId, originQuery.minAmountOut)
 * // ^ Needs special logic for Avalanche's GMX ^
 * 4. destQuery = brideZapD.getAmountOut(bridgeTokenD, tokenOut, originQuery.minAmountOut - fee)
 * 5. Do the bridging with router.bridge(to, destChainId, tokenIn, amountIn, originQuery, destQuery)
 * // If tokenIn is WETH, do router.bridge{value: amount} to use native ETH instead of WETH.
 * Note: the transaction will be reverted, if `bridgeTokenO` is not set up in SynapseRouter.
 */
contract SynapseRouter is LocalBridgeConfig, SynapseAdapter {
    // SynapseRouter is also the Adapter for the Synapse pools (this reduces the amount of token transfers).
    // SynapseRouter address will be used as swapAdapter in SwapQueries returned by a local SwapQuoter.

    using SafeERC20 for IERC20;

    /*╔══════════════════════════════════════════════════════════════════════╗*\
    ▏*║                        CONSTANTS & IMMUTABLES                        ║*▕
    \*╚══════════════════════════════════════════════════════════════════════╝*/

    /// @notice Address of wrapped gas token, that is used by SynapseBridge.
    IWETH9 public immutable weth;
    /// @notice Synapse:Bridge address
    ISynapseBridge public immutable synapseBridge;

    /*╔══════════════════════════════════════════════════════════════════════╗*\
    ▏*║                      CONSTRUCTOR & INITIALIZER                       ║*▕
    \*╚══════════════════════════════════════════════════════════════════════╝*/

    /**
     * @notice Creates a SynapseRouter implementation, saves WETH and SynapseBridge address.
     * @dev Redeploy an implementation with different values, if an update is required.
     * Upgrading the proxy implementation then will effectively "update the immutables".
     */
    constructor(address payable _weth, address _synapseBridge) public {
        weth = IWETH9(_weth);
        synapseBridge = ISynapseBridge(_synapseBridge);
    }

    /// @notice Receive function to enable unwrapping ETH into this contract
    receive() external payable {} // solhint-disable-line no-empty-blocks

    /*╔══════════════════════════════════════════════════════════════════════╗*\
    ▏*║                              OWNER ONLY                              ║*▕
    \*╚══════════════════════════════════════════════════════════════════════╝*/

    /**
     * @notice Sets a custom allowance for the given token.
     * @dev To be used for the wrapper token setups.
     */
    function setAllowance(
        IERC20 token,
        address spender,
        uint256 amount
    ) external onlyOwner {
        token.safeApprove(spender, amount);
    }

    /*╔══════════════════════════════════════════════════════════════════════╗*\
    ▏*║                            BRIDGE & SWAP                             ║*▕
    \*╚══════════════════════════════════════════════════════════════════════╝*/

    /**
     * @notice Initiate a bridge transaction with an optional swap on both
     * origin and destination chains.
     * @dev Note that method is payable.
     * 1. Using a msg.value == 0 forces SynapseRouter to use `token`. This way WETH could be bridged.
     * 2. Using a msg.value != 0 forces SynapseRouter to use native gas. In this case following is required:
     *    - `token` must be SynapseRouter's WETH, otherwise tx will revert
     *    - `amount` must be equal to msg.value, otherwise tx will revert
     *
     * `token` is always a token user is sending. In case token requires a wrapper token to be bridge,
     * use underlying address for `token` instead of the wrapper one.
     *
     * `originQuery` contains instructions for the swap on origin chain. As above, originQuery.tokenOut
     * should always use the underlying address. In other words, the concept of wrapper token is fully
     * abstracted away from the end user.
     *
     * `originQuery` and `destQuery` are supposed to be fetched using SynapseRouter.getAmountOut(tokenIn, tokenOut, amountIn)
     *
     * @param to            Address to receive tokens on destination chain
     * @param chainId       Destination chain id
     * @param token         Initial token for the bridge transaction to be pulled from the user
     * @param amount        Amount of the initial tokens for the bridge transaction
     * @param originQuery   Origin swap query. Empty struct indicates no swap is required
     * @param destQuery     Destination swap query. Empty struct indicates no swap is required
     */
    function bridge(
        address to,
        uint256 chainId,
        address token,
        uint256 amount,
        SwapQuery memory originQuery,
        SwapQuery memory destQuery
    ) external payable {
        if (_swapRequested(originQuery)) {
            // Pull initial token from the user to specified swap adapter
            _pullToken(originQuery.swapAdapter, token, amount);
            // Perform a swap using the swap adapter, transfer the swapped tokens to this contract
            (token, amount) = _adapterSwap(address(this), token, amount, originQuery);
        } else {
            // Pull initial token from the user to this contract
            _pullToken(address(this), token, amount);
        }
        // Either way, this contract has `amount` worth of `token`
        TokenConfig memory _config = config[token];
        require(_config.bridgeToken != address(0), "Token not supported");
        token = _config.bridgeToken;
        // Check if swap on destination chain is required.
        if (_swapRequested(destQuery)) {
            // Decode params for swapping via a Synapse pool on the destination chain.
            SynapseParams memory destParams = abi.decode(destQuery.rawParams, (SynapseParams));
            if (_config.tokenType == TokenType.Deposit) {
                require(destParams.action == Action.Swap, "Unsupported dest action");
                // Case 1: token needs to be deposited on origin chain.
                // We need to perform AndSwap() on destination chain.
                synapseBridge.depositAndSwap({
                    to: to,
                    chainId: chainId,
                    token: IERC20(token),
                    amount: amount,
                    tokenIndexFrom: destParams.tokenIndexFrom,
                    tokenIndexTo: destParams.tokenIndexTo,
                    minDy: destQuery.minAmountOut,
                    deadline: destQuery.deadline
                });
            } else if (destParams.action == Action.Swap) {
                // Case 2: token needs to be redeemed on origin chain.
                // We need to perform AndSwap() on destination chain.
                synapseBridge.redeemAndSwap({
                    to: to,
                    chainId: chainId,
                    token: IERC20(token),
                    amount: amount,
                    tokenIndexFrom: destParams.tokenIndexFrom,
                    tokenIndexTo: destParams.tokenIndexTo,
                    minDy: destQuery.minAmountOut,
                    deadline: destQuery.deadline
                });
            } else {
                require(destParams.action == Action.RemoveLiquidity, "Unsupported dest action");
                // Case 3: token needs to be redeemed on origin chain.
                // We need to perform AndRemove() on destination chain.
                synapseBridge.redeemAndRemove({
                    to: to,
                    chainId: chainId,
                    token: IERC20(token),
                    amount: amount,
                    liqTokenIndex: destParams.tokenIndexTo,
                    liqMinAmount: destQuery.minAmountOut,
                    liqDeadline: destQuery.deadline
                });
            }
        } else {
            if (_config.tokenType == TokenType.Deposit) {
                // Case 1 (Deposit): token needs to be deposited on origin chain
                synapseBridge.deposit(to, chainId, IERC20(token), amount);
            } else {
                // Case 2 (Redeem): token needs to be redeemed on origin chain
                synapseBridge.redeem(to, chainId, IERC20(token), amount);
            }
        }
    }

    /**
     * @notice Perform a swap using the supplied parameters.
     * @dev Note that method is payable.
     * 1. Using a msg.value == 0 forces SynapseRouter to use `token`. This way WETH could be swapped.
     * 2. Using a msg.value != 0 forces SynapseRouter to use native gas. In this case following is required:
     *    - `token` must be SynapseRouter's WETH, otherwise tx will revert
     *    - `amount` must be equal to msg.value, otherwise tx will revert
     * Note there's an option to unwrap WETH, should it be the swapped token.
     * @param to            Address to receive swapped tokens
     * @param token         Token to swap
     * @param amount        Amount of tokens to swap
     * @param query         Query with the swap parameters (see BridgeStructs.sol)
     * @param unwrapETH     Whether user wants to receive native ETH (ignored if tokenOut != WETH)
     * @return amountOut    Amount of swapped tokens received by the user
     */
    function swap(
        address to,
        address token,
        uint256 amount,
        SwapQuery memory query,
        bool unwrapETH
    ) external payable returns (uint256 amountOut) {
        require(to != address(0), "!recipient: zero address");
        require(to != address(this), "!recipient: router address");
        require(_swapRequested(query), "!swapAdapter");
        // Pull initial token from the user to specified swap adapter
        _pullToken(query.swapAdapter, token, amount);
        // Check if the end token is WETH and unwrapping is requested
        if (query.tokenOut == address(weth) && unwrapETH) {
            // Perform a swap through the adapter, send swapped token (WETH) to the this contract
            (, amountOut) = _adapterSwap(address(this), token, amount, query);
            // Unwrap ETH and send to the recipient
            _unwrapETH(to, amountOut);
        } else {
            // Perform a swap through the adapter, send swapped token to the recipient
            (, amountOut) = _adapterSwap(to, token, amount, query);
        }
    }

    /*╔══════════════════════════════════════════════════════════════════════╗*\
    ▏*║                         VIEWS: BRIDGE QUOTES                         ║*▕
    \*╚══════════════════════════════════════════════════════════════════════╝*/

    /**
     * @notice Finds the best pool from the Synapse-supported pools for tokenIn -> bridgeToken swap,
     * treating it as the "origin chain swap" in the Synapse Bridge transaction.
     *
     * @dev
     * 1. Will revert if `bridgeToken` is not a supported bridge token. In case the bridged token
     * requires a bridge wrapper token, use the underlying token address as `bridgeToken` in this method.
     * 2. Will correctly form a SwapQuery if `tokenIn == bridgeToken`.
     * 3. It is possible to form a SwapQuery off-chain using alternative SwapAdapter for the origin swap.
     *
     * @param tokenIn       Initial token that user wants to bridge/swap
     * @param bridgeToken   Token that will be used for bridging on origin chain
     * @param amountIn      Amount of tokens user wants to bridge/swap
     * @return query    Struct to be used as `originQuery` in SynapseRouter.
     *                  minAmountOut and deadline fields will need to be adjusted based on the user settings.
     */
    function getOriginAmountOut(
        address tokenIn,
        address bridgeToken,
        uint256 amountIn
    ) external view returns (SwapQuery memory query) {
        require(config[bridgeToken].bridgeToken != address(0), "Token not supported");
        query = this.getAmountOut(tokenIn, bridgeToken, amountIn);
    }

    /**
     * @notice Finds the best pool from the Synapse-supported pools for bridgeToken -> tokenOut swap,
     * treating it as the "destination chain swap" in the Synapse Bridge transaction.
     *
     * @dev
     * 1. Will revert if `bridgeToken` is not a supported bridge token. In case the bridged token
     * requires a bridge wrapper token, use the underlying token address as `bridgeToken` in this method.
     * 2. Will correctly form a SwapQuery if `bridgeToken == tokenOut`.
     * 3. It is NOT possible to form a SwapQuery off-chain using alternative SwapAdapter for the destination swap.
     * For the time being, only swaps through the Synapse-supported pools are available on destination chain.
     *
     * @param bridgeToken   Token that will be used for bridging on destination chain
     * @param tokenOut      Token user wants to receive on destination chain
     * @param amountIn      Amount of tokens bridged from origin chain (before fees)
     * @return query    Struct to be used as `destQuery` in SynapseRouter.
     *                  minAmountOut and deadline fields will need to be adjusted based on the user settings.
     */
    function getDestinationAmountOut(
        address bridgeToken,
        address tokenOut,
        uint256 amountIn
    ) external view returns (SwapQuery memory query) {
        // Apply bridge fee, this will revert if token is not supported
        amountIn = _calculateBridgeAmountOut(bridgeToken, amountIn);
        query = this.getAmountOut(bridgeToken, tokenOut, amountIn);
    }

    /*╔══════════════════════════════════════════════════════════════════════╗*\
    ▏*║                            INTERNAL: SWAP                            ║*▕
    \*╚══════════════════════════════════════════════════════════════════════╝*/

    /**
     * @notice Performs a swap from `token` using the provided query,
     * which includes the swap adapter, tokenOut and the swap execution parameters.
     * Initial token is supposed to have been already transferred to the swap adapter.
     * Swapped token is transferred to the specified recipient.
     */
    function _adapterSwap(
        address recipient,
        address token,
        uint256 amount,
        SwapQuery memory query
    ) internal returns (address tokenOut, uint256 amountOut) {
        // First, check the deadline for the swap
        // solhint-disable-next-line not-rely-on-time
        require(block.timestamp <= query.deadline, "Deadline not met");
        tokenOut = query.tokenOut;
        // If swapAdapter is this contract (which is the case for the supported Synapse pools),
        // this will be an external call to address(this), which we are fine with.
        // The external call is used because additional Adapters will be established in the future.
        amountOut = ISwapAdapter(query.swapAdapter).adapterSwap({
            to: recipient,
            tokenIn: token,
            amountIn: amount,
            tokenOut: tokenOut,
            rawParams: query.rawParams
        });
        // We can trust the supported adapters to return the exact swapped amount
        // Finally, check that the recipient received at least as much as they wanted
        require(amountOut >= query.minAmountOut, "Swap didn't result in min tokens");
    }

    /**
     * Pulls a requested token from the user to the requested recipient.
     * Or, if msg.value was provided and WETH was used as token, wraps the received ETH and sends to the recipient.
     */
    function _pullToken(
        address recipient,
        address token,
        uint256 amount
    ) internal {
        if (msg.value == 0) {
            // Token needs to be pulled only if msg.value is zero
            // This way user can specify WETH as the origin asset
            IERC20(token).safeTransferFrom(msg.sender, recipient, amount);
        } else {
            // Otherwise, we need to check that WETH was specified
            require(token == address(weth), "!weth");
            // And that amount matches msg.value
            require(msg.value == amount, "!msg.value");
            // Wrap ETH and send to recipient
            _wrapETH(recipient, amount);
        }
        // Either way `recipient` has `amount` worth of `token`
    }

    /**
     * @notice Checks whether the swap was requested in the query.
     * Query is considered empty (and thus swap-less) if swap adapter address was not specified.
     */
    function _swapRequested(SwapQuery memory query) internal pure returns (bool) {
        return query.swapAdapter != address(0);
    }

    /*╔══════════════════════════════════════════════════════════════════════╗*\
    ▏*║                 INTERNAL: ADD & REMOVE BRIDGE TOKENS                 ║*▕
    \*╚══════════════════════════════════════════════════════════════════════╝*/

    /// @dev Adds a bridge token config and its fee structure, if it's not present.
    /// If a token was added, approves it for spending by SynapseBridge.
    function _addToken(
        address token,
        TokenType tokenType,
        address bridgeToken,
        uint256 bridgeFee,
        uint256 minFee,
        uint256 maxFee
    ) internal override returns (bool wasAdded) {
        // Add token and its fee structure
        wasAdded = LocalBridgeConfig._addToken(token, tokenType, bridgeToken, bridgeFee, minFee, maxFee);
        if (wasAdded) {
            // Approve token only if it wasn't previously added
            // Underlying token should always implement allowance(), approve()
            if (token == bridgeToken) _approveToken(IERC20(token), address(synapseBridge));
            // Use {setAllowance} for custom wrapper token setups
        }
    }

    /*╔══════════════════════════════════════════════════════════════════════╗*\
    ▏*║                         INTERNAL: WETH LOGIC                         ║*▕
    \*╚══════════════════════════════════════════════════════════════════════╝*/

    function _wrapETH(address recipient, uint256 amount) internal {
        // Deposit in order to have WETH in this contract
        weth.deposit{value: amount}();
        // Transfer WETH to recipient, if requested
        if (recipient != address(this)) {
            IERC20(address(weth)).safeTransfer(recipient, amount);
        }
    }

    function _unwrapETH(address recipient, uint256 amount) internal {
        // Withdraw ETH to this contract
        weth.withdraw(amount);
        // Transfer ETH to recipient if requested
        if (recipient != address(this)) {
            (bool success, ) = recipient.call{value: amount}("");
            require(success, "ETH transfer failed");
        }
    }
}
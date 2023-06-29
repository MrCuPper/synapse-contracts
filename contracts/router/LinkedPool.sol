// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IPausable} from "./interfaces/IPausable.sol";
import {IndexedToken, IPoolModule} from "./interfaces/IPoolModule.sol";
import {ILinkedPool, LimitedToken} from "./interfaces/ILinkedPool.sol";
import {IDefaultPool} from "./interfaces/IDefaultPool.sol";
import {Action} from "./libs/Structs.sol";
import {TokenTree} from "./tree/TokenTree.sol";

import {Ownable} from "@openzeppelin/contracts-4.5.0/access/Ownable.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts-4.5.0/token/ERC20/utils/SafeERC20.sol";

/// LinkedPool is using an internal Token Tree to aggregate a collection of pools with correlated
/// tokens into a single wrapper, conforming to IDefaultPool interface.
/// The internal Token Tree allows to store up to 256 tokens, which should be enough for most use cases.
/// Note: unlike traditional Default pools, tokens in LinkedPool could be duplicated.
/// This contract is supposed to be used in conjunction with Synapse:Bridge:
/// - The bridged token has index == 0, and could not be duplicated in the tree.
/// - Other tokens (correlated to bridge token) could be duplicated in the tree. Every node token in the tree
/// is represented by a trade path from root token to node token.
/// > This is the reason why token could be duplicated. `nUSD -> USDC` and `nUSD -> USDT -> USDC` both represent
/// > USDC token, but via different paths from nUSD, the bridge token.
/// In addition to the standard IDefaultPool interface, LinkedPool also implements getters to observe the internal
/// tree, as well as the best path finder between any two tokens in the tree.
contract LinkedPool is TokenTree, Ownable, ILinkedPool {
    using SafeERC20 for IERC20;

    // solhint-disable-next-line no-empty-blocks
    constructor(address bridgeToken) TokenTree(bridgeToken) {}

    // ═════════════════════════════════════════════════ EXTERNAL ══════════════════════════════════════════════════════

    /// @notice Adds a pool with `N = tokensAmount` tokens to the tree by adding N-1 new nodes
    /// as the children of the given node. Given node needs to represent a token from the pool.
    /// @dev `poolModule` should be set to address(this) if the pool conforms to IDefaultPool interface.
    /// Otherwise, it should be set to the address of the contract that implements the logic for pool handling.
    /// @param nodeIndex        The index of the node to which the pool will be added
    /// @param pool             The address of the pool
    /// @param poolModule       The address of the pool module
    /// @param tokensAmount     The amount of tokens in the pool
    function addPool(
        uint256 nodeIndex,
        address pool,
        address poolModule,
        uint256 tokensAmount
    ) external onlyOwner {
        require(pool != address(0), "Pool address can't be zero");
        _addPool(nodeIndex, pool, poolModule, tokensAmount);
    }

    /// @inheritdoc ILinkedPool
    function swap(
        uint8 nodeIndexFrom,
        uint8 nodeIndexTo,
        uint256 dx,
        uint256 minDy,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        uint256 totalTokens = _nodes.length;
        // solhint-disable-next-line not-rely-on-time
        require(block.timestamp <= deadline, "Deadline not met");
        require(
            nodeIndexFrom < totalTokens && nodeIndexTo < totalTokens && nodeIndexFrom != nodeIndexTo,
            "Swap not supported"
        );
        // Pull initial token from the user
        address tokenIn = _nodes[nodeIndexFrom].token;
        uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), dx);
        // transfer in tokens and update dx (in case of transfer fees)
        dx = IERC20(tokenIn).balanceOf(address(this)) - balanceBefore;
        amountOut = _multiSwap(nodeIndexFrom, nodeIndexTo, dx).amountOut;
        require(amountOut >= minDy, "Swap didn't result in min tokens");
        // Transfer the tokens to the user
        IERC20(_nodes[nodeIndexTo].token).safeTransfer(msg.sender, amountOut);
    }

    // ═══════════════════════════════════════════════════ VIEWS ═══════════════════════════════════════════════════════

    /// Note: this calculates a quote for a predefined swap path between two tokens. If any of the tokens is
    /// presented more than once in the internal tree, there might be a better quote. Integration should use
    /// findBestPath() instead. This function is present for backwards compatibility.
    /// @inheritdoc ILinkedPool
    function calculateSwap(
        uint8 nodeIndexFrom,
        uint8 nodeIndexTo,
        uint256 dx
    ) external view returns (uint256 amountOut) {
        uint256 totalTokens = _nodes.length;
        // Check that the token indexes are within range
        if (nodeIndexFrom >= totalTokens || nodeIndexTo >= totalTokens) {
            return 0;
        }
        // Check that the token indexes are not the same
        if (nodeIndexFrom == nodeIndexTo) {
            return 0;
        }
        // Calculate the quote by following the path from "tokenFrom" node to "tokenTo" node in the stored tree
        // This function might be called by Synapse:Bridge before the swap, so we don't waste gas checking if pool is paused,
        // as the swap will fail anyway if it is.
        amountOut = _getMultiSwapQuote({
            nodeIndexFrom: nodeIndexFrom,
            nodeIndexTo: nodeIndexTo,
            amountIn: dx,
            probePaused: false
        }).amountOut;
    }

    /// @inheritdoc ILinkedPool
    function getConnectedTokens(LimitedToken[] memory tokensIn, address tokenOut)
        external
        view
        returns (bool[] memory isConnected)
    {
        uint256 numTokens = tokensIn.length;
        isConnected = new bool[](numTokens);
        uint256 tokenOutNodes = _tokenNodes[tokenOut].length;
        // Check if `tokenOut` is in the tree
        if (tokenOutNodes == 0) {
            return isConnected;
        }
        // tokenOut is root only if the first entry in `_tokenNodes[tokenOut]` is ZERO (root node index)
        bool isTokenOutRoot = _tokenNodes[tokenOut][0] == 0;
        for (uint256 i = 0; i < numTokens; ++i) {
            LimitedToken memory token = tokensIn[i];
            // `tokenIn` should be swappable
            if (!Action.Swap.isIncluded(token.actionMask)) {
                continue;
            }
            // `tokenIn` should differ from `tokenOut`
            if (token.token == tokenOut) {
                continue;
            }
            uint256 tokenInNodes = _tokenNodes[token.token].length;
            // Check if `tokenIn` is in the tree
            if (tokenInNodes == 0) {
                continue;
            }
            // We only consider paths where either of the tokens is the bridge(root) token,
            // as this is either "swap into bridge token" or "swap from bridge token" case.
            isConnected[i] = isTokenOutRoot || _tokenNodes[token.token][0] == 0;
        }
    }

    /// Note: this could be potentially a gas expensive operation. This is used by SwapQuoterV2 to get the best quote
    /// for tokenIn -> tokenOut swap request (the call to SwapQuoter is an off-chain call).
    /// This should NOT be used as a part of "find path + perform a swap" on-chain flow.
    /// Instead, do an off-chain call to findBestPath() and then perform a swap using the found node indexes.
    /// As pair of token nodes defines only a single trade path (tree has no cycles), it will be possible to go
    /// through the found path by simply supplying the found indexes (instead of searching for the best path again).
    /// @inheritdoc ILinkedPool
    function findBestPath(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    )
        external
        view
        returns (
            uint8 nodeIndexFromBest,
            uint8 nodeIndexToBest,
            uint256 amountOutBest
        )
    {
        // Check that the tokens are not the same and that the amount is not zero
        if (tokenIn == tokenOut || amountIn == 0) {
            return (0, 0, 0);
        }
        uint256 nodesFrom = _tokenNodes[tokenIn].length;
        uint256 nodesTo = _tokenNodes[tokenOut].length;
        // Go through every node that represents `tokenIn`
        for (uint256 i = 0; i < nodesFrom; ++i) {
            uint256 nodeIndexFrom = _tokenNodes[tokenIn][i];
            // Go through every node that represents `tokenOut`
            for (uint256 j = 0; j < nodesTo; ++j) {
                uint256 nodeIndexTo = _tokenNodes[tokenOut][j];
                // Calculate the quote by following the path from "tokenFrom" node to "tokenTo" node in the stored tree
                // We discard any paths with paused pools, as it's not possible to swap via them anyway.
                uint256 amountOut = _getMultiSwapQuote({
                    nodeIndexFrom: nodeIndexFrom,
                    nodeIndexTo: nodeIndexTo,
                    amountIn: amountIn,
                    probePaused: true
                }).amountOut;
                if (amountOut > amountOutBest) {
                    amountOutBest = amountOut;
                    nodeIndexFromBest = uint8(nodeIndexFrom);
                    nodeIndexToBest = uint8(nodeIndexTo);
                }
            }
        }
    }

    /// @inheritdoc ILinkedPool
    function getToken(uint8 index) external view returns (address token) {
        require(index < _nodes.length, "Out of range");
        return _nodes[index].token;
    }

    /// @inheritdoc ILinkedPool
    function tokenNodesAmount() external view returns (uint256) {
        return _nodes.length;
    }

    /// @inheritdoc ILinkedPool
    function getAttachedPools(uint8 index) external view returns (address[] memory pools) {
        require(index < _nodes.length, "Out of range");
        pools = new address[](_pools.length);
        uint256 amountAttached = 0;
        uint256 poolsMask = _attachedPools[index];
        for (uint256 i = 0; i < pools.length; ) {
            // Check if _pools[i] is attached to the node at `index`
            unchecked {
                if ((poolsMask >> i) & 1 == 1) {
                    pools[amountAttached++] = _pools[i];
                }
                ++i;
            }
        }
        // Use assembly to shrink the array to the actual size
        // solhint-disable-next-line no-inline-assembly
        assembly {
            mstore(pools, amountAttached)
        }
    }

    /// @inheritdoc ILinkedPool
    function getTokenNodes(address token) external view returns (uint256[] memory nodes) {
        nodes = _tokenNodes[token];
    }

    // ══════════════════════════════════════════════ INTERNAL LOGIC ═══════════════════════════════════════════════════

    /// @dev Approves the given spender to spend the given token indefinitely, if the current allowance is not enough.
    /// Note: doesn't do anything if the spender already has infinite allowance.
    function _approveToken(
        address token,
        address spender,
        uint256 minAllowance
    ) internal {
        uint256 allowance = IERC20(token).allowance(address(this), spender);
        if (allowance < minAllowance) {
            // if allowance is neither zero nor infinity, reset if first
            if (allowance != 0) {
                IERC20(token).safeApprove(spender, 0);
            }
            // We can issue the infinite approval here, as LinkedPool is not supposed to hold any tokens.
            IERC20(token).safeApprove(spender, type(uint256).max);
        }
    }

    /// @dev Performs a single swap between two nodes using the given pool.
    /// Assumes that the initial token is already in this contract.
    function _poolSwap(
        address poolModule,
        address pool,
        uint256 nodeIndexFrom,
        uint256 nodeIndexTo,
        uint256 amountIn
    ) internal override returns (uint256 amountOut) {
        address tokenFrom = _nodes[nodeIndexFrom].token;
        address tokenTo = _nodes[nodeIndexTo].token;
        // Approve pool to spend the token, if needed
        if (poolModule == address(this)) {
            _approveToken({token: tokenFrom, spender: pool, minAllowance: amountIn});
            // Pool conforms to IDefaultPool interface. Note: we check minDy and deadline outside of this function.
            amountOut = IDefaultPool(pool).swap({
                tokenIndexFrom: tokenIndexes[pool][tokenFrom],
                tokenIndexTo: tokenIndexes[pool][tokenTo],
                dx: amountIn,
                minDy: 0,
                deadline: type(uint256).max
            });
        } else {
            // Here we pass both token address and its index to the pool module, so it doesn't need to store
            // index<>token mapping. This allows Pool Module to be implemented in a stateless way, as some
            // pools require token index for interactions, while others require token address.
            // poolSwap(pool, tokenFrom, tokenTo, amountIn)
            bytes memory payload = abi.encodeWithSelector(
                IPoolModule.poolSwap.selector,
                pool,
                IndexedToken({index: tokenIndexes[pool][tokenFrom], token: tokenFrom}),
                IndexedToken({index: tokenIndexes[pool][tokenTo], token: tokenTo}),
                amountIn
            );
            // Delegate swap logic to Pool Module. It should approve the pool to spend the token, if needed.
            // Note that poolModule address is set by the contract owner, so it's safe to delegatecall it.
            (bool success, bytes memory result) = poolModule.delegatecall(payload);
            require(success, "Swap failed");
            // Pool Modules are whitelisted, so we can trust the returned amountOut value.
            amountOut = abi.decode(result, (uint256));
        }
    }

    // ══════════════════════════════════════════════ INTERNAL VIEWS ═══════════════════════════════════════════════════

    /// @dev Returns the amount of tokens that will be received from a single swap.
    function _getPoolQuote(
        address poolModule,
        address pool,
        uint256 nodeIndexFrom,
        uint256 nodeIndexTo,
        uint256 amountIn,
        bool probePaused
    ) internal view override returns (uint256 amountOut) {
        if (poolModule == address(this)) {
            // Check if pool is paused, if requested
            if (probePaused) {
                // We issue a static call in case the pool does not conform to IPausable interface.
                (bool success, bytes memory returnData) = pool.staticcall(
                    abi.encodeWithSelector(IPausable.paused.selector)
                );
                if (success && abi.decode(returnData, (bool))) {
                    // Pool is paused, return zero
                    return 0;
                }
            }
            // Pool conforms to IDefaultPool interface.
            try
                IDefaultPool(pool).calculateSwap({
                    tokenIndexFrom: tokenIndexes[pool][_nodes[nodeIndexFrom].token],
                    tokenIndexTo: tokenIndexes[pool][_nodes[nodeIndexTo].token],
                    dx: amountIn
                })
            returns (uint256 amountOut_) {
                amountOut = amountOut_;
            } catch {
                // Return zero if the pool getter reverts for any reason
                amountOut = 0;
            }
        } else {
            // Ask Pool Module to calculate the quote
            address tokenFrom = _nodes[nodeIndexFrom].token;
            address tokenTo = _nodes[nodeIndexTo].token;
            // Here we pass both token address and its index to the pool module, so it doesn't need to store
            // index<>token mapping. This allows Pool Module to be implemented in a stateless way, as some
            // pools require token index for interactions, while others require token address.
            try
                IPoolModule(poolModule).getPoolQuote(
                    pool,
                    IndexedToken({index: tokenIndexes[pool][tokenFrom], token: tokenFrom}),
                    IndexedToken({index: tokenIndexes[pool][tokenTo], token: tokenTo}),
                    amountIn,
                    probePaused
                )
            returns (uint256 amountOut_) {
                amountOut = amountOut_;
            } catch {
                // Return zero if the pool module getter reverts for any reason
                amountOut = 0;
            }
        }
    }

    /// @dev Returns the tokens in the pool at the given address.
    function _getPoolTokens(
        address poolModule,
        address pool,
        uint256 tokensAmount
    ) internal view override returns (address[] memory tokens) {
        if (poolModule == address(this)) {
            // Pool conforms to IDefaultPool interface.
            tokens = new address[](tokensAmount);
            for (uint256 i = 0; i < tokensAmount; ) {
                tokens[i] = IDefaultPool(pool).getToken(uint8(i));
                unchecked {
                    ++i;
                }
            }
        } else {
            // Ask Pool Module to return the tokens
            // Note: this will revert if pool is not supported by the module, enforcing the invariant
            // that the added pools are supported by their specified module.
            tokens = IPoolModule(poolModule).getPoolTokens(pool, tokensAmount);
        }
    }
}

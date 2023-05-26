// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/// TokenTree implements the internal logic for storing a set of tokens in a rooted tree.
/// - Root node represents a Synapse-bridged token.
/// - The root token could not appear more than once in the tree.
/// - Other tree nodes represent tokens that are correlated with the root token.
/// - These other tokens could appear more than once in the tree.
/// - Every edge between a child and a parent node is associated with a single liquidity pool that contains both tokens.
/// - The tree is rooted => the root of the tree has a zero depth. A child node depth is one greater than its parent.
/// - Every node can have arbitrary amount of children.
/// - New nodes are added to the tree by "attaching" a pool to an existing node. This adds all the other pool tokens
/// as new children of the existing node (which represents one of the tokens from the pool).
/// - Pool could be only attached once to any given node. Pool could not be attached to a node, if it connects the node
/// with its parent.
/// - Pool could be potentially attached to two different nodes in the tree.
/// - By definition a tree has no cycles, so there exists only one path between any two nodes. Every edge on this path
/// represents a liquidity pool, and the whole path represents a series of swaps that lead from one token to another.
/// - Paths that contain a pool more than once are not allowed, and are not used for quotes/swaps. This is due to
/// the fact that it's impossible to get an accurate quote for the second swap through the pool in the same tx.
/// > This contract is only responsible for storing and traversing the tree. The swap/quote logic, as well as
/// > transformation of the inner tree into ISaddle interface is implemented in the child contract.
abstract contract TokenTree {
    /// @notice Struct so store the tree nodes
    /// @param token        Address of the token represented by this node
    /// @param depth        Depth of the node in the tree
    /// @param poolIndex    Index of the pool that connects this node to its parent (0 if root)
    struct Node {
        address token;
        uint8 depth;
        uint8 poolIndex;
    }

    /// @notice Struct to store the liquidity pools
    /// @dev Module address is used for delegate calls to get swap quotes, token indexes, etc.
    /// Set to address(this) if pool conforms to ISaddle interface. Set to 0x0 if pool is not supported.
    /// @param module       Address of the module contract for this pool
    /// @param index        Index of the pool in the `_pools` array
    struct Pool {
        address module;
        uint8 index;
    }

    /// @notice Struct to get around stack too deep error
    /// @param from         Node representing the token we are swapping from
    /// @param to           Node representing the token we are swapping to
    struct Request {
        Node from;
        Node to;
        bool probePaused;
    }

    /// @notice Struct to get around stack too deep error
    /// @param visitedPools     Bitmask of pools visited so far
    /// @param amountOut        Amount of tokens received so far
    struct Route {
        uint256 visitedPools;
        uint256 amountOut;
    }

    // ══════════════════════════════════════════════════ STORAGE ══════════════════════════════════════════════════════

    // The nodes of the tree are stored in an array. The root node is at index 0.
    Node[] internal _nodes;

    // The list of all supported liquidity pools. All values are unique.
    address[] internal _pools;

    // (pool address => pool description)
    mapping(address => Pool) internal _poolMap;

    // (pool => token => tokenIndex) for each pool, stores the index of each token in the pool.
    mapping(address => mapping(address => uint8)) public tokenIndexes;

    // (token => nodes) for each token, stores the indexes of all nodes that represent this token.
    mapping(address => uint256[]) internal _tokenNodes;

    // The full path from every node to the root is stored using bitmasks in the following way:
    // - For a node with index i at depth N, lowest N + 1 bytes of _rootPath[i] are used to store the path to the root.
    // - The lowest byte is always the root index. This is always 0, but we store this for consistency.
    // - The highest byte is always the node index. This is always i, but we store this for consistency.
    // - The remaining bytes are indexes of the nodes on the path from the node to the root (from highest to lowest).
    // This way the finding the lowest common ancestor of two nodes is reduced to finding the lowest differing byte
    // in node's encoded root paths.
    uint256[] internal _rootPath;

    // (node => bitmask with all attached pools to the node).
    // Note: This excludes the pool that connects the node to its parent.
    mapping(uint256 => uint256) internal _attachedPools;

    // ════════════════════════════════════════════════ CONSTRUCTOR ════════════════════════════════════════════════════

    constructor(address bridgeToken) {
        // The root node is always the bridge token
        _addNode({token: bridgeToken, depth: 0, poolIndex: 0, rootPathParent: 0});
        // Push the empty pool so that `poolIndex` for non-root nodes is never 0
        _pools.push(address(0));
    }

    // ══════════════════════════════════════════════ INTERNAL LOGIC ═══════════════════════════════════════════════════

    /// @dev Adds a pool with `N = tokensAmount` tokens to the tree by adding N-1 new nodes
    /// as the children of the given node. Given node needs to represent a token from the pool.
    function _addPool(
        uint256 nodeIndex,
        address pool,
        address poolModule,
        uint256 tokensAmount
    ) internal {
        require(nodeIndex < _nodes.length, "Out of range");
        Node memory node = _nodes[nodeIndex];
        if (poolModule == address(0)) poolModule = address(this);
        (bool wasAdded, uint8 poolIndex) = (false, _poolMap[pool].index);
        if (poolIndex == 0) {
            poolIndex = uint8(_pools.length);
            require(poolIndex <= type(uint8).max, "Too many pools");
            _pools.push(pool);
            _poolMap[pool] = Pool({module: poolModule, index: poolIndex});
            wasAdded = true;
        } else {
            // Check that the pool does not connect the node to its parent
            require(node.poolIndex != poolIndex, "Parent pool can't be attached");
            // Check that the pool is not already attached to the node
            require(_attachedPools[nodeIndex] & (1 << poolIndex) == 0, "Pool already attached");
        }
        // Remember that the pool is attached to the node
        _attachedPools[nodeIndex] |= 1 << poolIndex;
        address[] memory tokens = _getPoolTokens(poolModule, pool, tokensAmount);
        bool nodeFound = false;
        unchecked {
            uint8 childDepth = node.depth + 1;
            uint256 rootPathParent = _rootPath[nodeIndex];
            for (uint256 i = 0; i < tokensAmount; ++i) {
                address token = tokens[i];
                // Save token indexes if this is a new pool
                if (wasAdded) {
                    tokenIndexes[pool][token] = uint8(i);
                }
                // Add new nodes to the tree
                if (token == node.token) {
                    // TODO: check that pool wasn't added twice to the same node
                    nodeFound = true;
                    continue;
                }
                _addNode(token, childDepth, poolIndex, rootPathParent);
            }
        }
        require(nodeFound, "Node token not found in the pool");
    }

    /// @dev Adds a new node to the tree and saves its path to the root.
    function _addNode(
        address token,
        uint8 depth,
        uint8 poolIndex,
        uint256 rootPathParent
    ) internal {
        // Index of the newly inserted child node
        uint256 nodeIndex = _nodes.length;
        require(nodeIndex <= type(uint8).max, "Too many nodes");
        require(_nodes.length == 0 || token != _nodes[0].token, "Bridge token must be at root");
        _nodes.push(Node({token: token, depth: depth, poolIndex: poolIndex}));
        _tokenNodes[token].push(nodeIndex);
        // Push the root path for the new node. The root path is the inserted node index + the parent's root path.
        _rootPath.push((nodeIndex << (8 * depth)) | rootPathParent);
    }

    // ══════════════════════════════════════ INTERNAL LOGIC: MULTIPLE POOLS ═══════════════════════════════════════════

    /// @dev Performs a multi-hop swap by following the path from "tokenFrom" node to "tokenTo" node
    /// in the stored tree. Token indexes are checked to be within range and not the same.
    /// Assumes that the initial token is already in this contract.
    function _multiSwap(
        uint256 nodeIndexFrom,
        uint256 nodeIndexTo,
        uint256 amountIn
    ) internal returns (Route memory route) {
        // Struct to get around stack too deep
        Request memory req = Request({from: _nodes[nodeIndexFrom], to: _nodes[nodeIndexTo], probePaused: false});
        uint256 rootPathFrom = _rootPath[nodeIndexFrom];
        uint256 rootPathTo = _rootPath[nodeIndexTo];
        // Find the depth where the paths diverge
        uint256 depthDiff = _depthDiff(rootPathFrom, rootPathTo);
        // Check if `nodeIndexTo` is an ancestor of `nodeIndexFrom`. True if paths diverge below `nodeIndexTo`.
        if (depthDiff > req.to.depth) {
            // Path from "tokenFrom" to root includes "tokenTo",
            // so we simply go from "tokenFrom" to "tokenTo" in the "to root" direction.
            return _multiSwapToRoot(0, rootPathFrom, req.from.depth, req.to.depth, amountIn);
        }
        // Check if `nodeIndexFrom` is an ancestor of `nodeIndexTo`. True if paths diverge below `nodeIndexFrom`.
        if (depthDiff > req.from.depth) {
            // Path from "tokenTo" to root includes "tokenFrom",
            // so we simply go from "tokenTo" to "tokenFrom" in the "from root" direction.
            return _multiSwapFromRoot(0, rootPathTo, req.from.depth, req.to.depth, amountIn);
        }
        // First, we traverse up the tree from "tokenFrom" to one level deeper the lowest common ancestor.
        route = _multiSwapToRoot(0, rootPathFrom, req.from.depth, depthDiff, amountIn);
        // Check if we need to do a sibling swap. When the two nodes are connected to the same parent via the same pool,
        // we do a direct swap between the two nodes, instead of doing two swaps through the parent using the same pool.
        uint256 lastNodeIndex = _extractNodeIndex(rootPathFrom, depthDiff);
        uint256 siblingIndex = _extractNodeIndex(rootPathTo, depthDiff);
        uint256 firstPoolIndex = _nodes[lastNodeIndex].poolIndex;
        uint256 secondPoolIndex = _nodes[siblingIndex].poolIndex;
        if (firstPoolIndex == secondPoolIndex) {
            // Swap lastNode -> sibling
            (route.visitedPools, route.amountOut) = _singleSwap(
                route.visitedPools,
                firstPoolIndex,
                lastNodeIndex,
                siblingIndex,
                route.amountOut
            );
        } else {
            // Swap lastNode -> parent
            uint256 parentIndex = _extractNodeIndex(rootPathFrom, depthDiff - 1);
            (route.visitedPools, route.amountOut) = _singleSwap(
                route.visitedPools,
                firstPoolIndex,
                lastNodeIndex,
                parentIndex,
                route.amountOut
            );
            // Swap parent -> sibling
            (route.visitedPools, route.amountOut) = _singleSwap(
                route.visitedPools,
                secondPoolIndex,
                parentIndex,
                siblingIndex,
                route.amountOut
            );
        }
        // Finally, we traverse down the tree from the lowest common ancestor to "tokenTo".
        return _multiSwapFromRoot(route.visitedPools, rootPathTo, depthDiff, req.to.depth, route.amountOut);
    }

    /// @dev Performs a multi-hop swap, going in "from root direction" (where depth increases)
    /// via the given `rootPath` from `depthFrom` to `depthTo`.
    /// Assumes that the initial token is already in this contract.
    function _multiSwapFromRoot(
        uint256 visitedPools,
        uint256 rootPath,
        uint256 depthFrom,
        uint256 depthTo,
        uint256 amountIn
    ) internal returns (Route memory route) {
        uint256 nodeIndex = _extractNodeIndex(rootPath, depthFrom);
        // Traverse down the tree following `rootPath` from `depthFrom` to `depthTo`.
        for (uint256 depth = depthFrom; depth < depthTo; ) {
            // Get the child node
            unchecked {
                ++depth;
            }
            uint256 childIndex = _extractNodeIndex(rootPath, depth);
            // Swap node -> child
            (visitedPools, amountIn) = _singleSwap(
                visitedPools,
                _nodes[childIndex].poolIndex,
                nodeIndex,
                childIndex,
                amountIn
            );
            nodeIndex = childIndex;
        }
        route.visitedPools = visitedPools;
        route.amountOut = amountIn;
    }

    /// @dev Performs a multi-hop swap, going in "to root direction" (where depth decreases)
    /// via the given `rootPath` from `depthFrom` to `depthTo`.
    /// Assumes that the initial token is already in this contract.
    function _multiSwapToRoot(
        uint256 visitedPools,
        uint256 rootPath,
        uint256 depthFrom,
        uint256 depthTo,
        uint256 amountIn
    ) internal returns (Route memory route) {
        uint256 nodeIndex = _extractNodeIndex(rootPath, depthFrom);
        // Traverse up the tree following `rootPath` from `depthFrom` to `depthTo`.
        for (uint256 depth = depthFrom; depth > depthTo; ) {
            // Get the parent node
            unchecked {
                --depth; // depth > 0 so we can do unchecked math
            }
            uint256 parentIndex = _extractNodeIndex(rootPath, depth);
            // Swap node -> parent
            (visitedPools, amountIn) = _singleSwap(
                visitedPools,
                _nodes[nodeIndex].poolIndex,
                nodeIndex,
                parentIndex,
                amountIn
            );
            nodeIndex = parentIndex;
        }
        route.visitedPools = visitedPools;
        route.amountOut = amountIn;
    }

    // ════════════════════════════════════════ INTERNAL LOGIC: SINGLE POOL ════════════════════════════════════════════

    /// @dev Performs a single swap between two nodes using the given pool.
    /// Assumes that the initial token is already in this contract.
    function _poolSwap(
        address poolModule,
        address pool,
        uint256 nodeIndexFrom,
        uint256 nodeIndexTo,
        uint256 amountIn
    ) internal virtual returns (uint256 amountOut);

    /// @dev Performs a single swap between two nodes using the given pool given the set of pools
    /// we have already used on the path. Returns the updated set of pools and the amount of tokens received.
    /// Assumes that the initial token is already in this contract.
    function _singleSwap(
        uint256 visitedPools,
        uint256 poolIndex,
        uint256 nodeIndexFrom,
        uint256 nodeIndexTo,
        uint256 amountIn
    ) internal returns (uint256 visitedPools_, uint256 amountOut) {
        if (visitedPools & (1 << poolIndex) != 0) {
            // If we already used this pool on the path, we can't use it again.
            revert("Can't use same pool twice");
        }
        // Mark the pool as visited
        visitedPools_ = visitedPools | (1 << poolIndex);
        address pool = _pools[poolIndex];
        amountOut = _poolSwap(_poolMap[pool].module, pool, nodeIndexFrom, nodeIndexTo, amountIn);
    }

    // ══════════════════════════════════════ INTERNAL VIEWS: MULTIPLE POOLS ═══════════════════════════════════════════

    /// @dev Calculates the multi-hop swap quote by following the path from "tokenFrom" node to "tokenTo" node
    /// in the stored tree. Token indexes are checked to be within range and not the same.
    function _getMultiSwapQuote(
        uint256 nodeIndexFrom,
        uint256 nodeIndexTo,
        uint256 amountIn,
        bool probePaused
    ) internal view returns (Route memory route) {
        // Struct to get around stack too deep
        Request memory req = Request({from: _nodes[nodeIndexFrom], to: _nodes[nodeIndexTo], probePaused: probePaused});
        uint256 rootPathFrom = _rootPath[nodeIndexFrom];
        uint256 rootPathTo = _rootPath[nodeIndexTo];
        // Find the depth where the paths diverge
        uint256 depthDiff = _depthDiff(rootPathFrom, rootPathTo);
        // Check if `nodeIndexTo` is an ancestor of `nodeIndexFrom`. True if paths diverge below `nodeIndexTo`.
        if (depthDiff > req.to.depth) {
            // Path from "tokenFrom" to root includes "tokenTo",
            // so we simply go from "tokenFrom" to "tokenTo" in the "to root" direction.
            return _getMultiSwapToRootQuote(0, rootPathFrom, req.from.depth, req.to.depth, amountIn, probePaused);
        }
        // Check if `nodeIndexFrom` is an ancestor of `nodeIndexTo`. True if paths diverge below `nodeIndexFrom`.
        if (depthDiff > req.from.depth) {
            // Path from "tokenTo" to root includes "tokenFrom",
            // so we simply go from "tokenTo" to "tokenFrom" in the "from root" direction.
            return _getMultiSwapFromRootQuote(0, rootPathTo, req.from.depth, req.to.depth, amountIn, probePaused);
        }
        // First, we traverse up the tree from "tokenFrom" to one level deeper the lowest common ancestor.
        route = _getMultiSwapToRootQuote(
            route.visitedPools,
            rootPathFrom,
            req.from.depth,
            depthDiff,
            amountIn,
            req.probePaused
        );
        // Check if we need to do a sibling swap. When the two nodes are connected to the same parent via the same pool,
        // we do a direct swap between the two nodes, instead of doing two swaps through the parent using the same pool.
        uint256 lastNodeIndex = _extractNodeIndex(rootPathFrom, depthDiff);
        uint256 siblingIndex = _extractNodeIndex(rootPathTo, depthDiff);
        uint256 firstPoolIndex = _nodes[lastNodeIndex].poolIndex;
        uint256 secondPoolIndex = _nodes[siblingIndex].poolIndex;
        if (firstPoolIndex == secondPoolIndex) {
            // Swap lastNode -> sibling
            (route.visitedPools, route.amountOut) = _getSingleSwapQuote(
                route.visitedPools,
                firstPoolIndex,
                lastNodeIndex,
                siblingIndex,
                route.amountOut,
                req.probePaused
            );
        } else {
            // Swap lastNode -> parent
            uint256 parentIndex = _extractNodeIndex(rootPathFrom, depthDiff - 1);
            (route.visitedPools, route.amountOut) = _getSingleSwapQuote(
                route.visitedPools,
                firstPoolIndex,
                lastNodeIndex,
                parentIndex,
                route.amountOut,
                req.probePaused
            );
            // Swap parent -> sibling
            (route.visitedPools, route.amountOut) = _getSingleSwapQuote(
                route.visitedPools,
                secondPoolIndex,
                parentIndex,
                siblingIndex,
                route.amountOut,
                req.probePaused
            );
        }
        // Finally, we traverse down the tree from the lowest common ancestor to "tokenTo".
        return
            _getMultiSwapFromRootQuote(
                route.visitedPools,
                rootPathTo,
                depthDiff,
                req.to.depth,
                route.amountOut,
                req.probePaused
            );
    }

    /// @dev Calculates the amount of tokens that will be received from a multi-hop swap,
    /// going in "from root direction" (where depth increases) via the given `rootPath` from `depthFrom` to `depthTo`.
    function _getMultiSwapFromRootQuote(
        uint256 visitedPools,
        uint256 rootPath,
        uint256 depthFrom,
        uint256 depthTo,
        uint256 amountIn,
        bool probePaused
    ) internal view returns (Route memory route) {
        uint256 nodeIndex = _extractNodeIndex(rootPath, depthFrom);
        // Traverse down the tree following `rootPath` from `depthFrom` to `depthTo`.
        for (uint256 depth = depthFrom; depth < depthTo; ) {
            // Get the child node
            unchecked {
                ++depth;
            }
            uint256 childIndex = _extractNodeIndex(rootPath, depth);
            // Swap node -> child
            (visitedPools, amountIn) = _getSingleSwapQuote(
                visitedPools,
                _nodes[childIndex].poolIndex,
                nodeIndex,
                childIndex,
                amountIn,
                probePaused
            );
            nodeIndex = childIndex;
        }
        route.visitedPools = visitedPools;
        route.amountOut = amountIn;
    }

    /// @dev Calculates the amount of tokens that will be received from a multi-hop swap,
    /// going in "to root direction" (where depth decreases) via the given `rootPath` from `depthFrom` to `depthTo`.
    function _getMultiSwapToRootQuote(
        uint256 visitedPools,
        uint256 rootPath,
        uint256 depthFrom,
        uint256 depthTo,
        uint256 amountIn,
        bool probePaused
    ) internal view returns (Route memory route) {
        uint256 nodeIndex = _extractNodeIndex(rootPath, depthFrom);
        // Traverse up the tree following `rootPath` from `depthFrom` to `depthTo`.
        for (uint256 depth = depthFrom; depth > depthTo; ) {
            // Get the parent node
            unchecked {
                --depth; // depth > 0 so we can do unchecked math
            }
            uint256 parentIndex = _extractNodeIndex(rootPath, depth);
            // Swap node -> parent
            (visitedPools, amountIn) = _getSingleSwapQuote(
                visitedPools,
                _nodes[nodeIndex].poolIndex,
                nodeIndex,
                parentIndex,
                amountIn,
                probePaused
            );
            nodeIndex = parentIndex;
        }
        route.visitedPools = visitedPools;
        route.amountOut = amountIn;
    }

    // ════════════════════════════════════════ INTERNAL VIEWS: SINGLE POOL ════════════════════════════════════════════

    /// @dev Returns the tokens in the pool at the given address.
    function _getPoolTokens(
        address poolModule,
        address pool,
        uint256 tokensAmount
    ) internal view virtual returns (address[] memory tokens);

    /// @dev Returns the amount of tokens that will be received from a single swap.
    /// Will check if the pool is paused beforehand, if requested.
    function _getPoolQuote(
        address poolModule,
        address pool,
        uint256 nodeIndexFrom,
        uint256 nodeIndexTo,
        uint256 amountIn,
        bool probePaused
    ) internal view virtual returns (uint256 amountOut);

    /// @dev Calculates the amount of tokens that will be received from a single swap given the set of pools
    /// we have already used on the path. Returns the updated set of pools and the amount of tokens received.
    function _getSingleSwapQuote(
        uint256 visitedPools,
        uint256 poolIndex,
        uint256 nodeIndexFrom,
        uint256 nodeIndexTo,
        uint256 amountIn,
        bool probePaused
    ) internal view returns (uint256 visitedPools_, uint256 amountOut) {
        if (visitedPools & (1 << poolIndex) != 0) {
            // If we already used this pool on the path, we can't use it again.
            // Return the full mask and zero amount to indicate that the swap is not possible.
            return (type(uint256).max, 0);
        }
        // Otherwise, mark the pool as visited
        visitedPools_ = visitedPools | (1 << poolIndex);
        address pool = _pools[poolIndex];
        // Pass the parameter for whether we want to check that the pool is paused or not.
        amountOut = _getPoolQuote(_poolMap[pool].module, pool, nodeIndexFrom, nodeIndexTo, amountIn, probePaused);
    }

    // ══════════════════════════════════════════════════ HELPERS ══════════════════════════════════════════════════════

    /// @dev Finds the lowest common ancestor of two different nodes in the tree.
    /// Node is defined by the path from the root to the node, and the depth of the node.
    function _depthDiff(uint256 rootPath0, uint256 rootPath1) internal pure returns (uint256 depthDiff) {
        // Xor the paths to get the first differing byte.
        // Nodes are different => root paths are different => the result is never zero.
        rootPath0 ^= rootPath1;
        // Sanity check for invariant: rootPath0 != rootPath1
        assert(rootPath0 != 0);
        // Traverse from root to node0 and node1 until the paths diverge.
        while ((rootPath0 & 0xFF) == 0) {
            // Shift off the lowest byte which are identical in both paths.
            rootPath0 >>= 8;
            unchecked {
                depthDiff++;
            }
        }
    }

    /// @dev Returns the index of the node at the given depth on the path from the root to the node.
    function _extractNodeIndex(uint256 rootPath, uint256 depth) internal pure returns (uint256 nodeIndex) {
        // Nodes on the path are stored from root to node (lowest to highest bytes).
        return (rootPath >> (8 * depth)) & 0xFF;
    }
}

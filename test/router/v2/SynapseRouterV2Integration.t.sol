// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IntegrationUtils} from "../../utils/IntegrationUtils.sol";

import {ISwapQuoterV2} from "../../../contracts/router/interfaces/ISwapQuoterV2.sol";
import {IBridgeModule} from "../../../contracts/router/interfaces/IBridgeModule.sol";
import {ILocalBridgeConfig} from "../../../contracts/router/interfaces/ILocalBridgeConfig.sol";

import {IMessageTransmitter} from "../../../contracts/cctp/interfaces/IMessageTransmitter.sol";
import {ISynapseCCTPConfig} from "../../../contracts/cctp/interfaces/ISynapseCCTPConfig.sol";

import {Arrays} from "../../../contracts/router/libs/Arrays.sol";
import {Action, BridgeToken, DefaultParams, SwapQuery} from "../../../contracts/router/libs/Structs.sol";
import {RequestLib} from "../../../contracts/cctp/libs/Request.sol";

import {SynapseRouterV2} from "../../../contracts/router/SynapseRouterV2.sol";
import {SynapseBridgeModule} from "../../../contracts/router/modules/bridge/SynapseBridgeModule.sol";
import {SynapseCCTPModule} from "../../../contracts/router/modules/bridge/SynapseCCTPModule.sol";

import {console, Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts-4.5.0/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-4.5.0/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts-4.5.0/token/ERC20/extensions/IERC20Metadata.sol";

// solhint-disable no-console
abstract contract SynapseRouterV2IntegrationTest is IntegrationUtils {
    using SafeERC20 for IERC20;
    using Arrays for BridgeToken[];
    using Arrays for address[];

    ISwapQuoterV2 private _quoter;

    uint256[] public expectedChainIds; // destination chain ids to support

    address[] public expectedModules;
    mapping(address => string) public moduleNames;
    mapping(address => bytes32) public moduleIds;

    address[] public expectedTokens;
    mapping(address => string) public tokenNames;

    // synapse bridge module
    address public synapseLocalBridgeConfig;
    address public synapseBridge;

    // synapse cctp module
    address public synapseCCTP;

    SynapseRouterV2 public router;
    address public user;
    address public recipient;

    /// synapse bridge events
    event TokenDeposit(address indexed to, uint256 chainId, address token, uint256 amount);
    event TokenDepositAndSwap(
        address indexed to,
        uint256 chainId,
        address token,
        uint256 amount,
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 minDy,
        uint256 deadline
    );

    event TokenRedeem(address indexed to, uint256 chainId, address token, uint256 amount);
    event TokenRedeemAndSwap(
        address indexed to,
        uint256 chainId,
        address token,
        uint256 amount,
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 minDy,
        uint256 deadline
    );
    event TokenRedeemAndRemove(
        address indexed to,
        uint256 chainId,
        address token,
        uint256 amount,
        uint8 swapTokenIndex,
        uint256 swapMinAmount,
        uint256 swapDeadline
    );

    // synapse cctp events
    event CircleRequestSent(
        uint256 chainId,
        address indexed sender,
        uint64 nonce,
        address token,
        uint256 amount,
        uint32 requestVersion,
        bytes formattedRequest,
        bytes32 requestID
    );

    constructor(
        string memory envRPC,
        uint256 forkBlockNumber,
        address quoter
    ) IntegrationUtils(envRPC, forkBlockNumber) {
        require(quoter != address(0), "swapQuoter == address(0)");
        _quoter = ISwapQuoterV2(quoter);
    }

    function setUp() public virtual override {
        super.setUp(); // @dev afterBlockchainForked() should be overwritten for extra config here

        deployRouter();
        setSwapQuoter();

        deploySynapseBridgeModule();
        if (synapseCCTP != address(0)) deploySynapseCCTPModule();

        addExpectedChainIds();
        addExpectedModules();
        addExpectedTokens();

        connectBridgeModules();
        user = makeAddr("User");
        recipient = makeAddr("Recipient");
    }

    function deployRouter() public virtual {
        router = new SynapseRouterV2();
    }

    function setSwapQuoter() public virtual {
        router.setSwapQuoter(_quoter);
    }

    function deploySynapseBridgeModule() public virtual {
        require(synapseLocalBridgeConfig != address(0), "synapseLocalBridgeConfig == address(0)");
        require(synapseBridge != address(0), "synapseBridge == address(0)");

        address module = address(new SynapseBridgeModule(synapseLocalBridgeConfig, synapseBridge));
        addExpectedModule(module, "SynapseBridgeModule");
    }

    function deploySynapseCCTPModule() public virtual {
        require(synapseCCTP != address(0), "synapseCCTP == address(0)");

        address module = address(new SynapseCCTPModule(synapseCCTP));
        addExpectedModule(module, "SynapseCCTPModule");
    }

    /// @dev override to include destination chains
    function addExpectedChainIds() public virtual;

    /// @dev override to include more modules than bridge, cctp
    function addExpectedModules() public virtual;

    function addExpectedModule(address module, string memory moduleName) public virtual {
        expectedModules.push(module);
        moduleNames[module] = moduleName;
        moduleIds[module] = getModuleId(moduleName);
        vm.label(module, moduleName);
    }

    function connectBridgeModules() public virtual {
        for (uint256 i = 0; i < expectedModules.length; i++) {
            address module = expectedModules[i];
            bytes32 id = moduleIds[module];
            router.connectBridgeModule(id, module);
        }
    }

    function addExpectedTokens() public virtual;

    function addExpectedToken(address token, string memory tokenName) public virtual {
        expectedTokens.push(token);
        tokenNames[token] = tokenName;
        vm.label(token, tokenName);
    }

    // ═══════════════════════════════════════════════════ TESTS ═══════════════════════════════════════════════════════

    // TODO: tests for views: generic getters, origin/destination getAmountOut

    function testSetup() public {
        for (uint256 i = 0; i < expectedModules.length; i++) {
            console.log("%s: %s [%s]", i, expectedModules[i], moduleNames[expectedModules[i]]);
            assertEq(router.moduleToId(expectedModules[i]), moduleIds[expectedModules[i]]);
        }
        assertTrue(user != address(0), "user not set");
        assertTrue(recipient != address(0), "recipient not set");
    }

    // TODO: add separate bridge tests with origin, dest query
    function testBridges() public {
        SwapQuery memory emptyQuery; // TODO: array of origin, dest queries to try ...
        for (uint256 i = 0; i < expectedModules.length; i++) {
            address module = expectedModules[i];
            bytes32 moduleId = moduleIds[module];
            for (uint256 j = 0; j < expectedTokens.length; j++) {
                address token = expectedTokens[j];
                address[] memory supportedTokens = IBridgeModule(module).getBridgeTokens().tokens();
                if (!supportedTokens.contains(token)) continue; // test not relevant if module doesn't support token; TODO: change for queries
                for (uint256 k = 0; k < expectedChainIds.length; k++) {
                    uint256 chainId = expectedChainIds[k];
                    checkBridge(chainId, moduleId, token, emptyQuery, emptyQuery);
                }
            }
        }
    }

    function checkBridge(
        uint256 chainId,
        bytes32 moduleId,
        address token,
        SwapQuery memory originQuery,
        SwapQuery memory destQuery
    ) public virtual {
        uint256 amount = getTestAmount(token);
        mintToken(token, amount);
        approveSpending(token, address(router), amount);

        // TODO: include swap query params in logs, factor in getters check
        console.log("Bridging %s from chain %s -> %s", tokenNames[token], getChainId(), chainId);
        uint256 balanceBefore = IERC20(token).balanceOf(user);

        checkBridgeEvent(chainId, moduleId, token, amount, originQuery, destQuery);
        vm.prank(user);
        router.bridgeViaSynapse({
            to: recipient,
            chainId: chainId,
            moduleId: moduleId,
            token: token,
            amount: amount,
            originQuery: originQuery,
            destQuery: destQuery
        });
        assertEq(IERC20(token).balanceOf(user), balanceBefore - amount, "Failed to spend token");
    }

    function checkBridgeEvent(
        uint256 chainId,
        bytes32 moduleId,
        address token,
        uint256 amount,
        SwapQuery memory originQuery,
        SwapQuery memory destQuery
    ) public virtual {
        if (moduleId == getModuleId("SynapseBridgeModule"))
            checkSynapseBridgeEvent(chainId, moduleId, token, amount, destQuery);
        else if (moduleId == getModuleId("SynapseCCTPModule"))
            checkSynapseCCTPEvent(chainId, moduleId, token, amount, destQuery);
        else checkExpectedBridgeEvent(chainId, moduleId, token, amount, destQuery);
    }

    function checkSynapseBridgeEvent(
        uint256 chainId,
        bytes32 moduleId,
        address token,
        uint256 amount,
        SwapQuery memory destQuery
    ) public {
        if (moduleId != getModuleId("SynapseBridgeModule")) return;

        // 5 cases
        //  1. TokenDeposit: ERC20 asset deposit on this chain and no destQuery
        //  2. TokenDepositAndSwap: ERC20 asset deposit on this chain and destQuery w Action.Swap
        //  3. TokenRedeem: Wrapped syn asset burned and no destQuery
        //  4. TokenRedeemAndSwap: Wrapped syn asset burned and destQuery w Action.Swap
        //  5. TokenRedeemAndRemove: Wrapped syn asset burned and destQuery  w Action.RemoveLiquidity
        (ILocalBridgeConfig.TokenType tokenType, ) = ILocalBridgeConfig(synapseLocalBridgeConfig).config(token);

        vm.expectEmit(synapseBridge); // @dev next call should be to router bridge function
        if (tokenType == ILocalBridgeConfig.TokenType.Deposit) {
            // case 1
            if (!hasParams(destQuery)) {
                emit TokenDeposit(recipient, chainId, token, amount);
                return;
            }

            // case 2
            DefaultParams memory params = abi.decode(destQuery.rawParams, (DefaultParams));
            if (params.action == Action.Swap)
                emit TokenDepositAndSwap(
                    recipient,
                    chainId,
                    token,
                    amount,
                    params.tokenIndexFrom,
                    params.tokenIndexTo,
                    destQuery.minAmountOut,
                    destQuery.deadline
                );
        } else if (tokenType == ILocalBridgeConfig.TokenType.Redeem) {
            // case 3
            if (!hasParams(destQuery)) {
                emit TokenRedeem(recipient, chainId, token, amount);
                return;
            }

            DefaultParams memory params = abi.decode(destQuery.rawParams, (DefaultParams));
            if (params.action == Action.Swap)
                emit TokenRedeemAndSwap(
                    recipient,
                    chainId,
                    token,
                    amount,
                    params.tokenIndexFrom,
                    params.tokenIndexTo,
                    destQuery.minAmountOut,
                    destQuery.deadline
                );
            // case 4
            else if (params.action == Action.RemoveLiquidity)
                emit TokenRedeemAndRemove(
                    recipient,
                    chainId,
                    token,
                    amount,
                    params.tokenIndexTo,
                    destQuery.minAmountOut,
                    destQuery.deadline
                ); // case 5
        }
    }

    function checkSynapseCCTPEvent(
        uint256 chainId,
        bytes32 moduleId,
        address token,
        uint256 amount,
        SwapQuery memory destQuery
    ) public {
        if (moduleId != getModuleId("SynapseCCTPModule")) return;

        uint32 originDomain = ISynapseCCTPConfig(synapseCCTP).localDomain();
        ISynapseCCTPConfig.DomainConfig memory remoteDomainConfig = ISynapseCCTPConfig(synapseCCTP).remoteDomainConfig(
            chainId
        );
        uint32 destDomain = remoteDomainConfig.domain;

        IMessageTransmitter messageTransmitter = ISynapseCCTPConfig(synapseCCTP).messageTransmitter();
        uint64 nonce = messageTransmitter.nextAvailableNonce();

        (uint32 requestVersion, bytes memory swapParams) = deriveCCTPSwapParams(destQuery);
        bytes memory expectedRequest = RequestLib.formatRequest({
            requestVersion: requestVersion,
            baseRequest: RequestLib.formatBaseRequest({
                originDomain: originDomain,
                nonce: nonce,
                originBurnToken: token,
                amount: amount,
                recipient: recipient
            }),
            swapParams: swapParams
        });
        bytes32 expectedRequestID = getCCTPRequestID(destDomain, requestVersion, expectedRequest);

        vm.expectEmit(synapseCCTP);
        emit CircleRequestSent({
            chainId: chainId,
            sender: user,
            nonce: nonce,
            token: token,
            amount: amount,
            requestVersion: requestVersion,
            formattedRequest: expectedRequest,
            requestID: expectedRequestID
        });
    }

    /// @dev Override for events to listen for with additional expected modules
    function checkExpectedBridgeEvent(
        uint256 chainId,
        bytes32 moduleId,
        address token,
        uint256 amount,
        SwapQuery memory destQuery
    ) public virtual;

    // TODO: test getter for getOriginAmountOut, getOriginBridgeTokens above
    function testSwaps() public {
        for (uint256 j = 0; j < expectedTokens.length; j++) {
            address token = expectedTokens[j];
            uint256 amount = getTestAmount(token);
            string[] memory symbols = router.getOriginBridgeTokens(token).symbols();
            SwapQuery[] memory queries = router.getOriginAmountOut(token, symbols, amount);
            for (uint256 k = 0; k < queries.length; k++) {
                checkSwap(recipient, token, amount, queries[k]);
            }
        }
    }

    function checkSwap(
        address to,
        address token,
        uint256 amount,
        SwapQuery memory query
    ) public virtual {
        mintToken(token, amount);
        approveSpending(token, address(router), amount);

        address tokenFrom = token;
        address tokenTo = query.tokenOut;
        uint256 expectedAmountOut = query.minAmountOut;

        console.log("Swapping: %s -> %s", tokenNames[tokenFrom], tokenNames[tokenTo]);
        console.log("   Expecting: %s -> %s", amount, expectedAmountOut);

        uint256 balanceFromBefore = IERC20(tokenFrom).balanceOf(user);
        uint256 balanceToBefore = IERC20(tokenTo).balanceOf(to);

        vm.prank(user);
        uint256 amountOut = router.swap(to, token, amount, query);
        assertEq(amountOut, expectedAmountOut, "Failed to get exact quote");

        // check balances after swap
        assertEq(
            IERC20(tokenFrom).balanceOf(user),
            tokenFrom == tokenTo && user == recipient
                ? balanceFromBefore - amount + amountOut
                : balanceFromBefore - amount
        );
        assertEq(
            IERC20(tokenTo).balanceOf(to),
            tokenFrom == tokenTo && user == recipient
                ? balanceToBefore + amountOut - amount
                : balanceToBefore + amountOut
        );
    }

    // ══════════════════════════════════════════════════ GENERIC HELPERS ══════════════════════════════════════════════════════

    function getModuleId(string memory moduleName) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(moduleName));
    }

    function hasParams(SwapQuery memory destQuery) public pure returns (bool) {
        return (destQuery.rawParams.length > 0);
    }

    function getTestAmount(address token) public view virtual returns (uint256) {
        // 0.01 units in the token decimals
        return 10**uint256(IERC20Metadata(token).decimals() - 2);
    }

    // Could be overridden if `deal` does not work with the token
    function mintToken(address token, uint256 amount) public virtual {
        deal(token, user, amount);
    }

    function approveSpending(
        address token,
        address spender,
        uint256 amount
    ) public {
        vm.startPrank(user);
        IERC20(token).safeApprove(spender, amount);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════ CCTP HELPERS ══════════════════════════════════════════════════════

    /// @dev see router/modules/bridge/SynapseCCTPModule.sol
    function deriveCCTPSwapParams(SwapQuery memory destQuery)
        public
        pure
        returns (uint32 requestVersion, bytes memory swapParams)
    {
        // Check if any action was specified in `destQuery`
        if (destQuery.routerAdapter == address(0)) {
            // No action was specified, so no swap is required
            return (RequestLib.REQUEST_BASE, "");
        }
        require(hasParams(destQuery), "CCTP dest query has no swap params");
        DefaultParams memory params = abi.decode(destQuery.rawParams, (DefaultParams));
        // Actions other than swap are not supported for Circle tokens on the destination chain
        require(params.action == Action.Swap, "invalid CCTP swap param action");
        require(params.tokenIndexFrom != params.tokenIndexTo, "invalid CCTP swap param token indices");
        requestVersion = RequestLib.REQUEST_SWAP;
        swapParams = RequestLib.formatSwapParams({
            tokenIndexFrom: params.tokenIndexFrom,
            tokenIndexTo: params.tokenIndexTo,
            deadline: destQuery.deadline,
            minAmountOut: destQuery.minAmountOut
        });
    }

    /// @notice Calculates the unique identifier of the request.
    /// @dev see cctp/SynapseCCTP.sol
    function getCCTPRequestID(
        uint32 destinationDomain,
        uint32 requestVersion,
        bytes memory formattedRequest
    ) public pure returns (bytes32 requestID) {
        // Merge the destination domain and the request version into a single uint256.
        uint256 prefix = (uint256(destinationDomain) << 32) | requestVersion;
        bytes32 requestHash = keccak256(formattedRequest);
        // Use assembly to return hash of the prefix and the request hash.
        // We are using scratch space to avoid unnecessary memory expansion.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Store prefix in memory at 0, and requestHash at 32.
            mstore(0, prefix)
            mstore(32, requestHash)
            // Return hash of first 64 bytes of memory.
            requestID := keccak256(0, 64)
        }
    }
}

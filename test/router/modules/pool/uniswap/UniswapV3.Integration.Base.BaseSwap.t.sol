// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IntegrationUtils} from "../../../../utils/IntegrationUtils.sol";

import {LinkedPool} from "../../../../../contracts/router/LinkedPool.sol";
import {IndexedToken, UniswapV3Module} from "../../../../../contracts/router/modules/pool/uniswap/UniswapV3Module.sol";

import {IERC20} from "@openzeppelin/contracts-4.5.0/token/ERC20/IERC20.sol";

contract UniswapV3ModuleBaseSwapBaseTestFork is IntegrationUtils {
    LinkedPool public linkedPool;
    UniswapV3Module public uniswapV3Module;

    // 2023-10-25
    uint256 public constant BASE_BLOCK_NUMBER = 5729000;

    // Uniswap V3 Router on Base
    address public constant UNI_V3_ROUTER = 0xacB8Ac8d5597A97267e16Dae214eE3F5dBd551BB;

    // Eden's Uniswap V3 Static Quoter on Base
    address public constant UNI_V3_STATIC_QUOTER = 0xbAD189BDF6a05FDaFA33CA917d094A64954093c4;

    // Uniswap V3 USDC/USDC.e pool on Base
    address public constant UNI_V3_USDC_POOL = 0x88492051E18a65FE00241A93699A6082aE95c828;

    // Bridged USDC (USDC_E) on Base
    address public constant USDC_E = 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA;

    // Native USDC on Base
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address public user;

    constructor() IntegrationUtils("base", "UniswapV3Module.BaseSwap", BASE_BLOCK_NUMBER) {}

    function afterBlockchainForked() public override {
        uniswapV3Module = new UniswapV3Module(UNI_V3_ROUTER, UNI_V3_STATIC_QUOTER);
        linkedPool = new LinkedPool(USDC, address(this));
        user = makeAddr("User");

        vm.label(UNI_V3_ROUTER, "UniswapV3Router");
        vm.label(UNI_V3_STATIC_QUOTER, "UniswapV3StaticQuoter");
        vm.label(UNI_V3_USDC_POOL, "UniswapV3USDCPool");
        vm.label(USDC_E, "USDC.e");
        vm.label(USDC, "USDC");
    }

    // ═══════════════════════════════════════════════ TESTS: VIEWS ════════════════════════════════════════════════════

    function testGetPoolTokens() public {
        address[] memory tokens = uniswapV3Module.getPoolTokens(UNI_V3_USDC_POOL);
        assertEq(tokens.length, 2);
        assertEq(tokens[0], USDC);
        assertEq(tokens[1], USDC_E);
    }

    // ══════════════════════════════════════════════ TESTS: ADD POOL ══════════════════════════════════════════════════

    function addPool() public {
        linkedPool.addPool({nodeIndex: 0, pool: UNI_V3_USDC_POOL, poolModule: address(uniswapV3Module)});
    }

    function testAddPool() public {
        addPool();
        assertEq(linkedPool.getToken(0), USDC);
        assertEq(linkedPool.getToken(1), USDC_E);
    }

    // ════════════════════════════════════════════════ TESTS: SWAP ════════════════════════════════════════════════════

    function swap(
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 amount
    ) public returns (uint256 amountOut) {
        vm.prank(user);
        amountOut = linkedPool.swap({
            nodeIndexFrom: tokenIndexFrom,
            nodeIndexTo: tokenIndexTo,
            dx: amount,
            minDy: 0,
            deadline: type(uint256).max
        });
    }

    function testSwapFromUSDCtoUSDCe() public {
        addPool();
        uint256 amount = 100 * 10**6;
        prepareUser(USDC, amount);
        uint256 expectedAmountOut = linkedPool.calculateSwap({nodeIndexFrom: 0, nodeIndexTo: 1, dx: amount});
        uint256 amountOut = swap({tokenIndexFrom: 0, tokenIndexTo: 1, amount: amount});
        assertGt(amountOut, 0);
        assertEq(amountOut, expectedAmountOut);
        assertEq(IERC20(USDC).balanceOf(user), 0);
        assertEq(IERC20(USDC_E).balanceOf(user), amountOut);
    }

    function testSwapFromUSDCetoUSDC() public {
        addPool();
        uint256 amount = 100 * 10**6;
        prepareUser(USDC_E, amount);
        uint256 expectedAmountOut = linkedPool.calculateSwap({nodeIndexFrom: 1, nodeIndexTo: 0, dx: amount});
        uint256 amountOut = swap({tokenIndexFrom: 1, tokenIndexTo: 0, amount: amount});
        assertGt(amountOut, 0);
        assertEq(amountOut, expectedAmountOut);
        assertEq(IERC20(USDC_E).balanceOf(user), 0);
        assertEq(IERC20(USDC).balanceOf(user), amountOut);
    }

    function testPoolSwapRevertsWhenDirectCall() public {
        vm.expectRevert("Not a delegate call");
        uniswapV3Module.poolSwap({
            pool: UNI_V3_USDC_POOL,
            tokenFrom: IndexedToken({index: 0, token: USDC}),
            tokenTo: IndexedToken({index: 1, token: USDC_E}),
            amountIn: 100 * 10**6
        });
    }

    function prepareUser(address token, uint256 amount) public {
        deal(token, user, amount);
        vm.prank(user);
        IERC20(token).approve(address(linkedPool), amount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import "./RateLimitedBridge.sol";

contract BridgeRateLimiterTestEth is RateLimitedBridge {
    address public constant BRIDGE = 0x2796317b0fF8538F253012862c06787Adfb8cEb6;
    address public constant NUSD_POOL =
        0x1116898DdA4015eD8dDefb84b6e8Bc24528Af2d8;

    IERC20 public constant NUSD =
        IERC20(0x1B84765dE8B7566e4cEAF4D0fD3c5aF52D3DdE4F);
    IERC20 public constant SYN =
        IERC20(0x0f2D719407FdBeFF09D87557AbB7232601FD9F29);

    constructor() RateLimitedBridge(BRIDGE) {
        this;
    }

    function testUpgradedCorrectly() public {
        bytes32[] memory kappas = new bytes32[](4);
        kappas[
            0
        ] = 0x58b29a4cf220b60a7e46b76b9831686c0bfbdbfea19721ef8f2192ba28514485;
        kappas[
            1
        ] = 0x3745754e018ed57dce0feda8b027f04b7e1369e7f74f1a247f5f7352d519021c;
        kappas[
            2
        ] = 0xea5bc18a60d2f1b9ba5e5f8bfef3cd112c3b1a1ef74a0de8e5989441b1722524;
        kappas[
            3
        ] = 0x1d4f3f6ed7690f1e5c1ff733d2040daa12fa484b3acbf37122ff334b46cf8b6d;

        _testUpgrade(kappas);
    }

    function testExactAllowance(uint96 amount) public {
        vm.assume(amount >= 3);
        vm.assume(amount <= _getBridgeBalance(NUSD));

        _setAllowance(NUSD, amount);

        uint96 totalBridged = 0;
        for (uint256 i = 0; i < 3; i++) {
            uint96 amountBridged = (
                i == 2 ? amount - totalBridged : amount / 3
            );
            bytes32 kappa = utils.getNextKappa();
            totalBridged += amountBridged;

            _checkCompleted(
                NUSD,
                amountBridged,
                0,
                kappa,
                NODE_GROUP,
                BRIDGE,
                IBridge.withdraw.selector,
                abi.encode(user, NUSD, amountBridged, 0, kappa),
                true
            );
        }

        // This should never happen
        assertEq(totalBridged, amount, "Sanity check failed");

        {
            uint256 amountBridged = 1;
            bytes32 kappa = utils.getNextKappa();
            // This should be rate limited
            _checkDelayed(
                kappa,
                NODE_GROUP,
                BRIDGE,
                IBridge.withdraw.selector,
                abi.encode(user, NUSD, amountBridged, 0, kappa)
            );
        }
    }

    function testMint(uint96 amount) public {
        _testBridgeFunction(
            amount,
            SYN,
            false,
            true,
            IBridge.mint.selector,
            bytes("")
        );
    }

    function testWithdraw(uint96 amount) public {
        _testBridgeFunction(
            amount,
            NUSD,
            true,
            true,
            IBridge.withdraw.selector,
            bytes("")
        );
    }

    function testWithdrawAndRemove(uint96 amount) public {
        _testBridgeFunction(
            amount,
            NUSD,
            true,
            false,
            IBridge.withdrawAndRemove.selector,
            abi.encode(NUSD_POOL, 0, 0, type(uint256).max)
        );
    }
}

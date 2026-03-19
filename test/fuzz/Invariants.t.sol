// SPDX-License-Identifier: MIT

// Have our Invariants aka properties
// What are our invariants?
//1. total supply of dsc < total value of collateral
//2. the getter view function should never revert  <-- evergreen invariant

pragma solidity ^0.8.18;
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStablecoin} from "../../src/DecentralizedStablecoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {Handler} from "./Handler.t.sol";

contract Invariants is StdInvariant, Test {
    DeployDSC deployer;
    DecentralizedStablecoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address weth;
    address wbtc;
    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    Handler handler;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        // targetContract(address(engine));
        handler = new Handler(engine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        //get the total value of collateral in the protocol
        //compare it all the debt (dsc)
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = ERC20Mock(weth).balanceOf(address(engine));
        uint256 totalBtcDeposited = ERC20Mock(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdvalue(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUsdvalue(wbtc, totalBtcDeposited);

        assert(wethValue + wbtcValue >= totalSupply);
    }
}

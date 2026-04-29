// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ERC20} from "../../PawnBroker.sol";
import {PawnBrokerFactory} from "../../PawnBrokerFactory.sol";
import {IPawnBroker} from "../../interfaces/IPawnBroker.sol";
import {IMorphoOracle} from "../../interfaces/IMorphoOracle.sol";

import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

interface IFactory {
    function governance() external view returns (address);

    function set_protocol_fee_bps(uint16) external;

    function set_protocol_fee_recipient(address) external;
}

contract Setup is Test, IEvents {
    ERC20 public asset;
    ERC20 public collateral;
    IPawnBroker public strategy;
    PawnBrokerFactory public pawnBrokerFactory;
    IMorphoOracle public collateralOracle;

    mapping(string => address) public tokenAddrs;

    address public user = address(10);
    address public borrower = address(11);
    address public liquidator = address(12);
    address public stranger = address(13);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);
    address public emergencyAdmin = address(5);

    address public factory;

    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;
    uint256 public maxFuzzAmount = 1_000_000e18;
    uint256 public minFuzzAmount = 1e18;
    uint256 public profitMaxUnlockTime = 10 days;

    uint256 public lltv = 915e15;
    uint256 public targetLtv = 9e17;
    uint256 public rate = 400;
    uint256 public callDuration = 1 weeks;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        _setTokenAddrs();

        asset = ERC20(tokenAddrs["USDC"]);
        collateral = ERC20(tokenAddrs["SIUSD"]);
        decimals = asset.decimals();

        collateralOracle = IMorphoOracle(0xd2cC46b9B2D761502eF933320ecf0268EC0dfa6d);

        pawnBrokerFactory = new PawnBrokerFactory(management, performanceFeeRecipient, keeper, emergencyAdmin);

        strategy = IPawnBroker(setUpPawnBroker());
        factory = strategy.FACTORY();

        vm.label(user, "user");
        vm.label(borrower, "borrower");
        vm.label(liquidator, "liquidator");
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(address(collateral), "collateral");
        vm.label(address(collateralOracle), "collateralOracle");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpPawnBroker() public returns (address) {
        IPawnBroker _strategy = IPawnBroker(
            address(
                pawnBrokerFactory.newPawnBroker(
                    address(asset),
                    "Pawn Broker",
                    borrower,
                    address(collateral),
                    address(collateralOracle),
                    lltv,
                    rate,
                    callDuration
                )
            )
        );

        vm.prank(management);
        _strategy.acceptManagement();

        return address(_strategy);
    }

    function setAllowed(address owner, bool isAllowed) public {
        vm.prank(management);
        strategy.setAllowed(owner, isAllowed);
    }

    function setLiquidator(address who, bool isAllowed) public {
        vm.prank(management);
        strategy.setLiquidator(who, isAllowed);
    }

    function toAssetAmount(uint256 wholeAmount) public view returns (uint256) {
        return wholeAmount * 10 ** asset.decimals();
    }

    function toCollateralAmount(uint256 wholeAmount) public view returns (uint256) {
        return wholeAmount * 10 ** collateral.decimals();
    }

    function collateralValue(uint256 collateralAmount) public view returns (uint256) {
        return Math.mulDiv(collateralAmount, collateralOracle.price(), 1e36);
    }

    function borrowAmountForLtv(uint256 collateralAmount, uint256 targetLtvRatio) public view returns (uint256) {
        return Math.mulDiv(collateralValue(collateralAmount), targetLtvRatio, 1e18);
    }

    function defaultLiquidityAmount() public view returns (uint256) {
        return toAssetAmount(200_000);
    }

    function defaultCollateralAmount() public view returns (uint256) {
        return toCollateralAmount(100_000);
    }

    function defaultBorrowAmount(uint256 collateralAmount) public view returns (uint256) {
        return borrowAmountForLtv(collateralAmount, targetLtv);
    }

    function depositIntoStrategy(IPawnBroker _strategy, address _user, uint256 _amount) public {
        vm.prank(management);
        _strategy.setAllowed(_user, true);

        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(IPawnBroker _strategy, address _user, uint256 _amount) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    function postCollateral(uint256 amount) public {
        airdrop(collateral, borrower, amount);

        vm.startPrank(borrower);
        collateral.approve(address(strategy), amount);
        strategy.postCollateral(amount);
        vm.stopPrank();
    }

    function checkStrategyTotals(IPawnBroker _strategy, uint256 _totalAssets, uint256 _totalDebt, uint256 _totalIdle)
        public
    {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(address(_strategy));
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setFees(uint16 _protocolFee, uint16 _performanceFee) public {
        address gov = IFactory(factory).governance();

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function _setTokenAddrs() internal {
        tokenAddrs["WBTC"] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        tokenAddrs["YFI"] = 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e;
        tokenAddrs["WETH"] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        tokenAddrs["LINK"] = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        tokenAddrs["USDT"] = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        tokenAddrs["DAI"] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        tokenAddrs["USDC"] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        tokenAddrs["SIUSD"] = 0xDBDC1Ef57537E34680B898E1FEBD3D68c7389bCB;
    }
}

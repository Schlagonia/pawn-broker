// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {Strategy} from "./Strategy.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

contract StrategyFactory {
    event NewStrategy(
        address indexed strategy,
        address indexed asset,
        address indexed borrower,
        address collateralAsset
    );

    address public immutable emergencyAdmin;

    address public management;
    address public performanceFeeRecipient;
    address public keeper;

    mapping(bytes32 => address) public deployments;
    mapping(address => bool) public deployedStrategies;

    constructor(
        address _management,
        address _performanceFeeRecipient,
        address _keeper,
        address _emergencyAdmin
    ) {
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        emergencyAdmin = _emergencyAdmin;
    }

    function newStrategy(
        address _asset,
        string calldata _name,
        address _borrower,
        address _collateralAsset,
        address _oracle,
        uint256 _lltv,
        uint256 _fixedRateBps,
        uint256 _callDuration
    ) external virtual returns (address) {
        bytes32 key = deploymentKey(
            _asset,
            _borrower,
            _collateralAsset,
            _oracle,
            _lltv,
            _fixedRateBps,
            _callDuration
        );
        require(deployments[key] == address(0), "strategy exists");

        IStrategyInterface _newStrategy = IStrategyInterface(
            address(
                new Strategy(
                    _asset,
                    _name,
                    _borrower,
                    _collateralAsset,
                    _oracle,
                    _lltv,
                    _fixedRateBps,
                    _callDuration
                )
            )
        );

        _newStrategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _newStrategy.setKeeper(keeper);
        _newStrategy.setPendingManagement(management);
        _newStrategy.setEmergencyAdmin(emergencyAdmin);

        deployments[key] = address(_newStrategy);
        deployedStrategies[address(_newStrategy)] = true;

        emit NewStrategy(
            address(_newStrategy),
            _asset,
            _borrower,
            _collateralAsset
        );
        return address(_newStrategy);
    }

    function deploymentKey(
        address _asset,
        address _borrower,
        address _collateralAsset,
        address _oracle,
        uint256 _lltv,
        uint256 _fixedRateBps,
        uint256 _callDuration
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    _asset,
                    _borrower,
                    _collateralAsset,
                    _oracle,
                    _lltv,
                    _fixedRateBps,
                    _callDuration
                )
            );
    }

    function deploymentFor(
        address _asset,
        address _borrower,
        address _collateralAsset,
        address _oracle,
        uint256 _lltv,
        uint256 _fixedRateBps,
        uint256 _callDuration
    ) external view returns (address) {
        return
            deployments[
                deploymentKey(
                    _asset,
                    _borrower,
                    _collateralAsset,
                    _oracle,
                    _lltv,
                    _fixedRateBps,
                    _callDuration
                )
            ];
    }

    function setAddresses(
        address _management,
        address _performanceFeeRecipient,
        address _keeper
    ) external {
        require(msg.sender == management, "!management");
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
    }

    function isDeployedStrategy(
        address _strategy
    ) external view returns (bool) {
        return deployedStrategies[_strategy];
    }
}

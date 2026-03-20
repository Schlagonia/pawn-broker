// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {Strategy} from "./Strategy.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

/// @notice Deploys and tracks strategy instances for unique loan configurations.
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

    /// @notice Configures the default roles assigned to newly deployed strategies.
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

    /// @notice Deploys a new strategy for a unique configuration.
    /// @return The address of the deployed strategy.
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
        bytes32 _key = deploymentKey(
            _asset,
            _borrower,
            _collateralAsset,
            _oracle,
            _lltv,
            _fixedRateBps,
            _callDuration
        );
        require(deployments[_key] == address(0), "strategy exists");

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

        deployments[_key] = address(_newStrategy);
        deployedStrategies[address(_newStrategy)] = true;

        emit NewStrategy(
            address(_newStrategy),
            _asset,
            _borrower,
            _collateralAsset
        );
        return address(_newStrategy);
    }

    /// @notice Returns the registry key for a strategy configuration.
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

    /// @notice Returns the deployed strategy for a configuration, if one exists.
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

    /// @notice Updates the default strategy role addresses.
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

    /// @notice Returns whether a strategy address was deployed by this factory.
    function isDeployedStrategy(
        address _strategy
    ) external view returns (bool) {
        return deployedStrategies[_strategy];
    }
}

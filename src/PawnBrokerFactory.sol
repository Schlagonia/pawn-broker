// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {PawnBroker} from "./PawnBroker.sol";
import {IPawnBroker} from "./interfaces/IPawnBroker.sol";

/// @notice Deploys and tracks pawn broker instances for unique loan configurations.
contract PawnBrokerFactory {
    event NewPawnBroker(
        address indexed pawnBroker,
        address indexed asset,
        address indexed borrower,
        address collateralAsset
    );

    address public immutable EMERGENCY_ADMIN;

    address public management;
    address public performanceFeeRecipient;
    address public keeper;

    mapping(bytes32 => address) public deployments;
    mapping(address => bool) public deployedPawnBrokers;

    /// @notice Configures the default roles assigned to newly deployed pawn brokers.
    constructor(
        address _management,
        address _performanceFeeRecipient,
        address _keeper,
        address _emergencyAdmin
    ) {
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        EMERGENCY_ADMIN = _emergencyAdmin;
    }

    /// @notice Deploys a new pawn broker for a unique configuration.
    /// @return The address of the deployed pawn broker.
    function newPawnBroker(
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
        require(deployments[_key] == address(0), "pawn broker exists");

        IPawnBroker _newPawnBroker = IPawnBroker(
            address(
                new PawnBroker(
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

        _newPawnBroker.setPerformanceFeeRecipient(performanceFeeRecipient);
        _newPawnBroker.setKeeper(keeper);
        _newPawnBroker.setPendingManagement(management);
        _newPawnBroker.setEmergencyAdmin(EMERGENCY_ADMIN);

        deployments[_key] = address(_newPawnBroker);
        deployedPawnBrokers[address(_newPawnBroker)] = true;

        emit NewPawnBroker(
            address(_newPawnBroker),
            _asset,
            _borrower,
            _collateralAsset
        );
        return address(_newPawnBroker);
    }

    /// @notice Returns the registry key for a pawn broker configuration.
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

    /// @notice Returns the deployed pawn broker for a configuration, if one exists.
    function pawnBrokerFor(
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

    /// @notice Updates the default pawn broker role addresses.
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

    /// @notice Returns whether a pawn broker address was deployed by this factory.
    function isDeployedPawnBroker(
        address _pawnBroker
    ) external view returns (bool) {
        return deployedPawnBrokers[_pawnBroker];
    }
}

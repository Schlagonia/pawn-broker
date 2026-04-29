// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {PawnBroker} from "./PawnBroker.sol";
import {IPawnBroker} from "./interfaces/IPawnBroker.sol";

/// @notice Deploys and tracks pawn broker instances for loan configurations.
contract PawnBrokerFactory {
    using EnumerableSet for EnumerableSet.AddressSet;

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

    mapping(bytes32 => EnumerableSet.AddressSet) internal pawnBrokersByKey;
    EnumerableSet.AddressSet internal allPawnBrokers;

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

    /// @notice Deploys a new pawn broker for a configuration.
    /// If the same configuration is deployed more than once, `pawnBrokerFor`
    /// returns the most recently deployed instance and `pawnBrokersFor`
    /// returns the full deployment history.
    /// @return The address of the deployed pawn broker.
    function newPawnBroker(
        address _asset,
        string calldata _name,
        address _borrower,
        address _collateralAsset,
        address _oracle,
        uint256 _lltv,
        uint256 _rateBps,
        uint256 _callDuration
    ) external virtual returns (address) {
        bytes32 _key = deploymentKey(
            _asset,
            _borrower,
            _collateralAsset,
            _oracle,
            _lltv,
            _rateBps,
            _callDuration
        );

        IPawnBroker _newPawnBroker = IPawnBroker(
            address(
                new PawnBroker(
                    _asset,
                    _name,
                    _borrower,
                    _collateralAsset,
                    _oracle,
                    _lltv,
                    _rateBps,
                    _callDuration
                )
            )
        );

        _newPawnBroker.setPerformanceFeeRecipient(performanceFeeRecipient);
        _newPawnBroker.setKeeper(keeper);
        _newPawnBroker.setPendingManagement(management);
        _newPawnBroker.setEmergencyAdmin(EMERGENCY_ADMIN);

        pawnBrokersByKey[_key].add(address(_newPawnBroker));
        allPawnBrokers.add(address(_newPawnBroker));

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
        uint256 _rateBps,
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
                    _rateBps,
                    _callDuration
                )
            );
    }

    /// @notice Returns the most recently deployed pawn broker for a configuration, if one exists.
    function pawnBrokerFor(
        address _asset,
        address _borrower,
        address _collateralAsset,
        address _oracle,
        uint256 _lltv,
        uint256 _rateBps,
        uint256 _callDuration
    ) external view returns (address) {
        EnumerableSet.AddressSet storage _pawnBrokers = pawnBrokersByKey[
            deploymentKey(
                _asset,
                _borrower,
                _collateralAsset,
                _oracle,
                _lltv,
                _rateBps,
                _callDuration
            )
        ];
        uint256 _length = _pawnBrokers.length();
        if (_length == 0) return address(0);
        return _pawnBrokers.at(_length - 1);
    }

    /// @notice Returns every pawn broker deployed for a configuration.
    function pawnBrokersFor(
        address _asset,
        address _borrower,
        address _collateralAsset,
        address _oracle,
        uint256 _lltv,
        uint256 _rateBps,
        uint256 _callDuration
    ) external view returns (address[] memory) {
        return
            pawnBrokersByKey[
                deploymentKey(
                    _asset,
                    _borrower,
                    _collateralAsset,
                    _oracle,
                    _lltv,
                    _rateBps,
                    _callDuration
                )
            ].values();
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
        return allPawnBrokers.contains(_pawnBroker);
    }
}

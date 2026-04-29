// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import {BaseHooks, ERC20, BaseHealthCheck} from "@periphery/Bases/Hooks/BaseHooks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMorphoOracle} from "./interfaces/IMorphoOracle.sol";
import {ILiquidator} from "./interfaces/ILiquidator.sol";

/// @notice Single-borrower pawn broker secured by posted collateral.
contract PawnBroker is BaseHooks {
    using SafeERC20 for ERC20;

    event CollateralPosted(address indexed caller, uint256 amount, uint256 totalCollateral);
    event CollateralWithdrawn(
        address indexed caller, address indexed receiver, uint256 amount, uint256 totalCollateral
    );
    event Borrowed(address indexed caller, address indexed receiver, uint256 amount, uint256 debtAmount);
    event Repaid(address indexed caller, uint256 amount, uint256 debtAmount, uint256 calledDebt);
    event DebtCalled(address indexed caller, uint256 amount, uint256 totalCalledDebt, uint256 deadline);
    event CallCleared(address indexed caller);
    event Liquidated(
        address indexed caller,
        address indexed receiver,
        uint256 repaidAmount,
        uint256 collateralSeized,
        uint256 debtAmount,
        uint256 totalCollateral
    );
    event LiquidatorUpdated(address indexed liquidator, bool isAllowed);
    event RateUpdateScheduled(uint256 newRate, uint256 effectiveTime);
    event RateUpdated(uint256 oldRate, uint256 newRate);

    modifier onlyBorrower() {
        require(msg.sender == BORROWER, "not borrower");
        _;
    }

    uint256 public constant LLTV_SCALE = 1e18;
    uint256 public constant ORACLE_PRICE_SCALE = 1e36;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @dev The only address allowed to post collateral, borrow, repay, and pull collateral.
    address public immutable BORROWER;
    /// @dev The collateral token backing the borrower position.
    address public immutable COLLATERAL_ASSET;
    /// @dev The oracle used to convert collateral into base-asset value.
    IMorphoOracle public immutable ORACLE;
    /// @dev The maximum loan-to-value ratio allowed for the position, scaled by `1e18`.
    uint256 public immutable LLTV;
    /// @dev The time window the borrower has to satisfy an active debt call.
    uint256 public immutable CALL_DURATION;

    /// @dev The amount of collateral currently posted by the borrower.
    uint256 public totalCollateral;
    /// @dev The current borrowable debt ceiling. Called debt is excluded.
    uint256 public maxDebt;
    /// @dev The active annualized interest rate charged on debt, in basis points.
    uint256 public rate;
    /// @dev The next annualized rate scheduled to become active.
    uint256 public pendingRate;
    /// @dev The timestamp when `pendingRate` may be applied, or zero.
    uint256 public pendingRateEffectiveTime;
    /// @dev The stored compounded debt balance after the last accrual update.
    uint256 internal debtAmount;
    /// @dev The timestamp of the last interest accrual.
    uint256 public lastAccrualTime;
    /// @dev The amount of debt currently under an active repayment call.
    /// Fully called positions keep accruing into this bucket until the call is cleared.
    uint256 public calledDebt;
    /// @dev The called debt already repaid and still sitting idle in the strategy.
    uint256 public repaidCalledDebt;
    /// @dev The deadline for the current debt call, or zero when no call is active.
    uint256 public callDeadline;

    /// @dev Addresses allowed to liquidate unhealthy or overdue positions.
    mapping(address => bool) public liquidators;

    /// @notice Deploys a pawn broker for one borrower, one collateral asset, and one oracle.
    constructor(
        address _asset,
        string memory _name,
        address _borrower,
        address _collateralAsset,
        address _oracle,
        uint256 _lltv,
        uint256 _rateBps,
        uint256 _callDuration
    ) BaseHealthCheck(_asset, _name) {
        require(_borrower != address(0), "zero borrower");
        require(_collateralAsset != address(0), "zero collateral");
        require(_oracle != address(0), "zero oracle");
        require(_collateralAsset != _asset, "shared asset");
        require(_lltv > 0 && _lltv < LLTV_SCALE, "bad lltv");
        require(_rateBps <= MAX_BPS, "bad rate");
        require(_callDuration > 0, "zero call duration");

        BORROWER = _borrower;
        COLLATERAL_ASSET = _collateralAsset;
        ORACLE = IMorphoOracle(_oracle);
        LLTV = _lltv;
        rate = _rateBps;
        CALL_DURATION = _callDuration;
        lastAccrualTime = block.timestamp;
    }

    ////////////////////////////////////////////////////////////////
    //                        SETTER FUNCTIONS                     //
    ////////////////////////////////////////////////////////////////

    /// @notice Sets whether an address may liquidate unhealthy or overdue debt.
    function setLiquidator(address _liquidator, bool _isAllowed) external onlyManagement {
        require(_liquidator != address(0), "zero liquidator");
        liquidators[_liquidator] = _isAllowed;
        emit LiquidatorUpdated(_liquidator, _isAllowed);
    }

    /// @notice Schedules a new rate after the call-duration delay.
    function setRate(uint256 _newRateBps) external onlyManagement {
        require(_newRateBps <= MAX_BPS, "bad rate");

        uint256 _effectiveTime = block.timestamp + CALL_DURATION;
        pendingRate = _newRateBps;
        pendingRateEffectiveTime = _effectiveTime;

        emit RateUpdateScheduled(_newRateBps, _effectiveTime);
    }

    /// @notice Applies the pending rate once its delay has elapsed.
    function applyPendingRate() external onlyManagement {
        uint256 _effectiveTime = pendingRateEffectiveTime;
        require(_effectiveTime != 0 && block.timestamp >= _effectiveTime, "rate not ready");

        _accrueInterest();

        uint256 _oldRate = rate;
        uint256 _newRate = pendingRate;

        rate = _newRate;
        pendingRate = 0;
        pendingRateEffectiveTime = 0;

        emit RateUpdated(_oldRate, _newRate);
    }

    ////////////////////////////////////////////////////////////////
    //                        BORROWER FUNCTIONS                    //
    ////////////////////////////////////////////////////////////////

    /// @notice Posts additional collateral for the borrower position.
    function postCollateral(uint256 _amount) external onlyBorrower {
        require(_amount > 0, "zero amount");

        _accrueInterest();
        ERC20(COLLATERAL_ASSET).safeTransferFrom(msg.sender, address(this), _amount);
        totalCollateral += _amount;

        emit CollateralPosted(msg.sender, _amount, totalCollateral);
    }

    /// @notice Borrows strategy assets against posted collateral.
    /// @param _amount The amount of base asset to borrow.
    /// @param _receiver The address that receives the borrowed assets.
    function borrow(uint256 _amount, address _receiver) external onlyBorrower {
        require(!TokenizedStrategy.isShutdown(), "shutdown");
        require(_amount > 0, "zero amount");
        require(_receiver != address(0), "zero receiver");
        require(callDeadline == 0, "debt called");

        uint256 _currentDebt = _accrueInterest();
        uint256 _newDebt = _currentDebt + _amount;
        require(_newDebt <= maxDebt, "max debt");
        require(_isSolventAt(_newDebt, totalCollateral) && !_isCallOverdue(), "position unhealthy");
        debtAmount = _newDebt;

        asset.safeTransfer(_receiver, _amount);

        emit Borrowed(msg.sender, _receiver, _amount, _newDebt);
    }

    /// @notice Repays outstanding debt.
    /// @param _amount The requested repayment amount.
    /// @return actualRepaid The amount of debt actually repaid.
    function repay(uint256 _amount) external onlyBorrower returns (uint256 actualRepaid) {
        require(_amount > 0, "zero amount");

        uint256 _currentDebt = _accrueInterest();
        require(_currentDebt > 0, "no debt");

        actualRepaid = Math.min(_amount, _currentDebt);
        _applyRepayment(actualRepaid);

        asset.safeTransferFrom(msg.sender, address(this), actualRepaid);

        emit Repaid(msg.sender, actualRepaid, debtAmount, calledDebt);
    }

    /// @notice Withdraws posted collateral when no debt call is active.
    /// @param _amount The amount of collateral to withdraw.
    /// @param _receiver The address that receives the collateral.
    function withdrawCollateral(uint256 _amount, address _receiver) external onlyBorrower {
        require(_amount > 0, "zero amount");
        require(_receiver != address(0), "zero receiver");
        require(callDeadline == 0, "debt called");

        uint256 _totalCollateral = totalCollateral;
        require(_amount <= _totalCollateral, "insufficient collateral");

        uint256 _currentDebt = _accrueInterest();

        _totalCollateral -= _amount;
        totalCollateral = _totalCollateral;
        require(_isSolventAt(_currentDebt, _totalCollateral) && !_isCallOverdue(), "position unhealthy");
        ERC20(COLLATERAL_ASSET).safeTransfer(_receiver, _amount);

        emit CollateralWithdrawn(msg.sender, _receiver, _amount, _totalCollateral);
    }

    /// @notice Calls debt and starts the repayment deadline window.
    /// @param _amount The additional amount of debt to call.
    function callDebt(uint256 _amount) external onlyManagement {
        require(_amount > 0, "zero amount");

        uint256 _currentDebt = _accrueInterest();
        require(_currentDebt > 0, "no debt");

        uint256 _availableDebtToCall = _currentDebt - calledDebt;
        uint256 _newlyCalledDebt = Math.min(_amount, _availableDebtToCall);
        require(_newlyCalledDebt > 0, "already fully called");

        calledDebt += _newlyCalledDebt;
        if (_newlyCalledDebt >= maxDebt) {
            maxDebt = 0;
        } else {
            maxDebt -= _newlyCalledDebt;
        }
        callDeadline = block.timestamp + CALL_DURATION;

        emit DebtCalled(msg.sender, _newlyCalledDebt, calledDebt, callDeadline);
    }

    /// @notice Repays debt and seizes collateral from a liquidatable position.
    /// @param _repayAmount The requested repayment amount.
    /// @param _receiver The address that receives seized collateral.
    /// @param _data Additional data to pass to the liquidator.
    /// @return actualRepaid The amount of debt actually repaid.
    /// @return collateralSeized The amount of collateral transferred to the receiver.
    function liquidate(uint256 _repayAmount, address _receiver, bytes calldata _data)
        external
        returns (uint256 actualRepaid, uint256 collateralSeized)
    {
        require(_repayAmount > 0, "zero amount");
        require(_receiver != address(0), "zero receiver");
        require(msg.sender == TokenizedStrategy.management() || liquidators[msg.sender], "not liquidator");

        uint256 _currentDebt = _accrueInterest();
        require(_currentDebt > 0, "no debt");

        uint256 _currentCollateral = totalCollateral;
        bool _callOverdue = _isCallOverdue();
        bool _solvent = _isSolventAt(_currentDebt, _currentCollateral);
        require(_callOverdue || !_solvent, "not liquidatable");

        uint256 _maxRepay = _currentDebt;
        // If just overdue but still solvent, repay the called debt.
        if (_solvent) _maxRepay = calledDebt;

        uint256 _positionCollateralValue = _collateralValue(_currentCollateral);
        _maxRepay = Math.min(_maxRepay, _positionCollateralValue);
        actualRepaid = Math.min(_repayAmount, _maxRepay);
        require(actualRepaid > 0, "repay too small");

        collateralSeized = _loanToCollateral(actualRepaid);
        require(collateralSeized > 0, "seize too small");
        if (collateralSeized > _currentCollateral) {
            collateralSeized = _currentCollateral;
        }

        totalCollateral -= collateralSeized;
        _applyRepayment(actualRepaid);

        ERC20(COLLATERAL_ASSET).safeTransfer(_receiver, collateralSeized);

        // If the caller has specified data.
        if (_data.length != 0) {
            // Do the callback.
            ILiquidator(_receiver).liquidateCallback(
                COLLATERAL_ASSET, msg.sender, collateralSeized, actualRepaid, _data
            );
        }

        asset.safeTransferFrom(msg.sender, address(this), actualRepaid);

        emit Liquidated(msg.sender, _receiver, actualRepaid, collateralSeized, debtAmount, totalCollateral);
    }

    ////////////////////////////////////////////////////////////////
    //                        VIEW FUNCTIONS                       //
    ////////////////////////////////////////////////////////////////

    /// @notice Returns current debt including accrued but unapplied interest.
    function totalDebt() public view returns (uint256) {
        return debtAmount + _previewInterest();
    }

    /// @notice Returns whether the current position is within the configured LLTV.
    function isSolvent() public view returns (bool) {
        return _isSolventAt(totalDebt(), totalCollateral);
    }

    /// @notice Returns whether the current position is solvent and not overdue.
    function isHealthy() public view returns (bool) {
        return isSolvent() && !_isCallOverdue();
    }

    /// @notice Returns the current loan-to-value ratio scaled by `1e18`.
    function currentLtv() public view returns (uint256) {
        uint256 _currentDebt = totalDebt();
        if (_currentDebt == 0) return 0;

        uint256 _positionCollateralValue = _collateralValue(totalCollateral);
        if (_positionCollateralValue == 0) return type(uint256).max;

        return Math.mulDiv(_currentDebt, LLTV_SCALE, _positionCollateralValue);
    }

    ////////////////////////////////////////////////////////////////
    //               TOKENIZED STRATEGY FUNCTIONS                 //
    ////////////////////////////////////////////////////////////////

    /// @notice Returns the deposit limit for an address.
    function availableDepositLimit(address _owner) public view override returns (uint256) {
        if (TokenizedStrategy.isShutdown()) return 0;
        if (allowed[_owner]) return type(uint256).max;
        return 0;
    }

    /// @notice Returns the amount of idle base asset currently withdrawable from the strategy.
    function availableWithdrawLimit(address) public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function _postDepositHook(uint256 _assets, uint256, address) internal override {
        maxDebt += _assets;
    }

    function _postWithdrawHook(uint256 _assets, uint256, address, address, uint256) internal override {
        if (_assets == 0) return;

        uint256 _repaidCalledConsumed = Math.min(repaidCalledDebt, _assets);
        if (_repaidCalledConsumed > 0) {
            repaidCalledDebt -= _repaidCalledConsumed;
        }

        uint256 _borrowableConsumed = Math.min(maxDebt, _assets - _repaidCalledConsumed);
        if (_borrowableConsumed > 0) {
            maxDebt -= _borrowableConsumed;
        }
    }

    function _deployFunds(uint256) internal pure override {}

    function _freeFunds(uint256) internal pure override {}

    function _harvestAndReport() internal override returns (uint256) {
        uint256 _currentDebt = _accrueInterest();
        uint256 _idleAssets = asset.balanceOf(address(this));

        if (_currentDebt == 0 || totalCollateral == 0) return _idleAssets;

        return _idleAssets + Math.min(_currentDebt, _collateralValue(totalCollateral));
    }

    ////////////////////////////////////////////////////////////////
    //                        INTERNAL FUNCTIONS                   //
    ////////////////////////////////////////////////////////////////

    function _accrueInterest() internal returns (uint256 _newDebt) {
        _newDebt = debtAmount;
        uint256 _accruedInterest = _previewInterest();
        if (_accruedInterest > 0) {
            if (calledDebt == _newDebt) {
                // Fully called positions keep accruing into this bucket until the call is cleared.
                calledDebt += _accruedInterest;
            } else {
                // Partial calls stay fixed at the requested amount.
                maxDebt += _accruedInterest;
            }

            _newDebt += _accruedInterest;
        }

        debtAmount = _newDebt;
        lastAccrualTime = block.timestamp;
    }

    function _applyRepayment(uint256 _amount) internal {
        uint256 _calledReduction = Math.min(calledDebt, _amount);
        if (_calledReduction > 0) {
            // Called debt that gets repaid stays non-borrowable. We track it separately
            // so later withdrawals do not accidentally reopen the line.
            calledDebt -= _calledReduction;
            repaidCalledDebt += _calledReduction;

            if (calledDebt == 0) {
                callDeadline = 0;
                emit CallCleared(msg.sender);
            }
        }

        debtAmount -= _amount;
    }

    function _isSolventAt(uint256 _currentDebt, uint256 _collateralAmount) internal view returns (bool) {
        if (_currentDebt == 0) return true;
        if (_collateralAmount == 0) return false;

        uint256 _maxDebt = Math.mulDiv(_collateralValue(_collateralAmount), LLTV, LLTV_SCALE);
        return _currentDebt <= _maxDebt;
    }

    function _isCallOverdue() internal view returns (bool) {
        return calledDebt > 0 && callDeadline > 0 && block.timestamp > callDeadline;
    }

    function _previewInterest() internal view returns (uint256) {
        if (debtAmount == 0) return 0;

        uint256 _elapsed = block.timestamp - lastAccrualTime;
        if (_elapsed == 0) return 0;

        uint256 _annualInterest = Math.mulDiv(debtAmount, rate, MAX_BPS);
        return Math.mulDiv(_annualInterest, _elapsed, SECONDS_PER_YEAR);
    }

    function _collateralValue(uint256 _collateralAmount) internal view returns (uint256) {
        if (_collateralAmount == 0) return 0;

        return Math.mulDiv(_collateralAmount, _price(), ORACLE_PRICE_SCALE);
    }

    function _loanToCollateral(uint256 _loanAmount) internal view returns (uint256) {
        if (_loanAmount == 0) return 0;

        return Math.mulDiv(_loanAmount, ORACLE_PRICE_SCALE, _price());
    }

    function _price() internal view returns (uint256) {
        uint256 _oraclePrice = ORACLE.price();
        require(_oraclePrice > 0, "zero oracle price");
        return _oraclePrice;
    }

    /// @notice Rescues unrelated tokens accidentally sent to the strategy.
    function rescue(address _token) external onlyManagement {
        require(_token != address(asset), "cannot rescue asset");
        require(_token != COLLATERAL_ASSET, "cannot rescue collateral");
        require(_token != address(this), "cannot rescue self");

        ERC20(_token).safeTransfer(msg.sender, ERC20(_token).balanceOf(address(this)));
    }
}

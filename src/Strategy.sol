// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMorphoOracle} from "./interfaces/IMorphoOracle.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

contract Strategy is BaseHealthCheck {
    using SafeERC20 for ERC20;
    using SafeERC20 for IERC20;

    event CollateralPosted(
        address indexed caller,
        uint256 amount,
        uint256 totalCollateral
    );
    event CollateralWithdrawn(
        address indexed caller,
        address indexed receiver,
        uint256 amount,
        uint256 totalCollateral
    );
    event Borrowed(
        address indexed caller,
        address indexed receiver,
        uint256 amount,
        uint256 debtAmount
    );
    event Repaid(
        address indexed caller,
        uint256 amount,
        uint256 debtAmount,
        uint256 calledDebtAmount
    );
    event DebtCalled(
        address indexed caller,
        uint256 amount,
        uint256 totalCalledDebt,
        uint256 deadline
    );
    event CallCleared(address indexed caller);
    event Liquidated(
        address indexed caller,
        address indexed receiver,
        uint256 repaidAmount,
        uint256 collateralSeized,
        uint256 debtAmount,
        uint256 totalCollateral
    );
    event UpdateAllowed(address indexed owner, bool isAllowed);
    event LiquidatorUpdated(address indexed liquidator, bool isAllowed);

    uint256 public constant LLTV_SCALE = 1e18;
    uint256 public constant ORACLE_PRICE_SCALE = 1e36;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    address internal immutable BORROWER;
    address internal immutable COLLATERAL_ASSET;
    IMorphoOracle internal immutable ORACLE;
    uint256 internal immutable LLTV;
    uint256 internal immutable FIXED_RATE;
    uint256 internal immutable CALL_DURATION;

    uint256 public totalCollateral;
    uint256 internal principalDebt;
    uint256 internal debtAmount;
    uint256 internal lastAccrualTime;
    uint256 public calledDebtAmount;
    uint256 public callDeadline;

    mapping(address => bool) internal allowed;
    mapping(address => bool) internal liquidators;

    constructor(
        address _asset,
        string memory _name,
        address _borrower,
        address _collateralAsset,
        address _oracle,
        uint256 _lltv,
        uint256 _fixedRateBps,
        uint256 _callDuration
    ) BaseHealthCheck(_asset, _name) {
        require(_borrower != address(0), "zero borrower");
        require(_collateralAsset != address(0), "zero collateral");
        require(_oracle != address(0), "zero oracle");
        require(_collateralAsset != _asset, "shared asset");
        require(_lltv > 0 && _lltv < LLTV_SCALE, "bad lltv");
        require(_callDuration > 0, "zero call duration");

        BORROWER = _borrower;
        COLLATERAL_ASSET = _collateralAsset;
        ORACLE = IMorphoOracle(_oracle);
        LLTV = _lltv;
        FIXED_RATE = _fixedRateBps;
        CALL_DURATION = _callDuration;
        lastAccrualTime = block.timestamp;
    }

    modifier onlyBorrower() {
        require(msg.sender == BORROWER, "not borrower");
        _;
    }

    function setAllowed(address owner, bool isAllowed) external onlyManagement {
        require(owner != address(0), "zero owner");
        allowed[owner] = isAllowed;
        emit UpdateAllowed(owner, isAllowed);
    }

    function setLiquidator(
        address liquidator,
        bool isAllowed
    ) external onlyManagement {
        require(liquidator != address(0), "zero liquidator");
        liquidators[liquidator] = isAllowed;
        emit LiquidatorUpdated(liquidator, isAllowed);
    }

    function postCollateral(uint256 amount) external onlyBorrower {
        require(amount > 0, "zero amount");

        _accrueInterest();
        IERC20(COLLATERAL_ASSET).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
        totalCollateral += amount;

        emit CollateralPosted(msg.sender, amount, totalCollateral);
    }

    function borrow(uint256 amount, address receiver) external onlyBorrower {
        require(!TokenizedStrategy.isShutdown(), "shutdown");
        require(amount > 0, "zero amount");
        require(receiver != address(0), "zero receiver");

        _accrueInterest();
        require(callDeadline == 0, "debt called");
        require(
            asset.balanceOf(address(this)) >= amount,
            "insufficient liquidity"
        );

        principalDebt += amount;
        debtAmount += amount;
        require(
            _isSolventAt(debtAmount, totalCollateral) && !_isCallOverdue(),
            "position unhealthy"
        );

        asset.safeTransfer(receiver, amount);

        emit Borrowed(msg.sender, receiver, amount, debtAmount);
    }

    function repay(
        uint256 amount
    ) external onlyBorrower returns (uint256 actualRepaid) {
        require(amount > 0, "zero amount");

        _accrueInterest();

        uint256 currentDebt = debtAmount;
        require(currentDebt > 0, "no debt");

        actualRepaid = Math.min(amount, currentDebt);
        asset.safeTransferFrom(msg.sender, address(this), actualRepaid);

        _applyRepayment(actualRepaid);

        _syncCallState(debtAmount);

        emit Repaid(msg.sender, actualRepaid, debtAmount, calledDebtAmount);
    }

    function withdrawCollateral(
        uint256 amount,
        address receiver
    ) external onlyBorrower {
        require(amount > 0, "zero amount");
        require(receiver != address(0), "zero receiver");

        _accrueInterest();
        require(callDeadline == 0, "debt called");
        require(amount <= totalCollateral, "insufficient collateral");

        totalCollateral -= amount;
        require(
            _isSolventAt(debtAmount, totalCollateral) && !_isCallOverdue(),
            "position unhealthy"
        );
        IERC20(COLLATERAL_ASSET).safeTransfer(receiver, amount);

        emit CollateralWithdrawn(msg.sender, receiver, amount, totalCollateral);
    }

    function callDebt(uint256 amount) external onlyManagement {
        require(amount > 0, "zero amount");

        _accrueInterest();

        uint256 currentDebt = debtAmount;
        require(currentDebt > 0, "no debt");

        if (calledDebtAmount > currentDebt) calledDebtAmount = currentDebt;

        uint256 updatedCalledDebt = Math.min(
            currentDebt,
            calledDebtAmount + amount
        );
        require(updatedCalledDebt > calledDebtAmount, "already fully called");

        calledDebtAmount = updatedCalledDebt;
        callDeadline = block.timestamp + CALL_DURATION;

        emit DebtCalled(msg.sender, amount, updatedCalledDebt, callDeadline);
    }

    function clearCall() external onlyManagement {
        _accrueInterest();
        require(calledDebtAmount == 0, "called debt active");
        _clearCallState();
    }

    function liquidate(
        uint256 repayAmount,
        address receiver
    ) external returns (uint256 actualRepaid, uint256 collateralSeized) {
        require(repayAmount > 0, "zero amount");
        require(receiver != address(0), "zero receiver");
        require(
            msg.sender == TokenizedStrategy.management() ||
                liquidators[msg.sender],
            "not liquidator"
        );

        _accrueInterest();

        uint256 currentDebt = debtAmount;
        require(currentDebt > 0, "no debt");

        bool callOverdue = _isCallOverdue();
        bool solvent = _isSolventAt(currentDebt, totalCollateral);
        require(callOverdue || !solvent, "not liquidatable");

        uint256 maxRepay = currentDebt;
        if (callOverdue && solvent) {
            maxRepay = calledDebtAmount;
        }

        uint256 collateralValue = _collateralValue(totalCollateral);
        maxRepay = Math.min(maxRepay, collateralValue);
        actualRepaid = Math.min(repayAmount, maxRepay);
        require(actualRepaid > 0, "repay too small");

        collateralSeized = _loanToCollateral(actualRepaid);
        require(collateralSeized > 0, "seize too small");
        if (collateralSeized > totalCollateral)
            collateralSeized = totalCollateral;

        asset.safeTransferFrom(msg.sender, address(this), actualRepaid);

        totalCollateral -= collateralSeized;
        _applyRepayment(actualRepaid);
        _syncCallState(debtAmount);

        IERC20(COLLATERAL_ASSET).safeTransfer(receiver, collateralSeized);

        emit Liquidated(
            msg.sender,
            receiver,
            actualRepaid,
            collateralSeized,
            debtAmount,
            totalCollateral
        );
    }

    function totalDebt() public view returns (uint256) {
        return debtAmount + _previewInterest();
    }

    function isSolvent() public view returns (bool) {
        return _isSolventAt(totalDebt(), totalCollateral);
    }

    function isHealthy() public view returns (bool) {
        return isSolvent() && !_isCallOverdue();
    }

    function currentLtv() public view returns (uint256) {
        uint256 currentDebt = totalDebt();
        if (currentDebt == 0) return 0;

        uint256 collateralValue = _collateralValue(totalCollateral);
        if (collateralValue == 0) return type(uint256).max;

        return Math.mulDiv(currentDebt, LLTV_SCALE, collateralValue);
    }

    function availableDepositLimit(
        address owner
    ) public view override returns (uint256) {
        if (TokenizedStrategy.isShutdown()) return 0;
        if (allowed[owner]) return type(uint256).max;
        return 0;
    }

    function availableWithdrawLimit(
        address
    ) public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function rescue(address token, address receiver) external onlyManagement {
        require(receiver != address(0), "zero receiver");
        require(token != address(asset), "cannot rescue asset");
        require(token != COLLATERAL_ASSET, "cannot rescue collateral");

        IERC20(token).safeTransfer(
            receiver,
            IERC20(token).balanceOf(address(this))
        );
    }

    function _deployFunds(uint256) internal override {}

    function _freeFunds(uint256) internal override {}

    function _harvestAndReport() internal view override returns (uint256) {
        uint256 currentDebt = totalDebt();
        uint256 totalAssets = asset.balanceOf(address(this));

        if (currentDebt == 0 || totalCollateral == 0) return totalAssets;

        return
            totalAssets +
            Math.min(currentDebt, _collateralValue(totalCollateral));
    }

    function _accrueInterest() internal {
        uint256 accruedInterest = _previewInterest();
        if (accruedInterest > 0) debtAmount += accruedInterest;

        lastAccrualTime = block.timestamp;
    }

    function _applyRepayment(uint256 amount) internal {
        uint256 calledReduction = Math.min(calledDebtAmount, amount);
        if (calledReduction > 0) calledDebtAmount -= calledReduction;

        uint256 remaining = amount;
        uint256 interestOutstanding = debtAmount - principalDebt;
        uint256 interestReduction = Math.min(interestOutstanding, remaining);
        remaining -= interestReduction;

        if (remaining > 0) principalDebt -= remaining;

        debtAmount -= amount;
    }

    function _syncCallState(uint256 currentDebt) internal {
        if (calledDebtAmount > currentDebt) calledDebtAmount = currentDebt;
    }

    function _clearCallState() internal {
        bool hadCall = calledDebtAmount != 0 || callDeadline != 0;

        calledDebtAmount = 0;
        callDeadline = 0;

        if (hadCall) emit CallCleared(msg.sender);
    }

    function _isSolventAt(
        uint256 currentDebt,
        uint256 collateralAmount
    ) internal view returns (bool) {
        if (currentDebt == 0) return true;
        if (collateralAmount == 0) return false;

        uint256 maxDebt = Math.mulDiv(
            _collateralValue(collateralAmount),
            LLTV,
            LLTV_SCALE
        );
        return currentDebt <= maxDebt;
    }

    function _isCallOverdue() internal view returns (bool) {
        return
            calledDebtAmount > 0 &&
            callDeadline > 0 &&
            block.timestamp > callDeadline;
    }

    function _previewInterest() internal view returns (uint256) {
        if (principalDebt == 0) return 0;

        uint256 elapsed = block.timestamp - lastAccrualTime;
        if (elapsed == 0) return 0;

        uint256 annualInterest = Math.mulDiv(
            principalDebt,
            FIXED_RATE,
            MAX_BPS
        );
        return Math.mulDiv(annualInterest, elapsed, SECONDS_PER_YEAR);
    }

    function _collateralValue(
        uint256 collateralAmount
    ) internal view returns (uint256) {
        if (collateralAmount == 0) return 0;

        uint256 price = ORACLE.price();
        require(price > 0, "zero oracle price");

        return Math.mulDiv(collateralAmount, price, ORACLE_PRICE_SCALE);
    }

    function _loanToCollateral(
        uint256 loanAmount
    ) internal view returns (uint256) {
        if (loanAmount == 0) return 0;

        uint256 price = ORACLE.price();
        require(price > 0, "zero oracle price");

        return Math.mulDiv(loanAmount, ORACLE_PRICE_SCALE, price);
    }
}

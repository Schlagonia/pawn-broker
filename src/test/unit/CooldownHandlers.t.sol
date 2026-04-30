// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SUSDeCooldownHandler} from "../../periphery/SUSDeCooldownHandler.sol";
import {SyrupCooldownHandler} from "../../periphery/SyrupCooldownHandler.sol";

contract MintableERC20 is ERC20 {
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}

contract MockSUSDe is ERC20 {
    MintableERC20 public immutable underlying;
    mapping(address => uint256) public cooldowns;

    constructor(MintableERC20 _underlying) ERC20("Staked USDe", "sUSDe") {
        underlying = _underlying;
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    function cooldownShares(uint256 _shares) external returns (uint256 assets) {
        _burn(msg.sender, _shares);
        cooldowns[msg.sender] += _shares;
        return _shares;
    }

    function unstake(address _receiver) external {
        uint256 _assets = cooldowns[msg.sender];
        require(_assets > 0, "no cooldown");
        cooldowns[msg.sender] = 0;
        underlying.mint(_receiver, _assets);
    }
}

contract MockSyrupPool is ERC20 {
    MintableERC20 public immutable underlying;
    mapping(address => uint256) public queuedShares;

    constructor(MintableERC20 _underlying) ERC20("Syrup Token", "syrup") {
        underlying = _underlying;
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    function convertToShares(uint256 _assets) external pure returns (uint256) {
        return _assets;
    }

    function requestRedeem(uint256 _shares, address _owner) external returns (uint256 exitShares) {
        require(_owner == msg.sender, "bad owner");
        _burn(_owner, _shares);
        queuedShares[_owner] += _shares;
        return _shares;
    }

    function removeShares(uint256 _shares, address _owner) external returns (uint256 removedShares) {
        require(_owner == msg.sender, "bad owner");
        removedShares = _shares > queuedShares[_owner] ? queuedShares[_owner] : _shares;
        queuedShares[_owner] -= removedShares;
        _mint(_owner, removedShares);
    }

    function fillRedemption(address _receiver, uint256 _assets) external {
        underlying.mint(_receiver, _assets);
    }
}

contract CooldownHandlersTest is Test {
    function test_sUSDeHandlerCooldownAndClaim() public {
        MintableERC20 usde = new MintableERC20("USDe", "USDe");
        MockSUSDe susde = new MockSUSDe(usde);
        SUSDeCooldownHandler handler = new SUSDeCooldownHandler(address(susde), address(this));

        uint256 shares = 10e18;
        susde.mint(address(handler), shares);

        uint256 queuedCollateral = handler.cooldown(shares);
        assertEq(queuedCollateral, shares);
        assertEq(handler.pendingCollateral(), shares);
        assertEq(handler.pendingAssets(), shares);
        assertEq(susde.balanceOf(address(handler)), 0);

        (uint256 claimedAssets, uint256 finalizedCollateral) = handler.claim(address(this));

        assertEq(claimedAssets, shares);
        assertEq(finalizedCollateral, shares);
        assertEq(handler.pendingCollateral(), 0);
        assertEq(usde.balanceOf(address(this)), shares);
    }

    function test_sUSDeHandlerRejectsCancel() public {
        MintableERC20 usde = new MintableERC20("USDe", "USDe");
        MockSUSDe susde = new MockSUSDe(usde);
        SUSDeCooldownHandler handler = new SUSDeCooldownHandler(address(susde), address(this));

        vm.expectRevert("unsupported");
        handler.cancel(1);
    }

    function test_syrupHandlerCooldownCancelAndClaim() public {
        MintableERC20 usdc = new MintableERC20("USDC", "USDC");
        MockSyrupPool syrup = new MockSyrupPool(usdc);
        SyrupCooldownHandler handler = new SyrupCooldownHandler(address(syrup), address(this));

        uint256 shares = 10e18;
        syrup.mint(address(handler), shares);

        uint256 queuedCollateral = handler.cooldown(shares);
        assertEq(queuedCollateral, shares);
        assertEq(handler.pendingCollateral(), shares);
        assertEq(syrup.balanceOf(address(handler)), 0);

        uint256 returnedCollateral = handler.cancel(4e18);
        assertEq(returnedCollateral, 4e18);
        assertEq(handler.pendingCollateral(), 6e18);
        assertEq(syrup.balanceOf(address(this)), 4e18);

        syrup.fillRedemption(address(handler), 6e18);
        (uint256 claimedAssets, uint256 finalizedCollateral) = handler.claim(address(this));

        assertEq(claimedAssets, 6e18);
        assertEq(finalizedCollateral, 6e18);
        assertEq(handler.pendingCollateral(), 0);
        assertEq(usdc.balanceOf(address(this)), 6e18);
    }
}

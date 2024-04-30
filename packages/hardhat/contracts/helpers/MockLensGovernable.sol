// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ILensGovernable} from "lens-modules/contracts/interfaces/ILensGovernable.sol";
import {Types} from "lens-modules/contracts/libraries/constants/Types.sol";

contract MockLensGovernable is ILensGovernable {
    address public treasury;
    uint16 public treasuryFeeBps;

    constructor(address _treasury, uint16 _treasuryFeeBps) {
        treasury = _treasury;
        treasuryFeeBps = _treasuryFeeBps;
    }

    function getTreasury() external view override returns (address) {
        return treasury;
    }

    function setTreasury(address _treasury) external override {
        treasury = _treasury;
    }

    function getTreasuryFee() external view override returns (uint16) {
        return treasuryFeeBps;
    }

    function setTreasuryFee(uint16 _treasuryFeeBps) external override {
        treasuryFeeBps = _treasuryFeeBps;
    }

    function getTreasuryData()
        external
        view
        override
        returns (address, uint16)
    {
        return (treasury, treasuryFeeBps);
    }

    function setTreasuryData(
        address _treasury,
        uint16 _treasuryFeeBps
    ) external {
        treasury = _treasury;
        treasuryFeeBps = _treasuryFeeBps;
    }

    // Other functions from ILensGovernable interface
    function setGovernance(address newGovernance) external override {}
    function setEmergencyAdmin(address newEmergencyAdmin) external override {}
    function setState(Types.ProtocolState newState) external override {}
    function whitelistProfileCreator(
        address profileCreator,
        bool whitelist
    ) external override {}
    function setProfileTokenURIContract(
        address profileTokenURIContract
    ) external override {}
    function setFollowTokenURIContract(
        address followTokenURIContract
    ) external override {}
    function getGovernance() external pure override returns (address) {
        return address(0);
    }
    function getState() external pure override returns (Types.ProtocolState) {
        return Types.ProtocolState.Unpaused;
    }
    function isProfileCreatorWhitelisted(
        address /* profileCreator */
    ) external pure override returns (bool) {
        return false;
    }
    function getProfileTokenURIContract()
        external
        pure
        override
        returns (address)
    {
        return address(0);
    }
    function getFollowTokenURIContract()
        external
        pure
        override
        returns (address)
    {
        return address(0);
    }
}

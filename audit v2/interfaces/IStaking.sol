// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

interface IStaking {
    function stake(uint _amount, address _recipient, bool _wrap) external;

    function addRebaseReward( uint _amount ) external;
}
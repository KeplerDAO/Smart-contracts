// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import "./interfaces/IStaking.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract StakingHelper {

    address public immutable staking;
    address public immutable KEEPER;

    constructor ( address _staking, address _KEEPER ) {
        require( _staking != address(0) );
        staking = _staking;
        require( _KEEPER != address(0) );
        KEEPER = _KEEPER;
    }

    function stake( uint _amount ) external {
        IERC20( KEEPER ).transferFrom( msg.sender, address(this), _amount );
        IERC20( KEEPER ).approve( staking, _amount );
        IStaking( staking ).stake( _amount, msg.sender );
        IStaking( staking ).claim( msg.sender );
    }
}
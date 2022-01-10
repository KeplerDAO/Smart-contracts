// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

interface ITreasury {
    function unstakeMint( uint _amount ) external;
    
    function SPVDeposit( address _token, uint _amount ) external;

    function SPVWithdraw( address _token, uint _amount ) external;

    function DAO() external view returns ( address );

    function spvDebt() external view returns ( uint );
}
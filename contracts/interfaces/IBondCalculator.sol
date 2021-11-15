// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

interface IBondCalculator {
    function markdown( address _LP ) external view returns ( uint );

    function valuation( address pair_, uint amount_ ) external view returns ( uint _value );
}
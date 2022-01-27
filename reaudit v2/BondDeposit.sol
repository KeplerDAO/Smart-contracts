// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./interfaces/IERC20Extended.sol";
import "./interfaces/IStaking.sol";
import "./interfaces/ITreasury.sol";


contract BondDeposit is Ownable {

    using SafeERC20 for IERC20;
    using SafeMath for uint;

    event BondCreated( address indexed token, uint indexed deposit, uint indexed expires );
    event BondRedeemed( address indexed recipient, uint indexed percent );

    /* ======== STATE VARIABLES ======== */

    address public immutable KEEPER; // intermediate token
    address public immutable USDC; // token used to create bond
    address public immutable USDT; // token used to create bond
    address public immutable DAI; // token used to create bond
    address public immutable treasury; // mints KEEPER when receives principle

    address public staking; // to auto-stake payout

    mapping( address => Bond ) public bondInfo; // stores bond information for depositors

    uint public immutable vestingTime;
    uint public totalDebt; // total value of outstanding bonds; used for pricing

    /* ======== STRUCTS ======== */

    // Info for bond holder
    struct Bond {
        uint keeperPayout;
        uint gonsPayout; // sKEEPER remaining to be paid
        uint vesting; // seconds left to vest
        uint lastTime; // Last interaction
    }

    constructor ( address _KEEPER, address _USDC, address _USDT, address _DAI, address _staking, address _treasury, uint _vestingTime) {
        require( _KEEPER != address(0) );
        KEEPER = _KEEPER;
        require( _USDC != address(0) );
        USDC = _USDC;
        require( _USDT != address(0) );
        USDT = _USDT;
        require( _DAI != address(0) );
        DAI = _DAI;
        require( _treasury != address(0) );
        treasury = _treasury;
        require( _staking != address(0) );
        staking = _staking;
        require( _vestingTime != 0 );
        vestingTime = _vestingTime;
    }


    /* ======== USER FUNCTIONS ======== */

    /**
     *  @notice depositReserve bond
     *  @param _token address
     *  @param _amount uint
     *  @param _depositor address
     *  @param _stake bool
     */
    function depositReserve( address _token, uint _amount, address _depositor, bool _stake) external {
        require( _token == USDC || _token == USDT || _token == DAI, "Invalid token" );
        
        IERC20( _token ).safeTransferFrom( msg.sender, address(this), _amount );
        IERC20( _token ).approve( address( treasury ), _amount );
        uint value = ITreasury( treasury ).deposit( _amount, _token, _stake );
        
        createBond( value, _depositor, _stake );
        emit BondCreated( _token, _amount, block.timestamp.add( vestingTime ) );
    }


    function depositEthereum( uint _amount, address _depositor, bool _stake) external payable {
        require( _amount == msg.value, "Amount mismatch" );
        uint value = ITreasury( treasury ).depositEth{value: _amount}( _amount, _stake );

        createBond( value, _depositor, _stake );
        emit BondCreated( address(0), _amount, block.timestamp.add( vestingTime ) );
    }


    function createBond( uint value, address _depositor, bool _stake ) internal {
        // total debt is increased
        totalDebt = totalDebt.add( value ); 
        uint stakeGons;
        uint keeperAmount;
        if ( _stake ) {
            stakeGons = IStaking(staking).getGonsAmount(value);
        } else {
            keeperAmount = value;
        }
        // depositor info is stored
        bondInfo[ _depositor ] = Bond({ 
            keeperPayout: bondInfo[ _depositor ].keeperPayout.add( keeperAmount ),
            gonsPayout: bondInfo[ _depositor ].gonsPayout.add( stakeGons ),
            vesting: vestingTime,
            lastTime: block.timestamp
        });
    }

    /** 
     *  @notice redeem bond for user
     *  @param _recipient address
     */ 
    function redeem( address _recipient ) external {        
        Bond memory info = bondInfo[ _recipient ];
        uint percentVested = percentVestedFor( _recipient ); // (vesting term remaining)

        if ( percentVested >= 10000 ) { // if fully vested
            percentVested = 10000;
            delete bondInfo[ _recipient ]; // delete user info
            if ( info.keeperPayout > 0 ) {
                IERC20( KEEPER ).transfer( _recipient, info.keeperPayout );
            }
            if ( info.gonsPayout > 0 ) {
                IStaking( staking ).transfer( _recipient, info.gonsPayout );
            }

        } else { // if unfinished
            // calculate payout vested
            uint keeperPayout = info.keeperPayout.mul( percentVested ).div( 10000 );
            if ( keeperPayout > 0 ) {
                IERC20( KEEPER ).transfer( _recipient, keeperPayout );
            }
            uint gonsPayout = info.gonsPayout.mul( percentVested ).div( 10000 );
            if ( gonsPayout > 0 ) {
                IStaking( staking ).transfer( _recipient, gonsPayout );
            }
            // store updated deposit info
            bondInfo[ _recipient ] = Bond({
                keeperPayout: info.keeperPayout.sub( keeperPayout ),
                gonsPayout: info.gonsPayout.sub( gonsPayout ),
                vesting: info.vesting.sub( block.timestamp.sub( info.lastTime ) ),
                lastTime: block.timestamp
            });
        }
        emit BondRedeemed( _recipient, percentVested ); // emit bond data
    }



    
    /* ======== INTERNAL HELPER FUNCTIONS ======== */

    function getBondInfo(address _depositor) public view returns ( uint keeperPayout, uint skeeperPayout, uint vesting, uint lastTime ) {
        Bond memory info = bondInfo[ _depositor ];
        keeperPayout = info.keeperPayout;
        skeeperPayout = IStaking(staking).getKeeperAmount(info.gonsPayout);
        vesting = info.vesting;
        lastTime = info.lastTime;
    }


    function percentVestedFor( address _depositor ) public view returns ( uint percentVested_ ) {
        Bond memory bond = bondInfo[ _depositor ];
        uint timeSinceLast = block.timestamp.sub( bond.lastTime );
        uint vesting = bond.vesting;

        if ( vesting > 0 ) {
            percentVested_ = timeSinceLast.mul( 10000 ).div( vesting );
        } else {
            percentVested_ = 0;
        }
    }


    function pendingPayoutFor( address _depositor ) external view returns ( uint keeperPending, uint skeeperPending ) {
        uint percentVested = percentVestedFor( _depositor );
        uint keeperPayout = bondInfo[_depositor].keeperPayout;
        uint skeeperPayout = IStaking(staking).getKeeperAmount(bondInfo[_depositor].gonsPayout);

        if ( percentVested >= 10000 ) {
            keeperPending = keeperPayout;
            skeeperPending = skeeperPayout;
        } else {
            keeperPending = keeperPayout.mul( percentVested ).div( 10000 );
            skeeperPending = skeeperPayout.mul( percentVested ).div( 10000 );
        }
    }
}
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./interfaces/IBondCalculator.sol";
import "./interfaces/IERC20Extended.sol";
import "./interfaces/IStaking.sol";
import "./interfaces/ITreasury.sol";
import "./libraries/FixedPoint.sol";
import "./libraries/SafeMathExtended.sol";


contract BondDepository is Ownable {

    using FixedPoint for *;
    using SafeERC20 for IERC20;
    using SafeMathExtended for uint;
    using SafeMathExtended for uint32;

    event BondCreated( uint deposit, uint indexed payout, uint indexed expires, uint indexed priceInUSD );
    event BondRedeemed( address indexed recipient, uint payout, uint remaining );
    event BondPriceChanged( uint indexed priceInUSD, uint indexed internalPrice, uint indexed debtRatio );
    event ControlVariableAdjustment( uint initialBCV, uint newBCV, uint adjustment, bool addition );

    /* ======== STATE VARIABLES ======== */

    address public immutable KEEPER; // token given as payment for bond
    address public immutable principle; // token used to create bond
    address public immutable treasury; // mints KEEPER when receives principle
    address public immutable DAO; // receives profit share from bond

    address public immutable bondCalculator; // calculates value of LP tokens
    bool public immutable isLiquidityBond; // LP and Reserve bonds are treated slightly different

    address public staking; // to auto-stake payout
    Terms public terms; // stores terms for new bonds
    Adjust public adjustment; // stores adjustment to BCV data

    mapping( address => Bond ) public bondInfo; // stores bond information for depositors

    uint public totalDebt; // total value of outstanding bonds; used for pricing
    uint32 public lastDecay; // reference time for debt decay

    /* ======== STRUCTS ======== */

    // Info for creating new bonds
    struct Terms {
        uint controlVariable; // scaling variable for price
        uint minimumPrice; // vs principle value
        uint maxPayout; // in thousandths of a %. i.e. 500 = 0.5%
        uint fee; // as % of bond payout, in hundreths. ( 500 = 5% = 0.05 for every 1 paid)
        uint maxDebt; // 9 decimal debt ratio, max % total supply created as debt
        uint32 vestingTerm; // in seconds
    }

    // Info for bond holder
    struct Bond {
        uint payout; // KEEPER remaining to be paid
        uint pricePaid; // In DAI, for front end viewing
        uint32 vesting; // seconds left to vest
        uint32 lastTime; // Last interaction
    }

    // Info for incremental adjustments to control variable 
    struct Adjust {
        bool add; // addition or subtraction
        uint rate; // increment
        uint target; // BCV when adjustment finished
        uint32 buffer; // minimum length (in seconds) between adjustments
        uint32 lastTime; // timestamp when last adjustment made
    }

    constructor ( address _KEEPER, address _principle, address _treasury, address _DAO, address _bondCalculator) {
        require( _KEEPER != address(0) );
        KEEPER = _KEEPER;
        require( _principle != address(0) );
        principle = _principle;
        require( _treasury != address(0) );
        treasury = _treasury;
        require( _DAO != address(0) );
        DAO = _DAO;
        // bondCalculator should be address(0) if not LP bond
        bondCalculator = _bondCalculator;
        isLiquidityBond = ( _bondCalculator != address(0) );
    }

    /**
     *  @notice initializes bond parameters
     *  @param _controlVariable uint
     *  @param _vestingTerm uint
     *  @param _minimumPrice uint
     *  @param _maxPayout uint
     *  @param _fee uint
     *  @param _maxDebt uint
     *  @param _initialDebt uint
     */
    function initializeBondTerms(uint _controlVariable, uint32 _vestingTerm, uint _minimumPrice, uint _maxPayout,
                                 uint _fee, uint _maxDebt, uint _initialDebt)
    external onlyOwner() {
        require( terms.controlVariable == 0, "Bonds must be initialized from 0" );
        terms = Terms ({
            controlVariable: _controlVariable,
            vestingTerm: _vestingTerm,
            minimumPrice: _minimumPrice,
            maxPayout: _maxPayout,
            fee: _fee,
            maxDebt: _maxDebt
        });
        totalDebt = _initialDebt;
        lastDecay = uint32(block.timestamp);
    }

    /* ======== POLICY FUNCTIONS ======== */

    enum PARAMETER { VESTING, PAYOUT, FEE, DEBT, MINPRICE }
    /**
     *  @notice set parameters for new bonds
     *  @param _parameter PARAMETER
     *  @param _input uint
     */
    function setBondTerms ( PARAMETER _parameter, uint _input ) external onlyOwner() {
        if ( _parameter == PARAMETER.VESTING ) { // 0
            require( _input >= 129600, "Vesting must be longer than 36 hours" );
            terms.vestingTerm = uint32(_input);
        } else if ( _parameter == PARAMETER.PAYOUT ) { // 1
            require( _input <= 1000, "Payout cannot be above 1 percent" );
            terms.maxPayout = _input;
        } else if ( _parameter == PARAMETER.FEE ) { // 2
            require( _input <= 10000, "DAO fee cannot exceed payout" );
            terms.fee = _input;
        } else if ( _parameter == PARAMETER.DEBT ) { // 3
            terms.maxDebt = _input;
        } else if ( _parameter == PARAMETER.MINPRICE ) { // 4
            terms.minimumPrice = _input;
        }
    }

    /**
     *  @notice set control variable adjustment
     *  @param _addition bool
     *  @param _increment uint
     *  @param _target uint
     *  @param _buffer uint
     */
    function setAdjustment ( bool _addition, uint _increment, uint _target, uint32 _buffer) external onlyOwner() {
        require( _increment <= terms.controlVariable.mul( 25 ).div( 1000 ), "Increment too large" );

        adjustment = Adjust({
            add: _addition,
            rate: _increment,
            target: _target,
            buffer: _buffer,
            lastTime: uint32(block.timestamp)
        });
    }

    /**
     *  @notice set contract for auto stake
     *  @param _staking address
     */
    function setStaking( address _staking ) external onlyOwner() {
        require( _staking != address(0) );
        staking = _staking;
    }


    /* ======== USER FUNCTIONS ======== */

    /**
     *  @notice deposit bond
     *  @param _amount uint
     *  @param _maxPrice uint
     *  @param _depositor address
     *  @return uint
     */
    function deposit( uint _amount, uint _maxPrice, address _depositor) external returns ( uint ) {
        require( _depositor != address(0), "Invalid address" );
        decayDebt();
        require( totalDebt <= terms.maxDebt, "Max capacity reached" );
        
        uint priceInUSD = bondPriceInUSD(); // Stored in bond info
        uint nativePrice = _bondPrice();

        require( _maxPrice >= nativePrice, "Slippage limit: more than max price" ); // slippage protection

        uint value = ITreasury( treasury ).valueOfToken( principle, _amount );
        uint payout = payoutFor( value ); // payout to bonder is computed

        require( payout >= 10000000, "Bond too small" ); // must be > 0.01 KEEPER ( underflow protection )
        require( payout <= maxPayout(), "Bond too large"); // size protection because there is no slippage

        // profits are calculated
        uint fee = payout.mul( terms.fee ).div( 10000 );
        uint profit = value.sub( payout ).sub( fee );

        /**
            principle is transferred in
            approved and
            deposited into the treasury, returning (_amount - profit) KEEPER
         */
        IERC20( principle ).safeTransferFrom( msg.sender, address(this), _amount );
        IERC20( principle ).approve( address( treasury ), _amount );
        ITreasury( treasury ).deposit( _amount, principle, profit );
        
        if ( fee != 0 ) { // fee is transferred to dao 
            IERC20( KEEPER ).safeTransfer( DAO, fee ); 
        }
        
        // total debt is increased
        totalDebt = totalDebt.add( value ); 
                
        // depositor info is stored
        bondInfo[ _depositor ] = Bond({ 
            payout: bondInfo[ _depositor ].payout.add( payout ),
            vesting: terms.vestingTerm,
            lastTime: uint32(block.timestamp),
            pricePaid: priceInUSD
        });

        // indexed events are emitted
        emit BondCreated( _amount, payout, block.timestamp.add( terms.vestingTerm ), priceInUSD );
        emit BondPriceChanged( bondPriceInUSD(), _bondPrice(), debtRatio() );

        adjust(); // control variable is adjusted
        return payout; 
    }

    /** 
     *  @notice redeem bond for user
     *  @param _recipient address
     *  @param _stake bool
     *  @return uint
     */ 
    function redeem( address _recipient, bool _stake, bool _wrap ) external returns ( uint ) {        
        Bond memory info = bondInfo[ _recipient ];
        uint percentVested = percentVestedFor( _recipient ); // (blocks since last interaction / vesting term remaining)

        if ( percentVested >= 10000 ) { // if fully vested
            delete bondInfo[ _recipient ]; // delete user info
            emit BondRedeemed( _recipient, info.payout, 0 ); // emit bond data
            return stakeOrSend( _recipient, _stake, _wrap, info.payout ); // pay user everything due

        } else { // if unfinished
            // calculate payout vested
            uint payout = info.payout.mul( percentVested ).div( 10000 );

            // store updated deposit info
            bondInfo[ _recipient ] = Bond({
                payout: info.payout.sub( payout ),
                vesting: info.vesting.sub32( uint32(block.timestamp).sub32( info.lastTime ) ),
                lastTime: uint32(block.timestamp),
                pricePaid: info.pricePaid
            });

            emit BondRedeemed( _recipient, payout, bondInfo[ _recipient ].payout );
            return stakeOrSend( _recipient, _stake, _wrap, payout );
        }
    }



    
    /* ======== INTERNAL HELPER FUNCTIONS ======== */

    /**
     *  @notice allow user to stake payout automatically
     *  @param _stake bool
     *  @param _amount uint
     *  @return uint
     */
    function stakeOrSend( address _recipient, bool _stake, bool _wrap, uint _amount ) internal returns ( uint ) {
        if ( !_stake ) { // if user does not want to stake
            IERC20( KEEPER ).transfer( _recipient, _amount ); // send payout
        } else { // if user wants to stake
            IERC20( KEEPER ).approve( staking, _amount );
            IStaking( staking ).stake( _amount, _recipient, _wrap );
        }
        return _amount;
    }

    /**
     *  @notice makes incremental adjustment to control variable
     */
    function adjust() internal {
        uint timeCanAdjust = adjustment.lastTime.add( adjustment.buffer );
        if( adjustment.rate != 0 && block.timestamp >= timeCanAdjust ) {
            uint initial = terms.controlVariable;
            if ( adjustment.add ) {
                terms.controlVariable = terms.controlVariable.add( adjustment.rate );
                if ( terms.controlVariable >= adjustment.target ) {
                    adjustment.rate = 0;
                }
            } else {
                terms.controlVariable = terms.controlVariable.sub( adjustment.rate );
                if ( terms.controlVariable <= adjustment.target ) {
                    adjustment.rate = 0;
                }
            }
            adjustment.lastTime = uint32(block.timestamp);
            emit ControlVariableAdjustment( initial, terms.controlVariable, adjustment.rate, adjustment.add );
        }
    }

    /**
     *  @notice reduce total debt
     */
    function decayDebt() internal {
        totalDebt = totalDebt.sub( debtDecay() );
        lastDecay = uint32(block.timestamp);
    }



    /* ======== VIEW FUNCTIONS ======== */

    /**
     *  @notice determine maximum bond size
     *  @return uint
     */
    function maxPayout() public view returns ( uint ) {
        return IERC20( KEEPER ).totalSupply().mul( terms.maxPayout ).div( 100000 );
    }

    /**
     *  @notice calculate interest due for new bond
     *  @param _value uint
     *  @return uint
     */
    function payoutFor( uint _value ) public view returns ( uint ) {
        return FixedPoint.fraction( _value, bondPrice() ).decode112with18().div( 1e16 );
    }


    /**
     *  @notice calculate current bond premium
     *  @return price_ uint
     */
    function bondPrice() public view returns ( uint price_ ) {        
        price_ = terms.controlVariable.mul( debtRatio() ).add( 1000000000 ).div( 1e7 );
        if ( price_ < terms.minimumPrice ) {
            price_ = terms.minimumPrice;
        }
    }

    /**
     *  @notice calculate current bond price and remove floor if above
     *  @return price_ uint
     */
    function _bondPrice() internal returns ( uint price_ ) {
        price_ = terms.controlVariable.mul( debtRatio() ).add( 1000000000 ).div( 1e7 );
        if ( price_ < terms.minimumPrice ) {
            price_ = terms.minimumPrice;        
        } else if ( terms.minimumPrice != 0 ) {
            terms.minimumPrice = 0;
        }
    }

    /**
     *  @notice converts bond price to DAI value
     *  @return price_ uint
     */
    function bondPriceInUSD() public view returns ( uint price_ ) {
        if( isLiquidityBond ) {
            price_ = bondPrice().mul( IBondCalculator( bondCalculator ).markdown( principle ) ).div( 100 );
        } else {
            price_ = bondPrice().mul( 10 ** IERC20Extended( principle ).decimals() ).div( 100 );
        }
    }


    /**
     *  @notice calculate current ratio of debt to KEEPER supply
     *  @return debtRatio_ uint
     */
    function debtRatio() public view returns ( uint debtRatio_ ) {   
        uint supply = IERC20( KEEPER ).totalSupply();
        debtRatio_ = FixedPoint.fraction( 
            currentDebt().mul( 1e9 ), 
            supply
        ).decode112with18().div( 1e18 );
    }

    /**
     *  @notice debt ratio in same terms for reserve or liquidity bonds
     *  @return uint
     */
    function standardizedDebtRatio() external view returns ( uint ) {
        if ( isLiquidityBond ) {
            return debtRatio().mul( IBondCalculator( bondCalculator ).markdown( principle ) ).div( 1e9 );
        } else {
            return debtRatio();
        }
    }

    /**
     *  @notice calculate debt factoring in decay
     *  @return uint
     */
    function currentDebt() public view returns ( uint ) {
        return totalDebt.sub( debtDecay() );
    }

    /**
     *  @notice amount to decay total debt by
     *  @return decay_ uint
     */
    function debtDecay() public view returns ( uint decay_ ) {
        uint32 timeSinceLast = uint32(block.timestamp).sub32( lastDecay );
        decay_ = totalDebt.mul( timeSinceLast ).div( terms.vestingTerm );
        if ( decay_ > totalDebt ) {
            decay_ = totalDebt;
        }
    }


    /**
     *  @notice calculate how far into vesting a depositor is
     *  @param _depositor address
     *  @return percentVested_ uint
     */
    function percentVestedFor( address _depositor ) public view returns ( uint percentVested_ ) {
        Bond memory bond = bondInfo[ _depositor ];
        uint timeSinceLast = uint32(block.timestamp).sub( bond.lastTime );
        uint vesting = bond.vesting;

        if ( vesting > 0 ) {
            percentVested_ = timeSinceLast.mul( 10000 ).div( vesting );
        } else {
            percentVested_ = 0;
        }
    }

    /**
     *  @notice calculate amount of KEEPER available for claim by depositor
     *  @param _depositor address
     *  @return pendingPayout_ uint
     */
    function pendingPayoutFor( address _depositor ) external view returns ( uint pendingPayout_ ) {
        uint percentVested = percentVestedFor( _depositor );
        uint payout = bondInfo[ _depositor ].payout;

        if ( percentVested >= 10000 ) {
            pendingPayout_ = payout;
        } else {
            pendingPayout_ = payout.mul( percentVested ).div( 10000 );
        }
    }




    /* ======= AUXILLIARY ======= */

    /**
     *  @notice allow anyone to send lost tokens (excluding principle or KEEPER) to the DAO
     *  @return bool
     */
    function recoverLostToken( address _token ) external returns ( bool ) {
        require( _token != KEEPER );
        require( _token != principle );
        IERC20( _token ).safeTransfer( DAO, IERC20( _token ).balanceOf( address(this) ) );
        return true;
    }
}
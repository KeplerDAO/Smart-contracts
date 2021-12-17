// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./interfaces/IDistributor.sol";
import "./interfaces/IsKEEPER.sol";
import "./interfaces/IwTROVE.sol";
import "./libraries/SafeMathExtended.sol";

contract Staking is Ownable {
    
    using SafeERC20 for IERC20;
    using SafeERC20 for IsKEEPER;
    using SafeMathExtended for uint256;
    using SafeMathExtended for uint32;

    event DistributorSet( address distributor );
    event WarmupSet( uint warmup );

    struct Epoch {
        uint32 length;
        uint32 endTime;
        uint32 number;
        uint distribute;
    }

    struct Claim {
        uint deposit;
        uint gons;
        uint expiry;
        bool lock; // prevents malicious delays
    }

    IERC20 public immutable KEEPER;
    IsKEEPER public immutable sKEEPER;
    IwTROVE public immutable wTROVE;
    Epoch public epoch;
    address public distributor;
    mapping( address => Claim ) public warmupInfo;
    uint32 public warmupPeriod;
    uint gonsInWarmup;


    constructor (address _KEEPER, address _sKEEPER, address _wTROVE, uint32 _epochLength, uint32 _firstEpochNumber, uint32 _firstEpochTime) {
        require( _KEEPER != address(0) );
        KEEPER = IERC20( _KEEPER );
        require( _sKEEPER != address(0) );
        sKEEPER = IsKEEPER( _sKEEPER );
        require( _wTROVE != address(0) );
        wTROVE = IwTROVE( _wTROVE );
        epoch = Epoch({
            length: _epochLength,
            number: _firstEpochNumber,
            endTime: _firstEpochTime,
            distribute: 0
        });
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice stake KEEPER to enter warmup
     * @param _amount uint
     * @param _recipient address
     */
    function stake( uint _amount, address _recipient, bool _wrap ) external returns ( uint ) {
        rebase();

        KEEPER.safeTransferFrom( msg.sender, address(this), _amount );

        if ( warmupPeriod == 0 ) {
            return _send( _recipient, _amount, _wrap );
        }
        else {
            Claim memory info = warmupInfo[ _recipient ];
            if ( !info.lock ) {
                require( _recipient == msg.sender, "External deposits for account are locked" );
            }

            uint sKeeperGons = sKEEPER.gonsForBalance( _amount );
            warmupInfo[ _recipient ] = Claim ({
                deposit: info.deposit.add(_amount),
                gons: info.gons.add(sKeeperGons),
                expiry: epoch.number.add32(warmupPeriod),
                lock: info.lock
            });

            gonsInWarmup = gonsInWarmup.add(sKeeperGons);
            return _amount;
        }
    }

    /**
     * @notice retrieve stake from warmup
     * @param _recipient address
     */
    function claim ( address _recipient ) public returns ( uint ) {
        Claim memory info = warmupInfo[ _recipient ];
        if ( epoch.number >= info.expiry && info.expiry != 0 ) {
            delete warmupInfo[ _recipient ];
            gonsInWarmup = gonsInWarmup.sub(info.gons);
            return _send( _recipient, sKEEPER.balanceForGons( info.gons ), false);
        }
        return 0;
    }

    /**
     * @notice forfeit stake and retrieve KEEPER
     */
    function forfeit() external returns ( uint ) {
        Claim memory info = warmupInfo[ msg.sender ];
        delete warmupInfo[ msg.sender ];
        gonsInWarmup = gonsInWarmup.sub(info.gons);
        KEEPER.safeTransfer( msg.sender, info.deposit );
        return info.deposit;
    }

    /**
     * @notice prevent new deposits or claims from ext. address (protection from malicious activity)
     */
    function toggleLock() external {
        warmupInfo[ msg.sender ].lock = !warmupInfo[ msg.sender ].lock;
    }

    /**
     * @notice redeem sKEEPER for KEEPER
     * @param _amount uint
     * @param _trigger bool
     */
    function unstake( uint _amount, bool _trigger ) external returns ( uint ) {
        if ( _trigger ) {
            rebase();
        }
        uint amount = _amount;
        sKEEPER.safeTransferFrom( msg.sender, address(this), _amount );
        KEEPER.safeTransfer( msg.sender, amount );
        return amount;
    }

    /**
        @notice trigger rebase if epoch over
     */
    function rebase() public {
        if( epoch.endTime <= uint32(block.timestamp) ) {
            sKEEPER.rebase( epoch.distribute, epoch.number );
            epoch.endTime = epoch.endTime.add32(epoch.length);
            epoch.number++;            
            if ( distributor != address(0) ) {
                IDistributor( distributor ).distribute();
            }

            uint contractBalanceVal = contractBalance();
            uint totalStakedVal = totalStaked();
            if( contractBalanceVal <= totalStakedVal ) {
                epoch.distribute = 0;
            }
            else {
                epoch.distribute = contractBalanceVal.sub(totalStakedVal);
            }
        }
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
     * @notice send staker their amount as sKEEPER or gKEEPER
     * @param _recipient address
     * @param _amount uint
     */
    function _send( address _recipient, uint _amount, bool _wrap ) internal returns ( uint ) {
        if (_wrap) {
            sKEEPER.approve( address( wTROVE ), _amount );
            uint wrapValue = wTROVE.wrap( _amount );
            wTROVE.transfer( _recipient, wrapValue );
        } else {
            sKEEPER.safeTransfer( _recipient, _amount ); // send as sKEEPER (equal unit as KEEPER)
        }
        return _amount;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
        @notice returns the sKEEPER index, which tracks rebase growth
        @return uint
     */
    function index() public view returns ( uint ) {
        return sKEEPER.index();
    }

    /**
        @notice returns contract KEEPER holdings, including bonuses provided
        @return uint
     */
    function contractBalance() public view returns ( uint ) {
        return KEEPER.balanceOf( address(this) );
    }

    function totalStaked() public view returns ( uint ) {
        return sKEEPER.circulatingSupply();
    }

    function supplyInWarmup() public view returns ( uint ) {
        return sKEEPER.balanceForGons( gonsInWarmup );
    }



    /* ========== MANAGERIAL FUNCTIONS ========== */

    /**
        @notice sets the contract address for LP staking
        @param _address address
     */
    function setDistributor( address _address ) external onlyOwner() {
        distributor = _address;
        emit DistributorSet( _address );
    }
    
    /**
     * @notice set warmup period for new stakers
     * @param _warmupPeriod uint
     */
    function setWarmup( uint32 _warmupPeriod ) external onlyOwner() {
        warmupPeriod = _warmupPeriod;
        emit WarmupSet( _warmupPeriod );
    }
}
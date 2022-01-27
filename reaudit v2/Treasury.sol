// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./interfaces/AggregateV3Interface.sol";
import "./interfaces/ILPCalculator.sol";
import "./interfaces/IERC20Extended.sol";
import "./interfaces/IKeplerERC20.sol";
import "./interfaces/ISPV.sol";
import "./interfaces/IStaking.sol";


contract Treasury is Ownable {
    
    using SafeERC20 for IERC20Extended;
    using SafeMath for uint;

    event Deposit( address indexed token, uint amount, uint value );
    event DepositEth( uint amount, uint value );
    event Sell( address indexed token, uint indexed amount, uint indexed price );
    event SellEth( uint indexed amount, uint indexed price );
    event ReservesWithdrawn( address indexed caller, address indexed token, uint amount );
    event ReservesUpdated( uint indexed totalReserves );
    event ReservesAudited( uint indexed totalReserves );
    event ChangeActivated( MANAGING indexed managing, address activated, bool result );
    event SPVUpdated( address indexed spv );

    enum MANAGING { RESERVETOKEN, LIQUIDITYTOKEN, VARIABLETOKEN, DEPOSITOR }
    struct PriceFeed {
        address feed;
        uint decimals;
    }

    IKeplerERC20 immutable KEEPER;
    uint public constant keeperDecimals = 9;
    uint public immutable priceAdjust;  // 4 decimals. 1000 = 0.1

    address[] public reserveTokens;
    mapping( address => bool ) public isReserveToken;

    address[] public variableTokens;
    mapping( address => bool ) public isVariableToken;

    address[] public liquidityTokens;
    mapping( address => bool ) public isLiquidityToken;

    address[] public depositors;
    mapping( address => bool ) public isDepositor;

    mapping( address => address ) public lpCalculator; // bond calculator for liquidity token
    mapping( address => PriceFeed ) public priceFeeds; // price feeds for variable token

    uint public totalReserves;
    uint public spvDebt;
    uint public daoDebt;
    uint public ownerDebt;
    uint public reserveLastAudited;
    AggregatorV3Interface internal ethPriceFeed;

    address public staking;
    address public vesting;
    address public SPV;
    address public immutable DAO;

    uint public daoRatio;   // 4 decimals. 1000 = 0.1
    uint public spvRatio;   // 4 decimals. 7000 = 0.7
    uint public vestingRatio;   // 4 decimals. 1000 = 0.1
    uint public stakeRatio;    // 4 decimals. 9000 = 0.9
    uint public lcv;    // 4 decimals. 1000 = 0.1
    
    uint public keeperSold;
    uint public initPrice;  // To deposit initial reserves when price is undefined (Keeper supply = 0)


    constructor (address _KEEPER, address _USDC, address _USDT, address _DAI, address _DAO, address _vesting, address _ethPriceFeed, uint _priceAdjust, uint _initPrice) {
        require( _KEEPER != address(0) );
        KEEPER = IKeplerERC20(_KEEPER);
        require( _DAO != address(0) );
        DAO = _DAO;
        require( _vesting != address(0) );
        vesting = _vesting;

        isReserveToken[ _USDC] = true;
        reserveTokens.push( _USDC );
        isReserveToken[ _USDT] = true;
        reserveTokens.push( _USDT );
        isReserveToken[ _DAI ] = true;
        reserveTokens.push( _DAI );

        ethPriceFeed = AggregatorV3Interface( _ethPriceFeed );
        priceAdjust = _priceAdjust;
        initPrice = _initPrice;
    }


    function treasuryInitialized() external onlyOwner() {
        initPrice = 0;
    }


    function setSPV(address _SPV) external onlyOwner() {
        require( _SPV != address(0), "Cannot be 0");
        SPV = _SPV;
        emit SPVUpdated( SPV );
    }


    function setVesting(address _vesting) external onlyOwner() {
        require( _vesting != address(0), "Cannot be 0");
        vesting = _vesting;
    }


    function setStaking(address _staking) external onlyOwner() {
        require( _staking != address(0), "Cannot be 0");
        staking = _staking;
    }


    function setLcv(uint _lcv) external onlyOwner() {
        require( lcv == 0 || _lcv <= lcv.mul(3).div(2), "LCV cannot change sharp" );
        lcv = _lcv;
    }


    function setTreasuryRatio(uint _daoRatio, uint _spvRatio, uint _vestingRatio, uint _stakeRatio) external onlyOwner() {
        require( _daoRatio <= 1000, "DAO more than 10%" );
        require( _spvRatio <= 7000, "SPV more than 70%" );
        require( _vestingRatio <= 2000, "Vesting more than 20%" );
        require( _stakeRatio >= 1000 && _stakeRatio <= 10000, "Stake ratio error" );
        daoRatio = _daoRatio;
        spvRatio = _spvRatio;
        vestingRatio = _vestingRatio;
        stakeRatio = _stakeRatio;
    }


    function getPremium(uint _price) public view returns (uint) {
        return _price.mul( lcv ).mul( keeperSold ).div( KEEPER.totalSupply().sub( KEEPER.balanceOf(vesting) ) ).div( 1e4 );
    }


    function getPrice() public view returns ( uint ) {
        if (initPrice != 0) {
            return initPrice;
        } else {
            return totalReserves.add(ownerDebt).add( ISPV(SPV).totalValue() ).add( priceAdjust ).mul(10 ** keeperDecimals).div( KEEPER.totalSupply().sub( KEEPER.balanceOf(vesting) ) );
        }
    }


    function ethAssetPrice() public view returns (uint) {
        ( , int price, , , ) = ethPriceFeed.latestRoundData();
        return uint(price).mul( 10 ** keeperDecimals ).div( 1e8 );
    }


    function variableAssetPrice(address _address, uint _decimals) public view returns (uint) {
        ( , int price, , , ) = AggregatorV3Interface(_address).latestRoundData();
        return uint(price).mul( 10 ** keeperDecimals ).div( 10 ** _decimals );
    }


    function EthToUSD( uint _amount ) internal view returns ( uint ) {
        return _amount.mul( ethAssetPrice() ).div( 1e18 );
    }


    function auditTotalReserves() public {
        uint reserves;
        for( uint i = 0; i < reserveTokens.length; i++ ) {
            reserves = reserves.add ( 
                valueOfToken( reserveTokens[ i ], IERC20Extended( reserveTokens[ i ] ).balanceOf( address(this) ) )
            );
        }
        for( uint i = 0; i < liquidityTokens.length; i++ ) {
            reserves = reserves.add (
                valueOfToken( liquidityTokens[ i ], IERC20Extended( liquidityTokens[ i ] ).balanceOf( address(this) ) )
            );
        }
        for( uint i = 0; i < variableTokens.length; i++ ) {
            reserves = reserves.add (
                valueOfToken( variableTokens[ i ], IERC20Extended( variableTokens[ i ] ).balanceOf( address(this) ) )
            );
        }
        reserves = reserves.add( EthToUSD(address(this).balance) );
        totalReserves = reserves;
        reserveLastAudited = block.timestamp;
        emit ReservesUpdated( reserves );
        emit ReservesAudited( reserves );
    }

    /**
        @notice allow depositing an asset for KEEPER
        @param _amount uint
        @param _token address
        @return send_ uint
     */
    function deposit( uint _amount, address _token, bool _stake ) external returns ( uint send_ ) {
        require( isReserveToken[ _token ] || isLiquidityToken[ _token ] || isVariableToken[ _token ], "Not accepted" );
        require( isDepositor[ msg.sender ], "Not Approved" );
        IERC20Extended( _token ).safeTransferFrom( msg.sender, address(this), _amount );

        // uint daoAmount = _amount.mul(daoRatio).div(1e4);
        // IERC20Extended( _token ).safeTransfer( DAO, daoAmount );
        
        uint value = valueOfToken(_token, _amount);
        // uint daoValue = value.mul(daoRatio).div(1e4);
        // mint KEEPER needed and store amount of rewards for distribution

        send_ = sendOrStake(msg.sender, value, _stake);

        totalReserves = totalReserves.add( value );
        emit ReservesUpdated( totalReserves );
        emit Deposit( _token, _amount, value );
    }


    function depositEth( uint _amount, bool _stake ) external payable returns ( uint send_ ) {
        require( _amount == msg.value, "Amount should be equal to ETH transferred");
        require( isDepositor[ msg.sender ], "Not Approved" );

        // uint daoAmount = _amount.mul(daoRatio).div(1e4);
        // safeTransferETH(DAO, daoAmount);

        uint value = EthToUSD( _amount );
        // uint daoValue = value.mul(daoRatio).div(1e4);
        // mint KEEPER needed and store amount of rewards for distribution
        send_ = sendOrStake(msg.sender, value, _stake);

        totalReserves = totalReserves.add( value );
        emit ReservesUpdated( totalReserves );
        emit DepositEth( _amount, value );
    }


    function sendOrStake(address _recipient, uint _value, bool _stake) internal returns (uint send_) {
        send_ = _value.mul( 10 ** keeperDecimals ).div( getPrice() );
        if ( _stake ) {
            KEEPER.mint( address(this), send_ );
            KEEPER.approve( staking, send_ );
            IStaking( staking ).stake( send_, _recipient, false );
        } else {
            KEEPER.mint( _recipient, send_ );
        }
        uint vestingAmount = send_.mul(vestingRatio).div(1e4);
        KEEPER.mint( vesting, vestingAmount );
    }

    /**
        @notice allow to burn KEEPER for reserves
        @param _amount uint of keeper
        @param _token address
     */
    function sell( uint _amount, address _token ) external {
        require( isReserveToken[ _token ], "Not accepted" ); // Only reserves can be used for redemptions

        (uint price, uint premium, uint sellPrice) = sellKeeperBurn(msg.sender, _amount);

        uint actualPrice = price.sub( premium.mul(stakeRatio).div(1e4) );
        uint reserveLoss = _amount.mul( actualPrice ).div( 10 ** keeperDecimals );
        uint tokenAmount = reserveLoss.mul( 10 ** IERC20Extended( _token ).decimals() ).div( 10 ** keeperDecimals );
        totalReserves = totalReserves.sub( reserveLoss );
        emit ReservesUpdated( totalReserves );

        uint sellAmount = tokenAmount.mul(sellPrice).div(actualPrice);
        uint daoAmount = tokenAmount.sub(sellAmount);
        IERC20Extended(_token).safeTransfer(msg.sender, sellAmount);
        IERC20Extended(_token).safeTransfer(DAO, daoAmount);

        emit Sell( _token, _amount, sellPrice );
    }


    function sellEth( uint _amount ) external {
        (uint price, uint premium, uint sellPrice) = sellKeeperBurn(msg.sender, _amount);

        uint actualPrice = price.sub( premium.mul(stakeRatio).div(1e4) );
        uint reserveLoss = _amount.mul( actualPrice ).div( 10 ** keeperDecimals );
        uint tokenAmount = reserveLoss.mul(10 ** 18).div( ethAssetPrice() );
        totalReserves = totalReserves.sub( reserveLoss );
        emit ReservesUpdated( totalReserves );

        uint sellAmount = tokenAmount.mul(sellPrice).div(actualPrice);
        uint daoAmount = tokenAmount.sub(sellAmount);
        safeTransferETH(msg.sender, sellAmount);
        safeTransferETH(DAO, daoAmount);

        emit SellEth( _amount, sellPrice );
    }


    function sellKeeperBurn(address _sender, uint _amount) internal returns (uint price, uint premium, uint sellPrice) {
        price = getPrice();
        premium = getPremium(price);
        sellPrice = price.sub(premium);

        KEEPER.burnFrom( _sender, _amount );
        keeperSold = keeperSold.add( _amount );
        uint stakeRewards = _amount.mul(stakeRatio).mul(premium).div(price).div(1e4);
        KEEPER.mint( address(this), stakeRewards );
        KEEPER.approve( staking, stakeRewards );
        IStaking( staking ).addRebaseReward( stakeRewards );
    }


    function unstakeMint(uint _amount) external {
        require( msg.sender == staking, "Not allowed." );
        KEEPER.mint(msg.sender, _amount);
    }


    function initDeposit( address _token, uint _amount ) external payable onlyOwner() {
        require( initPrice != 0, "Already initialized" );
        uint value;
        if ( _token == address(0) && msg.value != 0 ) {
            require( _amount == msg.value, "Amount mismatch" );
            value = EthToUSD( _amount );
        } else {
            IERC20Extended( _token ).safeTransferFrom( msg.sender, address(this), _amount );
            value = valueOfToken(_token, _amount);
        }
        totalReserves = totalReserves.add( value );
        uint send_ = value.mul( 10 ** keeperDecimals ).div( getPrice() );
        KEEPER.mint( msg.sender, send_ );
    } 

    /**
        @notice allow owner multisig to withdraw assets on debt (for safe investments)
        @param _token address
        @param _amount uint
     */
    function incurDebt( address _token, uint _amount, bool isEth ) external onlyOwner() {
        uint value;
        if ( _token == address(0) && isEth ) {
            safeTransferETH(msg.sender, _amount);
            value = EthToUSD( _amount );
        } else {
            IERC20Extended( _token ).safeTransfer( msg.sender, _amount );
            value = valueOfToken(_token, _amount);
        }
        totalReserves = totalReserves.sub( value );
        ownerDebt = ownerDebt.add(value);
        emit ReservesUpdated( totalReserves );
        emit ReservesWithdrawn( msg.sender, _token, _amount );
    }


    function repayDebt( address _token, uint _amount, bool isEth ) external payable onlyOwner() {
        uint value;
        if ( isEth ) {
            require( msg.value == _amount, "Amount mismatch" );
            value = EthToUSD( _amount );
        } else {
            require( isReserveToken[ _token ] || isLiquidityToken[ _token ] || isVariableToken[ _token ], "Not accepted" );
            IERC20Extended( _token ).safeTransferFrom( msg.sender, address(this), _amount );
            value = valueOfToken(_token, _amount);
        }
        totalReserves = totalReserves.add( value );
        if ( value > ownerDebt ) {
            uint daoProfit = _amount.mul( daoRatio ).mul( value.sub(ownerDebt) ).div( value ).div(1e4);
            if ( isEth ) {
                safeTransferETH( DAO, daoProfit );
            } else {
                IERC20Extended( _token ).safeTransfer( DAO, daoProfit );
            }
            value = ownerDebt;
        }
        ownerDebt = ownerDebt.sub(value);
        emit ReservesUpdated( totalReserves );
    }


    function SPVDeposit( address _token, uint _amount ) external {
        require( isReserveToken[ _token ] || isLiquidityToken[ _token ] || isVariableToken[ _token ], "Not accepted" );
        IERC20Extended( _token ).safeTransferFrom( msg.sender, address(this), _amount );
        uint value = valueOfToken(_token, _amount);
        totalReserves = totalReserves.add( value );
        if ( value > spvDebt ) {
            value = spvDebt;
        }
        spvDebt = spvDebt.sub(value);
        emit ReservesUpdated( totalReserves );
    }


    function SPVWithdraw( address _token, uint _amount ) external {
        require( msg.sender == SPV, "Only SPV" );
        address SPVWallet = ISPV( SPV ).SPVWallet();
        uint value = valueOfToken(_token, _amount);
        uint totalValue = totalReserves.add( ISPV(SPV).totalValue() ).add( ownerDebt );
        require( spvDebt.add(value) < totalValue.mul(spvRatio).div(1e4), "Debt exceeded" );
        spvDebt = spvDebt.add(value);
        totalReserves = totalReserves.sub( value );
        emit ReservesUpdated( totalReserves );
        IERC20Extended( _token ).safeTransfer( SPVWallet, _amount );
    }


    function DAOWithdraw( address _token, uint _amount, bool isEth ) external {
        require( msg.sender == DAO, "Only DAO Allowed" );
        uint value;
        if ( _token == address(0) && isEth ) {
            value = EthToUSD( _amount );
        } else {
            value = valueOfToken(_token, _amount);
        }
        uint daoProfit = ISPV( SPV ).totalProfit().mul( daoRatio ).div(1e4);
        require( daoDebt.add(value) <= daoProfit, "Too much" );
        if ( _token == address(0) && isEth ) {
            safeTransferETH(DAO, _amount);
        } else {
            IERC20Extended( _token ).safeTransfer( DAO, _amount );
        }
        totalReserves = totalReserves.sub( value );
        daoDebt = daoDebt.add(value);
        emit ReservesUpdated( totalReserves );
        emit ReservesWithdrawn( DAO, _token, _amount );
    }


    /**
        @notice returns KEEPER valuation of asset
        @param _token address
        @param _amount uint
        @return value_ uint
     */
    function valueOfToken( address _token, uint _amount ) public view returns ( uint value_ ) {
        if ( isReserveToken[ _token ] ) {
            // convert amount to match KEEPER decimals
            value_ = _amount.mul( 10 ** keeperDecimals ).div( 10 ** IERC20Extended( _token ).decimals() );
        } else if ( isLiquidityToken[ _token ] ) {
            value_ = ILPCalculator( lpCalculator[ _token ] ).valuationUSD( _token, _amount );
        } else if ( isVariableToken[ _token ] ) {
            value_ = _amount.mul(variableAssetPrice( priceFeeds[_token].feed, priceFeeds[_token].decimals )).div( 10 ** IERC20Extended( _token ).decimals() );
        }
    }


    /**
        @notice verify queue then set boolean in mapping
        @param _managing MANAGING
        @param _address address
        @param _calculatorFeed address
        @return bool
     */
    function toggle( MANAGING _managing, address _address, address _calculatorFeed, uint decimals ) external onlyOwner() returns ( bool ) {
        require( _address != address(0) );
        bool result;
        if ( _managing == MANAGING.RESERVETOKEN ) { // 0
            if( !listContains( reserveTokens, _address ) ) {
                reserveTokens.push( _address );
            }
            result = !isReserveToken[ _address ];
            isReserveToken[ _address ] = result;
            if ( !result ) {
                listRemove( reserveTokens, _address );
            }

        } else if ( _managing == MANAGING.LIQUIDITYTOKEN ) { // 1
            if( !listContains( liquidityTokens, _address ) ) {
                liquidityTokens.push( _address );
            }
            result = !isLiquidityToken[ _address ];
            isLiquidityToken[ _address ] = result;
            lpCalculator[ _address ] = _calculatorFeed;
            if ( !result ) {
                listRemove( liquidityTokens, _address );
            }

        } else if ( _managing == MANAGING.VARIABLETOKEN ) { // 2
            if( !listContains( variableTokens, _address ) ) {
                variableTokens.push( _address );
            }
            result = !isVariableToken[ _address ];
            isVariableToken[ _address ] = result;
            priceFeeds[ _address ] = PriceFeed({
                feed: _calculatorFeed,
                decimals: decimals
            });
            if ( !result ) {
                listRemove( variableTokens, _address );
            }

        } else if ( _managing == MANAGING.DEPOSITOR ) { // 3
            if( !listContains( depositors, _address ) ) {
                depositors.push( _address );
            }
            result = !isDepositor[ _address ];
            isDepositor[ _address ] = result;
            if ( !result ) {
                listRemove( depositors, _address );
            }
        } 
        else return false;

        auditTotalReserves();
        emit ChangeActivated( _managing, _address, result );
        return true;
    }


    /**
        @notice checks array to ensure against duplicate
        @param _list address[]
        @param _token address
        @return bool
     */
    function listContains( address[] storage _list, address _token ) internal view returns ( bool ) {
        for( uint i = 0; i < _list.length; i++ ) {
            if( _list[ i ] == _token ) {
                return true;
            }
        }
        return false;
    }


    function listRemove( address[] storage _list, address _token ) internal {
        bool removedItem = false;
        for( uint i = 0; i < _list.length; i++ ) {
            if( _list[ i ] == _token ) {
                _list[ i ] = _list[ _list.length-1 ];
                removedItem = true;
                break;
            }
        }
        if ( removedItem ) {
            _list.pop();
        }
    }


    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, 'STE');
    }

}
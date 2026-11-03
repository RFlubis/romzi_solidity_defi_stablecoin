// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./Libraries/OracleLib.sol";
/**
 * @title DSCEngine
 * @author Romzi Fauzi Lubis
 * @notice This contract is the core of the DSC system. It handles all the logic for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDAO DSS (DAI) system.
 *
 * The system is designed to mimic DAI stable coin, to maintain it's value to 1 token == 1$,with no governance, no fees, and was only backed by WETH and  WBTC.
 * the properties:
 *  - Exogenous Collateral
 *  - Dollar Pegged
 *  - Algoritmically Stable
 *
 * The DSC system should always be "overcollateralized". At no point should the value of all collateral <= the $ backed value of all DSC.
 */

contract DSCEngine is ReentrancyGuard {
    ///////////////////
    // Errors        //
    ///////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
    error DSCEngine__TokenNotAllowed(address token);
    error DSCEngine__TokenTransferFailed();
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorIsBroken(uint256 healthFactor);
    error DSCEngine__BurnFailed();
    error DSCEngine__HealthFactorOk(uint256 healthFactor);
    error DSCEngine__HealthFactorNotImproved();

    ///////////////////
    //  Types        //
    ///////////////////
    using OracleLib for AggregatorV3Interface;
    /////////////////////
    // State Variables //
    /////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% overcollateralized
    uint256 private constant LIQUIDATOR_BONUS = 10; //10% bonus for liquidators
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    /////////////////////
    // Events          //
    /////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemFrom,address indexed redeemTo, address indexed token, uint256 amount);

    ///////////////////
    // Modifiers     //
    ///////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed(token);
        }
        _;
    }

    ///////////////////
    // Functions     //
    ///////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////
    // External Functions //
    ////////////////////////
    /*
     * @notice This function allows users to deposit collateral and mint DSC in a single transaction.
     * @param tokenCollateralAddress The address of the collateral token to deposit.
     * @param amountCollateral The amount of collateral to deposit.
     * @param amountDscToMint The amount of DSC to mint.
     */
    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TokenTransferFailed();
        }
    }


    /**
     * @notice This function allows users to redeem collateral and burn DSC in a single transaction.
     * @param tokenCollateralAddress The address of the collateral token to redeem.
     * @param amountCollateral The amount of collateral to redeem.
     * @param amountDscToBurn The amount of DSC to burn.
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHelthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follow CEI.
     * @param amountDscToMint The amount of Desentralized Stable Coin to mint.
     * @notice must have more collateral value than the amount of DSC to mint.
     */

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHelthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amountDscToBurn) public moreThanZero(amountDscToBurn) nonReentrant {
        _burnDsc(msg.sender, msg.sender, amountDscToBurn);
       _revertIfHelthFactorIsBroken(msg.sender);
    }
    
    /*
     * @notice This function allows users to liquidate undercollateralized positions.
     * @param collateral The address of the collateral token to liquidate.
     * @param user The address of the user to liquidate because their health factor is broken to <1.
     * @param deptToCover The amount of DSC to burn in order to cover the user's debt.
     * @notice The liquidator will receive a bonus for taking on the risk of liquidating the user's position.
     * @notice partial liquidation is possible, meaning the liquidator can choose to cover a portion of the user's debt.
     * @notice a know bug would be if the protocol were 100% or less overcollateralized, then the liquidator would not be able to be properly incentivize, meaning they would not receive the full liquidation bonus.
     * @notice The user's health factor must be below 1 in order to be liquidated.
     * @notice this function working assumes the protocol will be roughly 200% overcollateralized, meaning for every 1$ of DSC minted, there is 2$ of collateral backing it.
     * @notice The liquidator must have enough DSC to cover the amount of DSC they are using to liquidate the user's position.
     */
    function liquidate(address collateral, address user, uint256 deptToCover) external moreThanZero(deptToCover) nonReentrant {

        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk(startingUserHealthFactor);
        }

        //we want to burn user DSC "debt"
        //and take their collateral
        //Bad user: $140 ETH, $100 DSC minted,it should be $200 collateral to mint $100 DSC.
        //debtToCover = $100
        //$100 DSC = ??? ETH
        //0.05 ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, deptToCover);
        //the liquidator will get $110 worth of ETH for covering $100 of DSC, to incentivize liquidation
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATOR_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, msg.sender, user);
        _burnDsc(msg.sender, user, deptToCover);
       
       uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHelthFactorIsBroken(msg.sender);
        //check health factor for user and liquidator
    }

    function getHealthFactor() external view returns (uint256) {}

    ///////////////////////////////////////
    // Private & Internal view Functions //
    ///////////////////////////////////////
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalCollateralValueInUsd, uint256 dscMinted)
    {
        totalCollateralValueInUsd = getAccountCollateralValue(user);
        dscMinted = s_DSCMinted[user];
    }

    /*
     * @notice This function allows users to redeem collateral and burn DSC in a single transaction.
     * @param tokenCollateralAddress The address of the collateral token to redeem.
     * @param amountCollateral The amount of collateral to redeem.
     * @param amountDscToBurn The amount of DSC to burn.
     * @dev internal function, must have health factor checked before calling this function, to make sure the user is not undercollateralized.
     */
    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address to, address from) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TokenTransferFailed();
        }
    }

    function _burnDsc(address dscFrom,address onBehalfOf,uint256 amountDscToBurn) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TokenTransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    /*
     * @notice Returns the health factor of a user,how close to liquidation a user is, if it's below 1, the user is undercollateralized.
     * @param user The address of the user to check the health factor of.
     * @return The health factor of the user.
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalCollateralValueInUsd, uint256 dscMinted) = _getAccountInformation(user);
        return _calculateHealthFactor(dscMinted,totalCollateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 dscMinted, uint256 totalCollateralValueInUsd) internal pure returns(uint256){

        if(dscMinted == 0) return type(uint256).max;
         uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / dscMinted;
    }

    function _revertIfHelthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBroken(healthFactor);
        }
    }

    //////////////////////////////////////
    // Public & External View Functions //
    //////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        //calculation example: 1 ETH = 2000 USD,(10e18 * 1e18) / (2000e8 * 1e10) = 0.5 ETH
        // forge-lint: disable-next-line(unsafe-typecast)
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            uint256 price = getUsdValue(token, amount);
            totalCollateralValueInUsd += price;
        }
        return totalCollateralValueInUsd;
    }

    function getAccountTokenCollateralInfo(address user, address token) external view returns (uint256 amountDeposited, uint256 tokenUsdValue) {
        amountDeposited = s_collateralDeposited[user][token];
        tokenUsdValue = getUsdValue(token, amountDeposited);
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // forge-lint: disable-next-line(unsafe-typecast)
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(address user) external view returns (uint256 totalCollateralValueInUsd, uint256 dscMinted) {
        (totalCollateralValueInUsd, dscMinted) = _getAccountInformation(user);
    }

    function calculateHealthFactor(uint256 dscMinted, uint256 totalCollateralValueInUsd) external pure returns(uint256){
        return _calculateHealthFactor(dscMinted,totalCollateralValueInUsd);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATOR_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}

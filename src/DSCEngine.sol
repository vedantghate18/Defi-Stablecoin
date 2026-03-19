// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;
import {DecentralizedStablecoin} from "../src/DecentralizedStablecoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/V0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Vedant Ghate
 * This system is designed to be as minimal as possible, and may have the tokens maintain a 1token == $1
 * this stablecoin has the properties:
 * -- Exogenous Collateral
 * -- Dollar Pegged
 * -- Algorithmic
 */

contract DSCEngine is ReentrancyGuard {
    ////////////////
    // Errors //
    ///////////////
    error DSCEngine__AmountZero();
    error DSCEngine__MismatchedTokenToPriceFeedArray();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__CollateralAmountIsLow();
    error DSCEngine__HealthFactorIsBelowOne(uint256);
    error DSCEngine__DSCMintingFailed();
    error DSCEngine__HealthFactorIOk();
    error DSCEngine__HealthFactorNotImproved();

    /////////////////////
    // State Variables //
    ////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISON = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStablecoin private immutable i_dsc;

    ////////////
    // Events //
    ////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ////////////////
    // Modifiers //
    ///////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__AmountZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ////////////////
    // Functions //
    ///////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        //USD PRICE FEEDS
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__MismatchedTokenToPriceFeedArray();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStablecoin(dscAddress);
    }

    ////////////////////////
    // External Functions //
    ///////////////////////

    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountToCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountToCollateral);
        mintDSC(amountDscToMint);
    }

    /**
     * @notice follows CEI pattern
     * @param tokenCollateralAddress the address of the token to be deposited as Collateral
     * @param amountToCollateral The amount of collateral deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountToCollateral)
        public
        moreThanZero(amountToCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountToCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountToCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountToCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountToCollateral, uint256 amountDscToBurn)
        public
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountToCollateral);
        //redeem collateral already checks healthfactor
    }

    // in order to redeem collateral :
    // 1. Health Factor must be over 1 After Collateral Pulled
    function redeemCollateral(address tokenCollateralAddress, uint256 amountToCollateral)
        public
        moreThanZero(amountToCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountToCollateral, msg.sender, msg.sender);
    }

    /**
     * @param amountDscToMint amount of DSC to be minted according to collateral
     * @notice They must have more collateral value than minimum threshold
     */
    function mintDSC(uint256 amountDscToMint) public moreThanZero(amountDscToMint) {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__DSCMintingFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // Don't think This is needed
    }

    // if we do start nearing the undercollateralization, we need someone  to liquidate positions

    //Liquidator take the backing and burns the DSC

    //If someone is almost undercollateralized, then we will pay you to liquidate their postions!
    /**
     * @param collateral: the erc20 address collateral to liquidate
     * @param user: The user who has broken the healtfactor. Their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param  debtToCover: The Amount of DSC you want to burn to improve the healt factor
     * @notice you can partially liquidate the user
     * @notice you will get the liquidation bonus for the user funds
     * @notice This function working assumes the protocol working will be roughly 200% overcollateralized in order to work
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldnt be incentive the liquidators.
     *
     * Follows : CEI  {CHECK, , EFFECTS, INTERACT}
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        //Check HealthFactor of the user to check if the user is liquidable
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIOk();
        }
        // we want to burn their DSC "debt"
        //And take their Collateral
        uint256 tokenAmountFromDebtCovered = getTokenFromUsd(collateral, debtToCover);
        // And Give them 10% incentive because they have liquidated the state by paying off the debt
        // We should implement a feature to liquidate in the event the protocol is insolvent
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        // Burning the DSC
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //////////////////////////////////
    // Private & Internal View Functions //
    /////////////////////////////////
    function _redeemCollateral(address tokenCollateralAddress, uint256 amountToCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountToCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountToCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountToCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    //low level internal function
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _getAccountInformation(address user)
        internal
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBelowOne(userHealthFactor);
        }
    }

    ////////////////////////////////////
    // Public & External View Functions//
    ///////////////////////////////////
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdvalue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdvalue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISON) * amount) / PRECISION;
    }

    // the value of Amount is of 8 places so additional precision is given
    function getTokenFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISON);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCoollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
}


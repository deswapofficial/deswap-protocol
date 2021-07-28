pragma solidity ^0.5.16;

import "./DToken.sol";
import "./ErrorReporter.sol";
import "./Exponential.sol";
import "./PriceOracle.sol";
import "./ComptrollerInterface.sol";
import "./ComptrollerStorage.sol";
import "./Unitroller.sol";
import "./Governance/DAW.sol";
import "./YAI/YAI.sol";

/**
 * @title Deswap's Comptroller Contract
 * @author Deswap
 */
contract ComptrollerG1 is ComptrollerV1Storage, ComptrollerInterfaceG1, ComptrollerErrorReporter, Exponential {
    /// @notice Emitted when an admin supports a market
    event MarketListed(DToken dToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(DToken dToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(DToken dToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(DToken dToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);

    /// @notice Emitted when maxAssets is changed by admin
    event NewMaxAssets(uint oldMaxAssets, uint newMaxAssets);

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(DToken dToken, string action, bool pauseState);

    /// @notice Emitted when market deswap status is changed
    event MarketDeswap(DToken dToken, bool isDeswap);

    /// @notice Emitted when Deswap rate is changed
    event NewDeswapRate(uint oldDeswapRate, uint newDeswapRate);

    /// @notice Emitted when Deswap YAI rate is changed
    event NewDeswapYAIRate(uint oldDeswapYAIRate, uint newDeswapYAIRate);

    /// @notice Emitted when a new Deswap speed is calculated for a market
    event DeswapSpeedUpdated(DToken indexed dToken, uint newSpeed);

    /// @notice Emitted when DAW is distributed to a supplier
    event DistributedSupplierDeswap(DToken indexed dToken, address indexed supplier, uint deswapDelta, uint deswapSupplyIndex);

    /// @notice Emitted when DAW is distributed to a borrower
    event DistributedBorrowerDeswap(DToken indexed dToken, address indexed borrower, uint deswapDelta, uint deswapBorrowIndex);

    /// @notice Emitted when DAW is distributed to a YAI minter
    event DistributedYAIMinterDeswap(address indexed yaiMinter, uint deswapDelta, uint deswapYAIMintIndex);

    /// @notice Emitted when YAIController is changed
    event NewYAIController(YAIControllerInterface oldYAIController, YAIControllerInterface newYAIController);

    /// @notice Emitted when YAI mint rate is changed by admin
    event NewYAIMintRate(uint oldYAIMintRate, uint newYAIMintRate);

    /// @notice Emitted when protocol state is changed by admin
    event ActionProtocolPaused(bool state);

    /// @notice The threshold above which the flywheel transfers DAW, in wei
    uint public constant deswapClaimThreshold = 0.001e18;

    /// @notice The initial Deswap index for a market
    uint224 public constant deswapInitialIndex = 1e36;

    // closeFactorMantissa must be strictly greater than this value
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    // liquidationIncentiveMantissa must be no less than this value
    uint internal constant liquidationIncentiveMinMantissa = 1.0e18; // 1.0

    // liquidationIncentiveMantissa must be no greater than this value
    uint internal constant liquidationIncentiveMaxMantissa = 1.5e18; // 1.5

    constructor() public {
        admin = msg.sender;
    }

    modifier onlyProtocolAllowed {
        require(!protocolPaused, "protocol is paused");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }

    modifier onlyListedMarket(DToken dToken) {
        require(markets[address(dToken)].isListed, "deswap market is not listed");
        _;
    }

    modifier validPauseState(bool state) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can");
        require(msg.sender == admin || state == true, "only admin can unpause");
        _;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (DToken[] memory) {
        return accountAssets[account];
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param dToken The dToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, DToken dToken) external view returns (bool) {
        return markets[address(dToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param dTokens The list of addresses of the dToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] calldata dTokens) external returns (uint[] memory) {
        uint len = dTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            results[i] = uint(addToMarketInternal(DToken(dTokens[i]), msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param dToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(DToken dToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(dToken)];

        if (!marketToJoin.isListed) {
            // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.accountMembership[borrower]) {
            // already joined
            return Error.NO_ERROR;
        }

        if (accountAssets[borrower].length >= maxAssets)  {
            // no space, cannot join
            return Error.TOO_MANY_ASSETS;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(dToken);

        emit MarketEntered(dToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param dTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address dTokenAddress) external returns (uint) {
        DToken dToken = DToken(dTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the dToken */
        (uint oErr, uint tokensHeld, uint amountOwed, ) = dToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint allowed = redeemAllowedInternal(dTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(dToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        /* Set dToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete dToken from the account’s list of assets */
        // In order to delete dToken, copy last item in list to location of item to be removed, reduce length by 1
        DToken[] storage userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint i;
        for (; i < len; i++) {
            if (userAssetList[i] == dToken) {
                userAssetList[i] = userAssetList[len - 1];
                userAssetList.length--;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(i < len);

        emit MarketExited(dToken, msg.sender);

        return uint(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param dToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(address dToken, address minter, uint mintAmount) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[dToken], "mint is paused");

        // Shh - currently unused
        mintAmount;

        if (!markets[dToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        updateDeswapSupplyIndex(dToken);
        distributeSupplierDeswap(dToken, minter, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param dToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(address dToken, address minter, uint actualMintAmount, uint mintTokens) external {
        // Shh - currently unused
        dToken;
        minter;
        actualMintAmount;
        mintTokens;
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param dToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of dTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(address dToken, address redeemer, uint redeemTokens) external onlyProtocolAllowed returns (uint) {
        uint allowed = redeemAllowedInternal(dToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateDeswapSupplyIndex(dToken);
        distributeSupplierDeswap(dToken, redeemer, false);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(address dToken, address redeemer, uint redeemTokens) internal view returns (uint) {
        if (!markets[dToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[dToken].accountMembership[redeemer]) {
            return uint(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, DToken(dToken), redeemTokens, 0);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall != 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param dToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(address dToken, address redeemer, uint redeemAmount, uint redeemTokens) external {
        // Shh - currently unused
        dToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        require(redeemTokens != 0 || redeemAmount == 0, "redeemTokens zero");
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param dToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(address dToken, address borrower, uint borrowAmount) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[dToken], "borrow is paused");

        if (!markets[dToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!markets[dToken].accountMembership[borrower]) {
            // only dTokens may call borrowAllowed if borrower not in market
            require(msg.sender == dToken, "sender must be dToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(DToken(dToken), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }
        }

        if (oracle.getUnderlyingPrice(DToken(dToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }

        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, DToken(dToken), 0, borrowAmount);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall != 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: DToken(dToken).borrowIndex()});
        updateDeswapBorrowIndex(dToken, borrowIndex);
        distributeBorrowerDeswap(dToken, borrower, borrowIndex, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param dToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(address dToken, address borrower, uint borrowAmount) external {
        // Shh - currently unused
        dToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param dToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would repay the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address dToken,
        address payer,
        address borrower,
        uint repayAmount) external onlyProtocolAllowed returns (uint) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[dToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: DToken(dToken).borrowIndex()});
        updateDeswapBorrowIndex(dToken, borrowIndex);
        distributeBorrowerDeswap(dToken, borrower, borrowIndex, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param dToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address dToken,
        address payer,
        address borrower,
        uint actualRepayAmount,
        uint borrowerIndex) external {
        // Shh - currently unused
        dToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param dTokenBorrowed Asset which was borrowed by the borrower
     * @param dTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address dTokenBorrowed,
        address dTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) external onlyProtocolAllowed returns (uint) {
        // Shh - currently unused
        liquidator;

        if (!markets[dTokenBorrowed].isListed || !markets[dTokenCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* The borrower must have shortfall in order to be liquidatable */
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, DToken(0), 0, 0);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall == 0) {
            return uint(Error.INSUFFICIENT_SHORTFALL);
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        uint borrowBalance = DToken(dTokenBorrowed).borrowBalanceStored(borrower);
        (MathError mathErr, uint maxClose) = mulScalarTruncate(Exp({mantissa: closeFactorMantissa}), borrowBalance);
        if (mathErr != MathError.NO_ERROR) {
            return uint(Error.MATH_ERROR);
        }
        if (repayAmount > maxClose) {
            return uint(Error.TOO_MUCH_REPAY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param dTokenBorrowed Asset which was borrowed by the borrower
     * @param dTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify(
        address dTokenBorrowed,
        address dTokenCollateral,
        address liquidator,
        address borrower,
        uint actualRepayAmount,
        uint seizeTokens) external {
        // Shh - currently unused
        dTokenBorrowed;
        dTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param dTokenCollateral Asset which was used as collateral and will be seized
     * @param dTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address dTokenCollateral,
        address dTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize is paused");

        // Shh - currently unused
        seizeTokens;

        if (!markets[dTokenCollateral].isListed || !markets[dTokenBorrowed].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (DToken(dTokenCollateral).comptroller() != DToken(dTokenBorrowed).comptroller()) {
            return uint(Error.COMPTROLLER_MISMATCH);
        }

        // Keep the flywheel moving
        updateDeswapSupplyIndex(dTokenCollateral);
        distributeSupplierDeswap(dTokenCollateral, borrower, false);
        distributeSupplierDeswap(dTokenCollateral, liquidator, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param dTokenCollateral Asset which was used as collateral and will be seized
     * @param dTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address dTokenCollateral,
        address dTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external {
        // Shh - currently unused
        dTokenCollateral;
        dTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param dToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of dTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(address dToken, address src, address dst, uint transferTokens) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(dToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateDeswapSupplyIndex(dToken);
        distributeSupplierDeswap(dToken, src, false);
        distributeSupplierDeswap(dToken, dst, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param dToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of dTokens to transfer
     */
    function transferVerify(address dToken, address src, address dst, uint transferTokens) external {
        // Shh - currently unused
        dToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `dTokenBalance` is the number of dTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint dTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, DToken(0), 0, 0);

        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param dTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address dTokenModify,
        uint redeemTokens,
        uint borrowAmount) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, DToken(dTokenModify), redeemTokens, borrowAmount);
        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param dTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral dToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        DToken dTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (Error, uint, uint) {

        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;
        MathError mErr;

        // For each asset the account is in
        DToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            DToken asset = assets[i];

            // Read the balances and exchange rate from the dToken
            (oErr, vars.dTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> bnb (normalized price value)
            (mErr, vars.tokensToDenom) = mulExp3(vars.collateralFactor, vars.exchangeRate, vars.oraclePrice);
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // sumCollateral += tokensToDenom * dTokenBalance
            (mErr, vars.sumCollateral) = mulScalarTruncateAddUInt(vars.tokensToDenom, vars.dTokenBalance, vars.sumCollateral);
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // Calculate effects of interacting with dTokenModify
            if (asset == dTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);
                if (mErr != MathError.NO_ERROR) {
                    return (Error.MATH_ERROR, 0, 0);
                }

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
                if (mErr != MathError.NO_ERROR) {
                    return (Error.MATH_ERROR, 0, 0);
                }
            }
        }

        /// @dev YAI Integration^
        (mErr, vars.sumBorrowPlusEffects) = addUInt(vars.sumBorrowPlusEffects, mintedYAIs[account]);
        if (mErr != MathError.NO_ERROR) {
            return (Error.MATH_ERROR, 0, 0);
        }
        /// @dev YAI Integration$

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in dToken.liquidateBorrowFresh)
     * @param dTokenBorrowed The address of the borrowed dToken
     * @param dTokenCollateral The address of the collateral dToken
     * @param actualRepayAmount The amount of dTokenBorrowed underlying to convert into dTokenCollateral tokens
     * @return (errorCode, number of dTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(address dTokenBorrowed, address dTokenCollateral, uint actualRepayAmount) external view returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(DToken(dTokenBorrowed));
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(DToken(dTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = DToken(dTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;
        MathError mathErr;

        (mathErr, numerator) = mulExp(liquidationIncentiveMantissa, priceBorrowedMantissa);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, denominator) = mulExp(priceCollateralMantissa, exchangeRateMantissa);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, ratio) = divExp(numerator, denominator);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, seizeTokens) = mulScalarTruncate(ratio, actualRepayAmount);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /*** Admin Functions ***/

    /**
      * @notice Sets a new price oracle for the comptroller
      * @dev Admin function to set a new price oracle
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        // Track the old oracle for the comptroller
        PriceOracle oldOracle = oracle;

        // Set comptroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the closeFactor used when liquidating borrows
      * @dev Admin function to set closeFactor
      * @param newCloseFactorMantissa New close factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setCloseFactor(uint newCloseFactorMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_CLOSE_FACTOR_OWNER_CHECK);
        }

        Exp memory newCloseFactorExp = Exp({mantissa: newCloseFactorMantissa});
        Exp memory lowLimit = Exp({mantissa: closeFactorMinMantissa});
        if (lessThanOrEqualExp(newCloseFactorExp, lowLimit)) {
            return fail(Error.INVALID_CLOSE_FACTOR, FailureInfo.SET_CLOSE_FACTOR_VALIDATION);
        }

        Exp memory highLimit = Exp({mantissa: closeFactorMaxMantissa});
        if (lessThanExp(highLimit, newCloseFactorExp)) {
            return fail(Error.INVALID_CLOSE_FACTOR, FailureInfo.SET_CLOSE_FACTOR_VALIDATION);
        }

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, newCloseFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the collateralFactor for a market
      * @dev Admin function to set per-market collateralFactor
      * @param dToken The market to set the factor on
      * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setCollateralFactor(DToken dToken, uint newCollateralFactorMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        // Verify market is listed
        Market storage market = markets[address(dToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(dToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(dToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets maxAssets which controls how many markets can be entered
      * @dev Admin function to set maxAssets
      * @param newMaxAssets New max assets
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setMaxAssets(uint newMaxAssets) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_MAX_ASSETS_OWNER_CHECK);
        }

        uint oldMaxAssets = maxAssets;
        maxAssets = newMaxAssets;
        emit NewMaxAssets(oldMaxAssets, newMaxAssets);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets liquidationIncentive
      * @dev Admin function to set liquidationIncentive
      * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK);
        }

        // Check de-scaled min <= newLiquidationIncentive <= max
        Exp memory newLiquidationIncentive = Exp({mantissa: newLiquidationIncentiveMantissa});
        Exp memory minLiquidationIncentive = Exp({mantissa: liquidationIncentiveMinMantissa});
        if (lessThanExp(newLiquidationIncentive, minLiquidationIncentive)) {
            return fail(Error.INVALID_LIQUIDATION_INCENTIVE, FailureInfo.SET_LIQUIDATION_INCENTIVE_VALIDATION);
        }

        Exp memory maxLiquidationIncentive = Exp({mantissa: liquidationIncentiveMaxMantissa});
        if (lessThanExp(maxLiquidationIncentive, newLiquidationIncentive)) {
            return fail(Error.INVALID_LIQUIDATION_INCENTIVE, FailureInfo.SET_LIQUIDATION_INCENTIVE_VALIDATION);
        }

        // Save current value for use in log
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Add the market to the markets mapping and set it as listed
      * @dev Admin function to set isListed and add support for the market
      * @param dToken The address of the market (token) to list
      * @return uint 0=success, otherwise a failure. (See enum Error for details)
      */
    function _supportMarket(DToken dToken) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SUPPORT_MARKET_OWNER_CHECK);
        }

        if (markets[address(dToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        dToken.isDToken(); // Sanity check to make sure its really a DToken

        markets[address(dToken)] = Market({isListed: true, isDeswap: false, collateralFactorMantissa: 0});

        _addMarketInternal(dToken);

        emit MarketListed(dToken);

        return uint(Error.NO_ERROR);
    }

    function _addMarketInternal(DToken dToken) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != dToken, "market already added");
        }
        allMarkets.push(dToken);
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, newPauseGuardian);

        return uint(Error.NO_ERROR);
    }

    function _setMintPaused(DToken dToken, bool state) public onlyListedMarket(dToken) validPauseState(state) returns (bool) {
        mintGuardianPaused[address(dToken)] = state;
        emit ActionPaused(dToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(DToken dToken, bool state) public onlyListedMarket(dToken) validPauseState(state) returns (bool) {
        borrowGuardianPaused[address(dToken)] = state;
        emit ActionPaused(dToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) public validPauseState(state) returns (bool) {
        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public validPauseState(state) returns (bool) {
        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _setMintYAIPaused(bool state) public validPauseState(state) returns (bool) {
        mintYAIGuardianPaused = state;
        emit ActionPaused("MintYAI", state);
        return state;
    }

    function _setRepayYAIPaused(bool state) public validPauseState(state) returns (bool) {
        repayYAIGuardianPaused = state;
        emit ActionPaused("RepayYAI", state);
        return state;
    }
    /**
     * @notice Set whole protocol pause/unpause state
     */
    function _setProtocolPaused(bool state) public onlyAdmin returns(bool) {
        protocolPaused = state;
        emit ActionProtocolPaused(state);
        return state;
    }

    /**
      * @notice Sets a new YAI controller
      * @dev Admin function to set a new YAI controller
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setYAIController(YAIControllerInterface yaiController_) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_YAICONTROLLER_OWNER_CHECK);
        }

        YAIControllerInterface oldRate = yaiController;
        yaiController = yaiController_;
        emit NewYAIController(oldRate, yaiController_);
    }

    function _setYAIMintRate(uint newYAIMintRate) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_YAI_MINT_RATE_CHECK);
        }

        uint oldYAIMintRate = yaiMintRate;
        yaiMintRate = newYAIMintRate;
        emit NewYAIMintRate(oldYAIMintRate, newYAIMintRate);

        return uint(Error.NO_ERROR);
    }

    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin can");
        require(unitroller._acceptImplementation() == 0, "not authorized");
    }

    /*** Deswap Distribution ***/

    /**
     * @notice Recalculate and update Deswap speeds for all Deswap markets
     */
    function refreshDeswapSpeeds() public {
        require(msg.sender == tx.origin, "only externally owned accounts can");
        refreshDeswapSpeedsInternal();
    }

    function refreshDeswapSpeedsInternal() internal {
        uint i;
        DToken dToken;

        for (i = 0; i < allMarkets.length; i++) {
            dToken = allMarkets[i];
            Exp memory borrowIndex = Exp({mantissa: dToken.borrowIndex()});
            updateDeswapSupplyIndex(address(dToken));
            updateDeswapBorrowIndex(address(dToken), borrowIndex);
        }

        Exp memory totalUtility = Exp({mantissa: 0});
        Exp[] memory utilities = new Exp[](allMarkets.length);
        for (i = 0; i < allMarkets.length; i++) {
            dToken = allMarkets[i];
            if (markets[address(dToken)].isDeswap) {
                Exp memory assetPrice = Exp({mantissa: oracle.getUnderlyingPrice(dToken)});
                Exp memory utility = mul_(assetPrice, dToken.totalBorrows());
                utilities[i] = utility;
                totalUtility = add_(totalUtility, utility);
            }
        }

        for (i = 0; i < allMarkets.length; i++) {
            dToken = allMarkets[i];
            uint newSpeed = totalUtility.mantissa > 0 ? mul_(deswapRate, div_(utilities[i], totalUtility)) : 0;
            deswapSpeeds[address(dToken)] = newSpeed;
            emit DeswapSpeedUpdated(dToken, newSpeed);
        }
    }

    /**
     * @notice Accrue DAW to the market by updating the supply index
     * @param dToken The market whose supply index to update
     */
    function updateDeswapSupplyIndex(address dToken) internal {
        DeswapMarketState storage supplyState = deswapSupplyState[dToken];
        uint supplySpeed = deswapSpeeds[dToken];
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, uint(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint supplyTokens = DToken(dToken).totalSupply();
            uint deswapAccrued = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(deswapAccrued, supplyTokens) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: supplyState.index}), ratio);
            deswapSupplyState[dToken] = DeswapMarketState({
                index: safe224(index.mantissa, "new index overflows"),
                block: safe32(blockNumber, "block number overflows")
            });
        } else if (deltaBlocks > 0) {
            supplyState.block = safe32(blockNumber, "block number overflows");
        }
    }

    /**
     * @notice Accrue DAW to the market by updating the borrow index
     * @param dToken The market whose borrow index to update
     */
    function updateDeswapBorrowIndex(address dToken, Exp memory marketBorrowIndex) internal {
        DeswapMarketState storage borrowState = deswapBorrowState[dToken];
        uint borrowSpeed = deswapSpeeds[dToken];
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, uint(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(DToken(dToken).totalBorrows(), marketBorrowIndex);
            uint deswapAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(deswapAccrued, borrowAmount) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: borrowState.index}), ratio);
            deswapBorrowState[dToken] = DeswapMarketState({
                index: safe224(index.mantissa, "new index overflows"),
                block: safe32(blockNumber, "block number overflows")
            });
        } else if (deltaBlocks > 0) {
            borrowState.block = safe32(blockNumber, "block number overflows");
        }
    }

    /**
     * @notice Accrue DAW to by updating the YAI minter index
     */
    function updateDeswapYAIMintIndex() internal {
        if (address(yaiController) != address(0)) {
            yaiController.updateDeswapYAIMintIndex();
        }
    }

    /**
     * @notice Calculate DAW accrued by a supplier and possibly transfer it to them
     * @param dToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute DAW to
     */
    function distributeSupplierDeswap(address dToken, address supplier, bool distributeAll) internal {
        DeswapMarketState storage supplyState = deswapSupplyState[dToken];
        Double memory supplyIndex = Double({mantissa: supplyState.index});
        Double memory supplierIndex = Double({mantissa: deswapSupplierIndex[dToken][supplier]});
        deswapSupplierIndex[dToken][supplier] = supplyIndex.mantissa;

        if (supplierIndex.mantissa == 0 && supplyIndex.mantissa > 0) {
            supplierIndex.mantissa = deswapInitialIndex;
        }

        Double memory deltaIndex = sub_(supplyIndex, supplierIndex);
        uint supplierTokens = DToken(dToken).balanceOf(supplier);
        uint supplierDelta = mul_(supplierTokens, deltaIndex);
        uint supplierAccrued = add_(deswapAccrued[supplier], supplierDelta);
        deswapAccrued[supplier] = transferDAW(supplier, supplierAccrued, distributeAll ? 0 : deswapClaimThreshold);
        emit DistributedSupplierDeswap(DToken(dToken), supplier, supplierDelta, supplyIndex.mantissa);
    }

    /**
     * @notice Calculate DAW accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param dToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute DAW to
     */
    function distributeBorrowerDeswap(address dToken, address borrower, Exp memory marketBorrowIndex, bool distributeAll) internal {
        DeswapMarketState storage borrowState = deswapBorrowState[dToken];
        Double memory borrowIndex = Double({mantissa: borrowState.index});
        Double memory borrowerIndex = Double({mantissa: deswapBorrowerIndex[dToken][borrower]});
        deswapBorrowerIndex[dToken][borrower] = borrowIndex.mantissa;

        if (borrowerIndex.mantissa > 0) {
            Double memory deltaIndex = sub_(borrowIndex, borrowerIndex);
            uint borrowerAmount = div_(DToken(dToken).borrowBalanceStored(borrower), marketBorrowIndex);
            uint borrowerDelta = mul_(borrowerAmount, deltaIndex);
            uint borrowerAccrued = add_(deswapAccrued[borrower], borrowerDelta);
            deswapAccrued[borrower] = transferDAW(borrower, borrowerAccrued, distributeAll ? 0 : deswapClaimThreshold);
            emit DistributedBorrowerDeswap(DToken(dToken), borrower, borrowerDelta, borrowIndex.mantissa);
        }
    }

    /**
     * @notice Calculate DAW accrued by a YAI minter and possibly transfer it to them
     * @dev YAI minters will not begin to accrue until after the first interaction with the protocol.
     * @param yaiMinter The address of the YAI minter to distribute DAW to
     */
    function distributeYAIMinterDeswap(address yaiMinter, bool distributeAll) internal {
        if (address(yaiController) != address(0)) {
            uint yaiMinterAccrued;
            uint yaiMinterDelta;
            uint yaiMintIndexMantissa;
            uint err;
            (err, yaiMinterAccrued, yaiMinterDelta, yaiMintIndexMantissa) = yaiController.calcDistributeYAIMinterDeswap(yaiMinter);
            if (err == uint(Error.NO_ERROR)) {
                deswapAccrued[yaiMinter] = transferDAW(yaiMinter, yaiMinterAccrued, distributeAll ? 0 : deswapClaimThreshold);
                emit DistributedYAIMinterDeswap(yaiMinter, yaiMinterDelta, yaiMintIndexMantissa);
            }
        }
    }

    /**
     * @notice Transfer DAW to the user, if they are above the threshold
     * @dev Note: If there is not enough DAW, we do not perform the transfer all.
     * @param user The address of the user to transfer DAW to
     * @param userAccrued The amount of DAW to (possibly) transfer
     * @return The amount of DAW which was NOT transferred to the user
     */
    function transferDAW(address user, uint userAccrued, uint threshold) internal returns (uint) {
        if (userAccrued >= threshold && userAccrued > 0) {
            DAW daw = DAW(getDAWAddress());
            uint dawRemaining = daw.balanceOf(address(this));
            if (userAccrued <= dawRemaining) {
                daw.transfer(user, userAccrued);
                return 0;
            }
        }
        return userAccrued;
    }

    /**
     * @notice Claim all the daw accrued by holder in all markets and YAI
     * @param holder The address to claim DAW for
     */
    function claimDeswap(address holder) public {
        return claimDeswap(holder, allMarkets);
    }

    /**
     * @notice Claim all the daw accrued by holder in the specified markets
     * @param holder The address to claim DAW for
     * @param dTokens The list of markets to claim DAW in
     */
    function claimDeswap(address holder, DToken[] memory dTokens) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimDeswap(holders, dTokens, true, true);
    }

    /**
     * @notice Claim all daw accrued by the holders
     * @param holders The addresses to claim DAW for
     * @param dTokens The list of markets to claim DAW in
     * @param borrowers Whether or not to claim DAW earned by borrowing
     * @param suppliers Whether or not to claim DAW earned by supplying
     */
    function claimDeswap(address[] memory holders, DToken[] memory dTokens, bool borrowers, bool suppliers) public {
        uint j;
        updateDeswapYAIMintIndex();
        for (j = 0; j < holders.length; j++) {
            distributeYAIMinterDeswap(holders[j], true);
        }
        for (uint i = 0; i < dTokens.length; i++) {
            DToken dToken = dTokens[i];
            require(markets[address(dToken)].isListed, "not listed market");
            if (borrowers) {
                Exp memory borrowIndex = Exp({mantissa: dToken.borrowIndex()});
                updateDeswapBorrowIndex(address(dToken), borrowIndex);
                for (j = 0; j < holders.length; j++) {
                    distributeBorrowerDeswap(address(dToken), holders[j], borrowIndex, true);
                }
            }
            if (suppliers) {
                updateDeswapSupplyIndex(address(dToken));
                for (j = 0; j < holders.length; j++) {
                    distributeSupplierDeswap(address(dToken), holders[j], true);
                }
            }
        }
    }

    /*** Deswap Distribution Admin ***/

    /**
     * @notice Set the amount of DAW distributed per block
     * @param deswapRate_ The amount of DAW wei per block to distribute
     */
    function _setDeswapRate(uint deswapRate_) public onlyAdmin {
        uint oldRate = deswapRate;
        deswapRate = deswapRate_;
        emit NewDeswapRate(oldRate, deswapRate_);

        refreshDeswapSpeedsInternal();
    }

    /**
     * @notice Set the amount of DAW distributed per block to YAI Mint
     * @param deswapYAIRate_ The amount of DAW wei per block to distribute to YAI Mint
     */
    function _setDeswapYAIRate(uint deswapYAIRate_) public {
        require(msg.sender == admin, "only admin can");

        uint oldYAIRate = deswapYAIRate;
        deswapYAIRate = deswapYAIRate_;
        emit NewDeswapYAIRate(oldYAIRate, deswapYAIRate_);
    }

    /**
     * @notice Add markets to deswapMarkets, allowing them to earn DAW in the flywheel
     * @param dTokens The addresses of the markets to add
     */
    function _addDeswapMarkets(address[] calldata dTokens) external onlyAdmin {
        for (uint i = 0; i < dTokens.length; i++) {
            _addDeswapMarketInternal(dTokens[i]);
        }

        refreshDeswapSpeedsInternal();
    }

    function _addDeswapMarketInternal(address dToken) internal {
        Market storage market = markets[dToken];
        require(market.isListed, "deswap market is not listed");
        require(!market.isDeswap, "deswap market already added");

        market.isDeswap = true;
        emit MarketDeswap(DToken(dToken), true);

        if (deswapSupplyState[dToken].index == 0 && deswapSupplyState[dToken].block == 0) {
            deswapSupplyState[dToken] = DeswapMarketState({
                index: deswapInitialIndex,
                block: safe32(getBlockNumber(), "block number overflows")
            });
        }

        if (deswapBorrowState[dToken].index == 0 && deswapBorrowState[dToken].block == 0) {
            deswapBorrowState[dToken] = DeswapMarketState({
                index: deswapInitialIndex,
                block: safe32(getBlockNumber(), "block number overflows")
            });
        }
    }

    function _initializeDeswapYAIState(uint blockNumber) public {
        require(msg.sender == admin, "only admin can");
        if (address(yaiController) != address(0)) {
            yaiController._initializeDeswapYAIState(blockNumber);
        }
    }

    /**
     * @notice Remove a market from deswapMarkets, preventing it from earning DAW in the flywheel
     * @param dToken The address of the market to drop
     */
    function _dropDeswapMarket(address dToken) public onlyAdmin {
        Market storage market = markets[dToken];
        require(market.isDeswap == true, "not deswap market");

        market.isDeswap = false;
        emit MarketDeswap(DToken(dToken), false);

        refreshDeswapSpeedsInternal();
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view returns (DToken[] memory) {
        return allMarkets;
    }

    function getBlockNumber() public view returns (uint) {
        return block.number;
    }

    /**
     * @notice Return the address of the DAW token
     * @return The address of DAW
     */
    function getDAWAddress() public view returns (address) {
        return 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;
    }

    /*** YAI functions ***/

    /**
     * @notice Set the minted YAI amount of the `owner`
     * @param owner The address of the account to set
     * @param amount The amount of YAI to set to the account
     * @return The number of minted YAI by `owner`
     */
    function setMintedYAIOf(address owner, uint amount) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintYAIGuardianPaused && !repayYAIGuardianPaused, "YAI is paused");
        // Check caller is yaiController
        if (msg.sender != address(yaiController)) {
            return fail(Error.REJECTION, FailureInfo.SET_MINTED_YAI_REJECTION);
        }
        mintedYAIs[owner] = amount;

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Mint YAI
     */
    function mintYAI(uint mintYAIAmount) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintYAIGuardianPaused, "mintYAI is paused");

        // Keep the flywheel moving
        updateDeswapYAIMintIndex();
        distributeYAIMinterDeswap(msg.sender, false);
        return yaiController.mintYAI(msg.sender, mintYAIAmount);
    }

    /**
     * @notice Repay YAI
     */
    function repayYAI(uint repayYAIAmount) external onlyProtocolAllowed returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!repayYAIGuardianPaused, "repayYAI is paused");

        // Keep the flywheel moving
        updateDeswapYAIMintIndex();
        distributeYAIMinterDeswap(msg.sender, false);
        return yaiController.repayYAI(msg.sender, repayYAIAmount);
    }

    /**
     * @notice Get the minted YAI amount of the `owner`
     * @param owner The address of the account to query
     * @return The number of minted YAI by `owner`
     */
    function mintedYAIOf(address owner) external view returns (uint) {
        return mintedYAIs[owner];
    }

    /**
     * @notice Get Mintable YAI amount
     */
    function getMintableYAI(address minter) external view returns (uint, uint) {
        return yaiController.getMintableYAI(minter);
    }
}

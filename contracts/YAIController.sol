pragma solidity ^0.5.16;

import "./DToken.sol";
import "./PriceOracle.sol";
import "./ErrorReporter.sol";
import "./Exponential.sol";
import "./YAIControllerStorage.sol";
import "./YAIUnitroller.sol";
import "./YAI/YAI.sol";

interface ComptrollerImplInterface {
    function protocolPaused() external view returns (bool);
    function mintedYAIs(address account) external view returns (uint);
    function yaiMintRate() external view returns (uint);
    function deswapYAIRate() external view returns (uint);
    function deswapAccrued(address account) external view returns(uint);
    function getAssetsIn(address account) external view returns (DToken[] memory);
    function oracle() external view returns (PriceOracle);

    function distributeYAIMinterDeswap(address yaiMinter) external;
}

/**
 * @title Deswap's YAI Comptroller Contract
 * @author Deswap
 */
contract YAIController is YAIControllerStorageG2, YAIControllerErrorReporter, Exponential {

    /// @notice Emitted when Comptroller is changed
    event NewComptroller(ComptrollerInterface oldComptroller, ComptrollerInterface newComptroller);

    /**
     * @notice Event emitted when YAI is minted
     */
    event MintYAI(address minter, uint mintYAIAmount);

    /**
     * @notice Event emitted when YAI is repaid
     */
    event RepayYAI(address payer, address borrower, uint repayYAIAmount);

    /// @notice The initial Deswap index for a market
    uint224 public constant deswapInitialIndex = 1e36;

    /**
     * @notice Event emitted when a borrow is liquidated
     */
    event LiquidateYAI(address liquidator, address borrower, uint repayAmount, address dTokenCollateral, uint seizeTokens);

    /**
     * @notice Emitted when treasury guardian is changed
     */
    event NewTreasuryGuardian(address oldTreasuryGuardian, address newTreasuryGuardian);

    /**
     * @notice Emitted when treasury address is changed
     */
    event NewTreasuryAddress(address oldTreasuryAddress, address newTreasuryAddress);

    /**
     * @notice Emitted when treasury percent is changed
     */
    event NewTreasuryPercent(uint oldTreasuryPercent, uint newTreasuryPercent);

    /**
     * @notice Event emitted when YAIs are minted and fee are transferred
     */
    event MintFee(address minter, uint feeAmount);

    /*** Main Actions ***/
    struct MintLocalVars {
        Error err;
        MathError mathErr;
        uint mintAmount;
    }

    function mintYAI(uint mintYAIAmount) external nonReentrant returns (uint) {
        if(address(comptroller) != address(0)) {
            require(mintYAIAmount > 0, "mintYAIAmount cannt be zero");

            require(!ComptrollerImplInterface(address(comptroller)).protocolPaused(), "protocol is paused");

            MintLocalVars memory vars;

            address minter = msg.sender;

            // Keep the flywheel moving
            updateDeswapYAIMintIndex();
            ComptrollerImplInterface(address(comptroller)).distributeYAIMinterDeswap(minter);

            uint oErr;
            MathError mErr;
            uint accountMintYAINew;
            uint accountMintableYAI;

            (oErr, accountMintableYAI) = getMintableYAI(minter);
            if (oErr != uint(Error.NO_ERROR)) {
                return uint(Error.REJECTION);
            }

            // check that user have sufficient mintableYAI balance
            if (mintYAIAmount > accountMintableYAI) {
                return fail(Error.REJECTION, FailureInfo.YAI_MINT_REJECTION);
            }

            (mErr, accountMintYAINew) = addUInt(ComptrollerImplInterface(address(comptroller)).mintedYAIs(minter), mintYAIAmount);
            require(mErr == MathError.NO_ERROR, "YAI_MINT_AMOUNT_CALCULATION_FAILED");
            uint error = comptroller.setMintedYAIOf(minter, accountMintYAINew);
            if (error != 0 ) {
                return error;
            }

            uint feeAmount;
            uint remainedAmount;
            vars.mintAmount = mintYAIAmount;
            if (treasuryPercent != 0) {
                (vars.mathErr, feeAmount) = mulUInt(vars.mintAmount, treasuryPercent);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                (vars.mathErr, feeAmount) = divUInt(feeAmount, 1e18);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                (vars.mathErr, remainedAmount) = subUInt(vars.mintAmount, feeAmount);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                YAI(getYAIAddress()).mint(treasuryAddress, feeAmount);

                emit MintFee(minter, feeAmount);
            } else {
                remainedAmount = vars.mintAmount;
            }

            YAI(getYAIAddress()).mint(minter, remainedAmount);

            emit MintYAI(minter, remainedAmount);

            return uint(Error.NO_ERROR);
        }
    }

    /**
     * @notice Repay YAI
     */
    function repayYAI(uint repayYAIAmount) external nonReentrant returns (uint, uint) {
        if(address(comptroller) != address(0)) {
            require(repayYAIAmount > 0, "repayYAIAmount cannt be zero");

            require(!ComptrollerImplInterface(address(comptroller)).protocolPaused(), "protocol is paused");

            address payer = msg.sender;

            updateDeswapYAIMintIndex();
            ComptrollerImplInterface(address(comptroller)).distributeYAIMinterDeswap(payer);

            return repayYAIFresh(msg.sender, msg.sender, repayYAIAmount);
        }
    }

    /**
     * @notice Repay YAI Internal
     * @notice Borrowed YAIs are repaid by another user (possibly the borrower).
     * @param payer the account paying off the YAI
     * @param borrower the account with the debt being payed off
     * @param repayAmount the amount of YAI being returned
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function repayYAIFresh(address payer, address borrower, uint repayAmount) internal returns (uint, uint) {
        uint actualBurnAmount;

        uint yaiBalanceBorrower = ComptrollerImplInterface(address(comptroller)).mintedYAIs(borrower);

        if(yaiBalanceBorrower > repayAmount) {
            actualBurnAmount = repayAmount;
        } else {
            actualBurnAmount = yaiBalanceBorrower;
        }

        MathError mErr;
        uint accountYAINew;

        YAI(getYAIAddress()).burn(payer, actualBurnAmount);

        (mErr, accountYAINew) = subUInt(yaiBalanceBorrower, actualBurnAmount);
        require(mErr == MathError.NO_ERROR, "YAI_BURN_AMOUNT_CALCULATION_FAILED");

        uint error = comptroller.setMintedYAIOf(borrower, accountYAINew);
        if (error != 0) {
            return (error, 0);
        }
        emit RepayYAI(payer, borrower, actualBurnAmount);

        return (uint(Error.NO_ERROR), actualBurnAmount);
    }

    /**
     * @notice The sender liquidates the yai minters collateral.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of yai to be liquidated
     * @param dTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function liquidateYAI(address borrower, uint repayAmount, DTokenInterface dTokenCollateral) external nonReentrant returns (uint, uint) {
        require(!ComptrollerImplInterface(address(comptroller)).protocolPaused(), "protocol is paused");

        uint error = dTokenCollateral.accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but we still want to log the fact that an attempted liquidation failed
            return (fail(Error(error), FailureInfo.YAI_LIQUIDATE_ACCRUE_COLLATERAL_INTEREST_FAILED), 0);
        }

        // liquidateYAIFresh emits borrow-specific logs on errors, so we don't need to
        return liquidateYAIFresh(msg.sender, borrower, repayAmount, dTokenCollateral);
    }

    /**
     * @notice The liquidator liquidates the borrowers collateral by repay borrowers YAI.
     *  The collateral seized is transferred to the liquidator.
     * @param liquidator The address repaying the YAI and seizing collateral
     * @param borrower The borrower of this YAI to be liquidated
     * @param dTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the YAI to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment YAI.
     */
    function liquidateYAIFresh(address liquidator, address borrower, uint repayAmount, DTokenInterface dTokenCollateral) internal returns (uint, uint) {
        if(address(comptroller) != address(0)) {
            /* Fail if liquidate not allowed */
            uint allowed = comptroller.liquidateBorrowAllowed(address(this), address(dTokenCollateral), liquidator, borrower, repayAmount);
            if (allowed != 0) {
                return (failOpaque(Error.REJECTION, FailureInfo.YAI_LIQUIDATE_COMPTROLLER_REJECTION, allowed), 0);
            }

            /* Verify dTokenCollateral market's block number equals current block number */
            //if (dTokenCollateral.accrualBlockNumber() != accrualBlockNumber) {
            if (dTokenCollateral.accrualBlockNumber() != getBlockNumber()) {
                return (fail(Error.REJECTION, FailureInfo.YAI_LIQUIDATE_COLLATERAL_FRESHNESS_CHECK), 0);
            }

            /* Fail if borrower = liquidator */
            if (borrower == liquidator) {
                return (fail(Error.REJECTION, FailureInfo.YAI_LIQUIDATE_LIQUIDATOR_IS_BORROWER), 0);
            }

            /* Fail if repayAmount = 0 */
            if (repayAmount == 0) {
                return (fail(Error.REJECTION, FailureInfo.YAI_LIQUIDATE_CLOSE_AMOUNT_IS_ZERO), 0);
            }

            /* Fail if repayAmount = -1 */
            if (repayAmount == uint(-1)) {
                return (fail(Error.REJECTION, FailureInfo.YAI_LIQUIDATE_CLOSE_AMOUNT_IS_UINT_MAX), 0);
            }


            /* Fail if repayYAI fails */
            (uint repayBorrowError, uint actualRepayAmount) = repayYAIFresh(liquidator, borrower, repayAmount);
            if (repayBorrowError != uint(Error.NO_ERROR)) {
                return (fail(Error(repayBorrowError), FailureInfo.YAI_LIQUIDATE_REPAY_BORROW_FRESH_FAILED), 0);
            }

            /////////////////////////
            // EFFECTS & INTERACTIONS
            // (No safe failures beyond this point)

            /* We calculate the number of collateral tokens that will be seized */
            (uint amountSeizeError, uint seizeTokens) = comptroller.liquidateYAICalculateSeizeTokens(address(dTokenCollateral), actualRepayAmount);
            require(amountSeizeError == uint(Error.NO_ERROR), "YAI_LIQUIDATE_COMPTROLLER_CALCULATE_AMOUNT_SEIZE_FAILED");

            /* Revert if borrower collateral token balance < seizeTokens */
            require(dTokenCollateral.balanceOf(borrower) >= seizeTokens, "YAI_LIQUIDATE_SEIZE_TOO_MUCH");

            uint seizeError;
            seizeError = dTokenCollateral.seize(liquidator, borrower, seizeTokens);

            /* Revert if seize tokens fails (since we cannot be sure of side effects) */
            require(seizeError == uint(Error.NO_ERROR), "token seizure failed");

            /* We emit a LiquidateBorrow event */
            emit LiquidateYAI(liquidator, borrower, actualRepayAmount, address(dTokenCollateral), seizeTokens);

            /* We call the defense hook */
            comptroller.liquidateBorrowVerify(address(this), address(dTokenCollateral), liquidator, borrower, actualRepayAmount, seizeTokens);

            return (uint(Error.NO_ERROR), actualRepayAmount);
        }
    }

    /**
     * @notice Initialize the DeswapYAIState
     */
    function _initializeDeswapYAIState(uint blockNumber) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COMPTROLLER_OWNER_CHECK);
        }

        if (isDeswapYAIInitialized == false) {
            isDeswapYAIInitialized = true;
            uint yaiBlockNumber = blockNumber == 0 ? getBlockNumber() : blockNumber;
            deswapYAIState = DeswapYAIState({
                index: deswapInitialIndex,
                block: safe32(yaiBlockNumber, "block number overflows")
            });
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Accrue DAW to by updating the YAI minter index
     */
    function updateDeswapYAIMintIndex() public returns (uint) {
        uint yaiMinterSpeed = ComptrollerImplInterface(address(comptroller)).deswapYAIRate();
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, uint(deswapYAIState.block));
        if (deltaBlocks > 0 && yaiMinterSpeed > 0) {
            uint yaiAmount = YAI(getYAIAddress()).totalSupply();
            uint deswapAccrued = mul_(deltaBlocks, yaiMinterSpeed);
            Double memory ratio = yaiAmount > 0 ? fraction(deswapAccrued, yaiAmount) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: deswapYAIState.index}), ratio);
            deswapYAIState = DeswapYAIState({
                index: safe224(index.mantissa, "new index overflows"),
                block: safe32(blockNumber, "block number overflows")
            });
        } else if (deltaBlocks > 0) {
            deswapYAIState.block = safe32(blockNumber, "block number overflows");
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Calculate DAW accrued by a YAI minter
     * @param yaiMinter The address of the YAI minter to distribute DAW to
     */
    function calcDistributeYAIMinterDeswap(address yaiMinter) public returns(uint, uint, uint, uint) {
        // Check caller is comptroller
        if (msg.sender != address(comptroller)) {
            return (fail(Error.UNAUTHORIZED, FailureInfo.SET_COMPTROLLER_OWNER_CHECK), 0, 0, 0);
        }

        Double memory yaiMintIndex = Double({mantissa: deswapYAIState.index});
        Double memory yaiMinterIndex = Double({mantissa: deswapYAIMinterIndex[yaiMinter]});
        deswapYAIMinterIndex[yaiMinter] = yaiMintIndex.mantissa;

        if (yaiMinterIndex.mantissa == 0 && yaiMintIndex.mantissa > 0) {
            yaiMinterIndex.mantissa = deswapInitialIndex;
        }

        Double memory deltaIndex = sub_(yaiMintIndex, yaiMinterIndex);
        uint yaiMinterAmount = ComptrollerImplInterface(address(comptroller)).mintedYAIs(yaiMinter);
        uint yaiMinterDelta = mul_(yaiMinterAmount, deltaIndex);
        uint yaiMinterAccrued = add_(ComptrollerImplInterface(address(comptroller)).deswapAccrued(yaiMinter), yaiMinterDelta);
        return (uint(Error.NO_ERROR), yaiMinterAccrued, yaiMinterDelta, yaiMintIndex.mantissa);
    }

    /*** Admin Functions ***/

    /**
      * @notice Sets a new comptroller
      * @dev Admin function to set a new comptroller
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setComptroller(ComptrollerInterface comptroller_) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COMPTROLLER_OWNER_CHECK);
        }

        ComptrollerInterface oldComptroller = comptroller;
        comptroller = comptroller_;
        emit NewComptroller(oldComptroller, comptroller_);

        return uint(Error.NO_ERROR);
    }

    function _become(YAIUnitroller unitroller) external {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account total supply balance.
     *  Note that `dTokenBalance` is the number of dTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountAmountLocalVars {
        uint totalSupplyAmount;
        uint sumSupply;
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

    function getMintableYAI(address minter) public view returns (uint, uint) {
        PriceOracle oracle = ComptrollerImplInterface(address(comptroller)).oracle();
        DToken[] memory enteredMarkets = ComptrollerImplInterface(address(comptroller)).getAssetsIn(minter);

        AccountAmountLocalVars memory vars; // Holds all our calculation results

        uint oErr;
        MathError mErr;

        uint accountMintableYAI;
        uint i;

        /**
         * We use this formula to calculate mintable YAI amount.
         * totalSupplyAmount * YAIMintRate - (totalBorrowAmount + mintedYAIOf)
         */
        for (i = 0; i < enteredMarkets.length; i++) {
            (oErr, vars.dTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = enteredMarkets[i].getAccountSnapshot(minter);
            if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (uint(Error.SNAPSHOT_ERROR), 0);
            }
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(enteredMarkets[i]);
            if (vars.oraclePriceMantissa == 0) {
                return (uint(Error.PRICE_ERROR), 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            (mErr, vars.tokensToDenom) = mulExp(vars.exchangeRate, vars.oraclePrice);
            if (mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            // sumSupply += tokensToDenom * dTokenBalance
            (mErr, vars.sumSupply) = mulScalarTruncateAddUInt(vars.tokensToDenom, vars.dTokenBalance, vars.sumSupply);
            if (mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);
            if (mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }
        }

        (mErr, vars.sumBorrowPlusEffects) = addUInt(vars.sumBorrowPlusEffects, ComptrollerImplInterface(address(comptroller)).mintedYAIs(minter));
        if (mErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mErr, accountMintableYAI) = mulUInt(vars.sumSupply, ComptrollerImplInterface(address(comptroller)).yaiMintRate());
        require(mErr == MathError.NO_ERROR, "YAI_MINT_AMOUNT_CALCULATION_FAILED");

        (mErr, accountMintableYAI) = divUInt(accountMintableYAI, 10000);
        require(mErr == MathError.NO_ERROR, "YAI_MINT_AMOUNT_CALCULATION_FAILED");


        (mErr, accountMintableYAI) = subUInt(accountMintableYAI, vars.sumBorrowPlusEffects);
        if (mErr != MathError.NO_ERROR) {
            return (uint(Error.REJECTION), 0);
        }

        return (uint(Error.NO_ERROR), accountMintableYAI);
    }

    function _setTreasuryData(address newTreasuryGuardian, address newTreasuryAddress, uint newTreasuryPercent) external returns (uint) {
        // Check caller is admin
        if (!(msg.sender == admin || msg.sender == treasuryGuardian)) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_TREASURY_OWNER_CHECK);
        }

        require(newTreasuryPercent < 1e18, "treasury percent cap overflow");

        address oldTreasuryGuardian = treasuryGuardian;
        address oldTreasuryAddress = treasuryAddress;
        uint oldTreasuryPercent = treasuryPercent;

        treasuryGuardian = newTreasuryGuardian;
        treasuryAddress = newTreasuryAddress;
        treasuryPercent = newTreasuryPercent;

        emit NewTreasuryGuardian(oldTreasuryGuardian, newTreasuryGuardian);
        emit NewTreasuryAddress(oldTreasuryAddress, newTreasuryAddress);
        emit NewTreasuryPercent(oldTreasuryPercent, newTreasuryPercent);

        return uint(Error.NO_ERROR);
    }

    function getBlockNumber() public view returns (uint) {
        return block.number;
    }

    /**
     * @notice Return the address of the YAI token
     * @return The address of YAI
     */
    function getYAIAddress() public view returns (address) {
        return 0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7;
    }

    function initialize() onlyAdmin public {
        // The counter starts true to prevent changing it from zero to non-zero (i.e. smaller cost/refund)
        _notEntered = true;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }

    /*** Reentrancy Guard ***/

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true; // get a gas-refund post-Istanbul
    }
}

pragma solidity ^0.5.16;

import "./DToken.sol";
import "./PriceOracle.sol";
import "./ErrorReporter.sol";
import "./Exponential.sol";
import "./YAIControllerStorage.sol";
import "./YAIUnitroller.sol";
import "./YAI/YAI.sol";

interface ComptrollerLensInterface {
    function protocolPaused() external view returns (bool);
    function mintedYAIs(address account) external view returns (uint);
    function yaiMintRate() external view returns (uint);
    function deswapYAIRate() external view returns (uint);
    function deswapAccrued(address account) external view returns(uint);
    function getAssetsIn(address account) external view returns (DToken[] memory);
    function oracle() external view returns (PriceOracle);

    function distributeYAIMinterDeswap(address yaiMinter, bool distributeAll) external;
}

/**
 * @title Deswap's YAI Comptroller Contract
 * @author Deswap
 */
contract YAIControllerG1 is YAIControllerStorageG1, YAIControllerErrorReporter, Exponential {

    /// @notice Emitted when Comptroller is changed
    event NewComptroller(ComptrollerInterface oldComptroller, ComptrollerInterface newComptroller);

    /**
     * @notice Event emitted when YAI is minted
     */
    event MintYAI(address minter, uint mintYAIAmount);

    /**
     * @notice Event emitted when YAI is repaid
     */
    event RepayYAI(address repayer, uint repayYAIAmount);

    /// @notice The initial Deswap index for a market
    uint224 public constant deswapInitialIndex = 1e36;

    /*** Main Actions ***/

    function mintYAI(uint mintYAIAmount) external returns (uint) {
        if(address(comptroller) != address(0)) {
            require(!ComptrollerLensInterface(address(comptroller)).protocolPaused(), "protocol is paused");

            address minter = msg.sender;

            // Keep the flywheel moving
            updateDeswapYAIMintIndex();
            ComptrollerLensInterface(address(comptroller)).distributeYAIMinterDeswap(minter, false);

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

            (mErr, accountMintYAINew) = addUInt(ComptrollerLensInterface(address(comptroller)).mintedYAIs(minter), mintYAIAmount);
            require(mErr == MathError.NO_ERROR, "YAI_MINT_AMOUNT_CALCULATION_FAILED");
            uint error = comptroller.setMintedYAIOf(minter, accountMintYAINew);
            if (error != 0 ) {
                return error;
            }

            YAI(getYAIAddress()).mint(minter, mintYAIAmount);
            emit MintYAI(minter, mintYAIAmount);

            return uint(Error.NO_ERROR);
        }
    }

    /**
     * @notice Repay YAI
     */
    function repayYAI(uint repayYAIAmount) external returns (uint) {
        if(address(comptroller) != address(0)) {
            require(!ComptrollerLensInterface(address(comptroller)).protocolPaused(), "protocol is paused");

            address repayer = msg.sender;

            updateDeswapYAIMintIndex();
            ComptrollerLensInterface(address(comptroller)).distributeYAIMinterDeswap(repayer, false);

            uint actualBurnAmount;

            uint yaiBalance = ComptrollerLensInterface(address(comptroller)).mintedYAIs(repayer);

            if(yaiBalance > repayYAIAmount) {
                actualBurnAmount = repayYAIAmount;
            } else {
                actualBurnAmount = yaiBalance;
            }

            uint error = comptroller.setMintedYAIOf(repayer, yaiBalance - actualBurnAmount);
            if (error != 0) {
                return error;
            }

            YAI(getYAIAddress()).burn(repayer, actualBurnAmount);
            emit RepayYAI(repayer, actualBurnAmount);

            return uint(Error.NO_ERROR);
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
    }

    /**
     * @notice Accrue DAW to by updating the YAI minter index
     */
    function updateDeswapYAIMintIndex() public returns (uint) {
        uint yaiMinterSpeed = ComptrollerLensInterface(address(comptroller)).deswapYAIRate();
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
        uint yaiMinterAmount = ComptrollerLensInterface(address(comptroller)).mintedYAIs(yaiMinter);
        uint yaiMinterDelta = mul_(yaiMinterAmount, deltaIndex);
        uint yaiMinterAccrued = add_(ComptrollerLensInterface(address(comptroller)).deswapAccrued(yaiMinter), yaiMinterDelta);
        return (uint(Error.NO_ERROR), yaiMinterAccrued, yaiMinterDelta, yaiMintIndex.mantissa);
    }

    /*** Admin Functions ***/

    /**
      * @notice Sets a new comptroller
      * @dev Admin function to set a new comptroller
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setComptroller(ComptrollerInterface comptroller_) public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COMPTROLLER_OWNER_CHECK);
        }

        ComptrollerInterface oldComptroller = comptroller;
        comptroller = comptroller_;
        emit NewComptroller(oldComptroller, comptroller_);

        return uint(Error.NO_ERROR);
    }

    function _become(YAIUnitroller unitroller) public {
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
        PriceOracle oracle = ComptrollerLensInterface(address(comptroller)).oracle();
        DToken[] memory enteredMarkets = ComptrollerLensInterface(address(comptroller)).getAssetsIn(minter);

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

        (mErr, vars.sumBorrowPlusEffects) = addUInt(vars.sumBorrowPlusEffects, ComptrollerLensInterface(address(comptroller)).mintedYAIs(minter));
        if (mErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mErr, accountMintableYAI) = mulUInt(vars.sumSupply, ComptrollerLensInterface(address(comptroller)).yaiMintRate());
        require(mErr == MathError.NO_ERROR, "YAI_MINT_AMOUNT_CALCULATION_FAILED");

        (mErr, accountMintableYAI) = divUInt(accountMintableYAI, 10000);
        require(mErr == MathError.NO_ERROR, "YAI_MINT_AMOUNT_CALCULATION_FAILED");


        (mErr, accountMintableYAI) = subUInt(accountMintableYAI, vars.sumBorrowPlusEffects);
        if (mErr != MathError.NO_ERROR) {
            return (uint(Error.REJECTION), 0);
        }

        return (uint(Error.NO_ERROR), accountMintableYAI);
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
}

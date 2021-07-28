pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2;

import "../DBep20.sol";
import "../DToken.sol";
import "../PriceOracle.sol";
import "../EIP20Interface.sol";
import "../Governance/GovernorAlpha.sol";
import "../Governance/DAW.sol";

interface ComptrollerLensInterface {
    function markets(address) external view returns (bool, uint);
    function oracle() external view returns (PriceOracle);
    function getAccountLiquidity(address) external view returns (uint, uint, uint);
    function getAssetsIn(address) external view returns (DToken[] memory);
    function claimDeswap(address) external;
    function deswapAccrued(address) external view returns (uint);
}

contract DeswapLens {
    struct DTokenMetadata {
        address dToken;
        uint exchangeRateCurrent;
        uint supplyRatePerBlock;
        uint borrowRatePerBlock;
        uint reserveFactorMantissa;
        uint totalBorrows;
        uint totalReserves;
        uint totalSupply;
        uint totalCash;
        bool isListed;
        uint collateralFactorMantissa;
        address underlyingAssetAddress;
        uint dTokenDecimals;
        uint underlyingDecimals;
    }

    function dTokenMetadata(DToken dToken) public returns (DTokenMetadata memory) {
        uint exchangeRateCurrent = dToken.exchangeRateCurrent();
        ComptrollerLensInterface comptroller = ComptrollerLensInterface(address(dToken.comptroller()));
        (bool isListed, uint collateralFactorMantissa) = comptroller.markets(address(dToken));
        address underlyingAssetAddress;
        uint underlyingDecimals;

        if (compareStrings(dToken.symbol(), "dBNB")) {
            underlyingAssetAddress = address(0);
            underlyingDecimals = 18;
        } else {
            DBep20 dBep20 = DBep20(address(dToken));
            underlyingAssetAddress = dBep20.underlying();
            underlyingDecimals = EIP20Interface(dBep20.underlying()).decimals();
        }

        return DTokenMetadata({
            dToken: address(dToken),
            exchangeRateCurrent: exchangeRateCurrent,
            supplyRatePerBlock: dToken.supplyRatePerBlock(),
            borrowRatePerBlock: dToken.borrowRatePerBlock(),
            reserveFactorMantissa: dToken.reserveFactorMantissa(),
            totalBorrows: dToken.totalBorrows(),
            totalReserves: dToken.totalReserves(),
            totalSupply: dToken.totalSupply(),
            totalCash: dToken.getCash(),
            isListed: isListed,
            collateralFactorMantissa: collateralFactorMantissa,
            underlyingAssetAddress: underlyingAssetAddress,
            dTokenDecimals: dToken.decimals(),
            underlyingDecimals: underlyingDecimals
        });
    }

    function dTokenMetadataAll(DToken[] calldata dTokens) external returns (DTokenMetadata[] memory) {
        uint dTokenCount = dTokens.length;
        DTokenMetadata[] memory res = new DTokenMetadata[](dTokenCount);
        for (uint i = 0; i < dTokenCount; i++) {
            res[i] = dTokenMetadata(dTokens[i]);
        }
        return res;
    }

    struct DTokenBalances {
        address dToken;
        uint balanceOf;
        uint borrowBalanceCurrent;
        uint balanceOfUnderlying;
        uint tokenBalance;
        uint tokenAllowance;
    }

    function dTokenBalances(DToken dToken, address payable account) public returns (DTokenBalances memory) {
        uint balanceOf = dToken.balanceOf(account);
        uint borrowBalanceCurrent = dToken.borrowBalanceCurrent(account);
        uint balanceOfUnderlying = dToken.balanceOfUnderlying(account);
        uint tokenBalance;
        uint tokenAllowance;

        if (compareStrings(dToken.symbol(), "dBNB")) {
            tokenBalance = account.balance;
            tokenAllowance = account.balance;
        } else {
            DBep20 dBep20 = DBep20(address(dToken));
            EIP20Interface underlying = EIP20Interface(dBep20.underlying());
            tokenBalance = underlying.balanceOf(account);
            tokenAllowance = underlying.allowance(account, address(dToken));
        }

        return DTokenBalances({
            dToken: address(dToken),
            balanceOf: balanceOf,
            borrowBalanceCurrent: borrowBalanceCurrent,
            balanceOfUnderlying: balanceOfUnderlying,
            tokenBalance: tokenBalance,
            tokenAllowance: tokenAllowance
        });
    }

    function dTokenBalancesAll(DToken[] calldata dTokens, address payable account) external returns (DTokenBalances[] memory) {
        uint dTokenCount = dTokens.length;
        DTokenBalances[] memory res = new DTokenBalances[](dTokenCount);
        for (uint i = 0; i < dTokenCount; i++) {
            res[i] = dTokenBalances(dTokens[i], account);
        }
        return res;
    }

    struct DTokenUnderlyingPrice {
        address dToken;
        uint underlyingPrice;
    }

    function dTokenUnderlyingPrice(DToken dToken) public view returns (DTokenUnderlyingPrice memory) {
        ComptrollerLensInterface comptroller = ComptrollerLensInterface(address(dToken.comptroller()));
        PriceOracle priceOracle = comptroller.oracle();

        return DTokenUnderlyingPrice({
            dToken: address(dToken),
            underlyingPrice: priceOracle.getUnderlyingPrice(dToken)
        });
    }

    function dTokenUnderlyingPriceAll(DToken[] calldata dTokens) external view returns (DTokenUnderlyingPrice[] memory) {
        uint dTokenCount = dTokens.length;
        DTokenUnderlyingPrice[] memory res = new DTokenUnderlyingPrice[](dTokenCount);
        for (uint i = 0; i < dTokenCount; i++) {
            res[i] = dTokenUnderlyingPrice(dTokens[i]);
        }
        return res;
    }

    struct AccountLimits {
        DToken[] markets;
        uint liquidity;
        uint shortfall;
    }

    function getAccountLimits(ComptrollerLensInterface comptroller, address account) public view returns (AccountLimits memory) {
        (uint errorCode, uint liquidity, uint shortfall) = comptroller.getAccountLiquidity(account);
        require(errorCode == 0, "account liquidity error");

        return AccountLimits({
            markets: comptroller.getAssetsIn(account),
            liquidity: liquidity,
            shortfall: shortfall
        });
    }

    struct GovReceipt {
        uint proposalId;
        bool hasVoted;
        bool support;
        uint96 votes;
    }

    function getGovReceipts(GovernorAlpha governor, address voter, uint[] memory proposalIds) public view returns (GovReceipt[] memory) {
        uint proposalCount = proposalIds.length;
        GovReceipt[] memory res = new GovReceipt[](proposalCount);
        for (uint i = 0; i < proposalCount; i++) {
            GovernorAlpha.Receipt memory receipt = governor.getReceipt(proposalIds[i], voter);
            res[i] = GovReceipt({
                proposalId: proposalIds[i],
                hasVoted: receipt.hasVoted,
                support: receipt.support,
                votes: receipt.votes
            });
        }
        return res;
    }

    struct GovProposal {
        uint proposalId;
        address proposer;
        uint eta;
        address[] targets;
        uint[] values;
        string[] signatures;
        bytes[] calldatas;
        uint startBlock;
        uint endBlock;
        uint forVotes;
        uint againstVotes;
        bool canceled;
        bool executed;
    }

    function setProposal(GovProposal memory res, GovernorAlpha governor, uint proposalId) internal view {
        (
            ,
            address proposer,
            uint eta,
            uint startBlock,
            uint endBlock,
            uint forVotes,
            uint againstVotes,
            bool canceled,
            bool executed
        ) = governor.proposals(proposalId);
        res.proposalId = proposalId;
        res.proposer = proposer;
        res.eta = eta;
        res.startBlock = startBlock;
        res.endBlock = endBlock;
        res.forVotes = forVotes;
        res.againstVotes = againstVotes;
        res.canceled = canceled;
        res.executed = executed;
    }

    function getGovProposals(GovernorAlpha governor, uint[] calldata proposalIds) external view returns (GovProposal[] memory) {
        GovProposal[] memory res = new GovProposal[](proposalIds.length);
        for (uint i = 0; i < proposalIds.length; i++) {
            (
                address[] memory targets,
                uint[] memory values,
                string[] memory signatures,
                bytes[] memory calldatas
            ) = governor.getActions(proposalIds[i]);
            res[i] = GovProposal({
                proposalId: 0,
                proposer: address(0),
                eta: 0,
                targets: targets,
                values: values,
                signatures: signatures,
                calldatas: calldatas,
                startBlock: 0,
                endBlock: 0,
                forVotes: 0,
                againstVotes: 0,
                canceled: false,
                executed: false
            });
            setProposal(res[i], governor, proposalIds[i]);
        }
        return res;
    }

    struct DAWBalanceMetadata {
        uint balance;
        uint votes;
        address delegate;
    }

    function getDAWBalanceMetadata(DAW daw, address account) external view returns (DAWBalanceMetadata memory) {
        return DAWBalanceMetadata({
            balance: daw.balanceOf(account),
            votes: uint256(daw.getCurrentVotes(account)),
            delegate: daw.delegates(account)
        });
    }

    struct DAWBalanceMetadataExt {
        uint balance;
        uint votes;
        address delegate;
        uint allocated;
    }

    function getDAWBalanceMetadataExt(DAW daw, ComptrollerLensInterface comptroller, address account) external returns (DAWBalanceMetadataExt memory) {
        uint balance = daw.balanceOf(account);
        comptroller.claimDeswap(account);
        uint newBalance = daw.balanceOf(account);
        uint accrued = comptroller.deswapAccrued(account);
        uint total = add(accrued, newBalance, "sum daw total");
        uint allocated = sub(total, balance, "sub allocated");

        return DAWBalanceMetadataExt({
            balance: balance,
            votes: uint256(daw.getCurrentVotes(account)),
            delegate: daw.delegates(account),
            allocated: allocated
        });
    }

    struct DeswapVotes {
        uint blockNumber;
        uint votes;
    }

    function getDeswapVotes(DAW daw, address account, uint32[] calldata blockNumbers) external view returns (DeswapVotes[] memory) {
        DeswapVotes[] memory res = new DeswapVotes[](blockNumbers.length);
        for (uint i = 0; i < blockNumbers.length; i++) {
            res[i] = DeswapVotes({
                blockNumber: uint256(blockNumbers[i]),
                votes: uint256(daw.getPriorVotes(account, blockNumbers[i]))
            });
        }
        return res;
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }

    function add(uint a, uint b, string memory errorMessage) internal pure returns (uint) {
        uint c = a + b;
        require(c >= a, errorMessage);
        return c;
    }

    function sub(uint a, uint b, string memory errorMessage) internal pure returns (uint) {
        require(b <= a, errorMessage);
        uint c = a - b;
        return c;
    }
}

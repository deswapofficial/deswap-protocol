pragma solidity ^0.5.16;

contract ComptrollerInterfaceG1 {
    /// @notice Indicator that this is a Comptroller contract (for inspection)
    bool public constant isComptroller = true;

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata dTokens) external returns (uint[] memory);
    function exitMarket(address dToken) external returns (uint);

    /*** Policy Hooks ***/

    function mintAllowed(address dToken, address minter, uint mintAmount) external returns (uint);
    function mintVerify(address dToken, address minter, uint mintAmount, uint mintTokens) external;

    function redeemAllowed(address dToken, address redeemer, uint redeemTokens) external returns (uint);
    function redeemVerify(address dToken, address redeemer, uint redeemAmount, uint redeemTokens) external;

    function borrowAllowed(address dToken, address borrower, uint borrowAmount) external returns (uint);
    function borrowVerify(address dToken, address borrower, uint borrowAmount) external;

    function repayBorrowAllowed(
        address dToken,
        address payer,
        address borrower,
        uint repayAmount) external returns (uint);
    function repayBorrowVerify(
        address dToken,
        address payer,
        address borrower,
        uint repayAmount,
        uint borrowerIndex) external;

    function liquidateBorrowAllowed(
        address dTokenBorrowed,
        address dTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) external returns (uint);
    function liquidateBorrowVerify(
        address dTokenBorrowed,
        address dTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount,
        uint seizeTokens) external;

    function seizeAllowed(
        address dTokenCollateral,
        address dTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external returns (uint);
    function seizeVerify(
        address dTokenCollateral,
        address dTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external;

    function transferAllowed(address dToken, address src, address dst, uint transferTokens) external returns (uint);
    function transferVerify(address dToken, address src, address dst, uint transferTokens) external;

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address dTokenBorrowed,
        address dTokenCollateral,
        uint repayAmount) external view returns (uint, uint);
    function setMintedYAIOf(address owner, uint amount) external returns (uint);
}

contract ComptrollerInterfaceG2 is ComptrollerInterfaceG1 {
    function liquidateYAICalculateSeizeTokens(
        address dTokenCollateral,
        uint repayAmount) external view returns (uint, uint);
}

contract ComptrollerInterface is ComptrollerInterfaceG2 {
}

interface IYAIVault {
    function updatePendingRewards() external;
}

interface IComptroller {
    /*** Treasury Data ***/
    function treasuryAddress() external view returns (address);
    function treasuryPercent() external view returns (uint);
}

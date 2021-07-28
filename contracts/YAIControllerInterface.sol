pragma solidity ^0.5.16;

contract YAIControllerInterface {
    function getYAIAddress() public view returns (address);
    function getMintableYAI(address minter) public view returns (uint, uint);
    function mintYAI(address minter, uint mintYAIAmount) external returns (uint);
    function repayYAI(address repayer, uint repayYAIAmount) external returns (uint);

    function _initializeDeswapYAIState(uint blockNumber) external returns (uint);
    function updateDeswapYAIMintIndex() external returns (uint);
    function calcDistributeYAIMinterDeswap(address yaiMinter) external returns(uint, uint, uint, uint);
}

pragma solidity ^0.5.16;

import "./ComptrollerInterface.sol";

contract YAIUnitrollerAdminStorage {
    /**
    * @notice Administrator for this contract
    */
    address public admin;

    /**
    * @notice Pending administrator for this contract
    */
    address public pendingAdmin;

    /**
    * @notice Active brains of Unitroller
    */
    address public yaiControllerImplementation;

    /**
    * @notice Pending brains of Unitroller
    */
    address public pendingYAIControllerImplementation;
}

contract YAIControllerStorageG1 is YAIUnitrollerAdminStorage {
    ComptrollerInterface public comptroller;

    struct DeswapYAIState {
        /// @notice The last updated deswapYAIMintIndex
        uint224 index;

        /// @notice The block number the index was last updated at
        uint32 block;
    }

    /// @notice The Deswap YAI state
    DeswapYAIState public deswapYAIState;

    /// @notice The Deswap YAI state initialized
    bool public isDeswapYAIInitialized;

    /// @notice The Deswap YAI minter index as of the last time they accrued DAW
    mapping(address => uint) public deswapYAIMinterIndex;
}

contract YAIControllerStorageG2 is YAIControllerStorageG1 {
    /// @notice Treasury Guardian address
    address public treasuryGuardian;

    /// @notice Treasury address
    address public treasuryAddress;

    /// @notice Fee percent of accrued interest with decimal 18
    uint256 public treasuryPercent;

    /// @notice Guard variable for re-entrancy checks
    bool internal _notEntered;
}

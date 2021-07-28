pragma solidity ^0.5.16;
import "./SafeMath.sol";
import "./IBEP20.sol";

contract YAIVaultAdminStorage {
    /**
    * @notice Administrator for this contract
    */
    address public admin;

    /**
    * @notice Pending administrator for this contract
    */
    address public pendingAdmin;

    /**
    * @notice Active brains of YAI Vault
    */
    address public yaiVaultImplementation;

    /**
    * @notice Pending brains of YAI Vault
    */
    address public pendingYAIVaultImplementation;
}

contract YAIVaultStorage is YAIVaultAdminStorage {
    /// @notice The DAW TOKEN!
    IBEP20 public daw;

    /// @notice The YAI TOKEN!
    IBEP20 public yai;

    /// @notice Guard variable for re-entrancy checks
    bool internal _notEntered;

    /// @notice DAW balance of vault
    uint256 public dawBalance;

    /// @notice Accumulated DAW per share
    uint256 public accDAWPerShare;

    //// pending rewards awaiting anyone to update
    uint256 public pendingRewards;

    /// @notice Info of each user.
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    // Info of each user that stakes tokens.
    mapping(address => UserInfo) public userInfo;
}

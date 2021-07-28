pragma solidity ^0.5.16;
import "./SafeBEP20.sol";
import "./IBEP20.sol";
import "./YAIVaultProxy.sol";
import "./YAIVaultStorage.sol";
import "./YAIVaultErrorReporter.sol";

contract YAIVault is YAIVaultStorage {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    /// @notice Event emitted when YAI deposit
    event Deposit(address indexed user, uint256 amount);

    /// @notice Event emitted when YAI withrawal
    event Withdraw(address indexed user, uint256 amount);

    /// @notice Event emitted when admin changed
    event AdminTransfered(address indexed oldAdmin, address indexed newAdmin);

    constructor() public {
        admin = msg.sender;
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

    /**
     * @notice Deposit YAI to YAIVault for DAW allocation
     * @param _amount The amount to deposit to vault
     */
    function deposit(uint256 _amount) public nonReentrant {
        UserInfo storage user = userInfo[msg.sender];

        updateVault();

        // Transfer pending tokens to user
        updateAndPayOutPending(msg.sender);

        // Transfer in the amounts from user
        if(_amount > 0) {
            yai.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }

        user.rewardDebt = user.amount.mul(accDAWPerShare).div(1e18);
        emit Deposit(msg.sender, _amount);
    }

    /**
     * @notice Withdraw YAI from YAIVault
     * @param _amount The amount to withdraw from vault
     */
    function withdraw(uint256 _amount) public nonReentrant {
        _withdraw(msg.sender, _amount);
    }

    /**
     * @notice Claim DAW from YAIVault
     */
    function claim() public nonReentrant {
        _withdraw(msg.sender, 0);
    }

    /**
     * @notice Low level withdraw function
     * @param account The account to withdraw from vault
     * @param _amount The amount to withdraw from vault
     */
    function _withdraw(address account, uint256 _amount) internal {
        UserInfo storage user = userInfo[account];
        require(user.amount >= _amount, "withdraw: not good");

        updateVault();
        updateAndPayOutPending(account); // Update balances of account this is not withdrawal but claiming DAW farmed

        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            yai.safeTransfer(address(account), _amount);
        }
        user.rewardDebt = user.amount.mul(accDAWPerShare).div(1e18);

        emit Withdraw(account, _amount);
    }

    /**
     * @notice View function to see pending DAW on frontend
     * @param _user The user to see pending DAW
     */
    function pendingDAW(address _user) public view returns (uint256)
    {
        UserInfo storage user = userInfo[_user];

        return user.amount.mul(accDAWPerShare).div(1e18).sub(user.rewardDebt);
    }

    /**
     * @notice Update and pay out pending DAW to user
     * @param account The user to pay out
     */
    function updateAndPayOutPending(address account) internal {
        uint256 pending = pendingDAW(account);

        if(pending > 0) {
            safeDAWTransfer(account, pending);
        }
    }

    /**
     * @notice Safe DAW transfer function, just in case if rounding error causes pool to not have enough DAW
     * @param _to The address that DAW to be transfered
     * @param _amount The amount that DAW to be transfered
     */
    function safeDAWTransfer(address _to, uint256 _amount) internal {
        uint256 dawBal = daw.balanceOf(address(this));

        if (_amount > dawBal) {
            daw.transfer(_to, dawBal);
            dawBalance = daw.balanceOf(address(this));
        } else {
            daw.transfer(_to, _amount);
            dawBalance = daw.balanceOf(address(this));
        }
    }

    /**
     * @notice Function that updates pending rewards
     */
    function updatePendingRewards() public {
        uint256 newRewards = daw.balanceOf(address(this)).sub(dawBalance);

        if(newRewards > 0) {
            dawBalance = daw.balanceOf(address(this)); // If there is no change the balance didn't change
            pendingRewards = pendingRewards.add(newRewards);
        }
    }

    /**
     * @notice Update reward variables to be up-to-date
     */
    function updateVault() internal {
        uint256 yaiBalance = yai.balanceOf(address(this));
        if (yaiBalance == 0) { // avoids division by 0 errors
            return;
        }

        accDAWPerShare = accDAWPerShare.add(pendingRewards.mul(1e18).div(yaiBalance));
        pendingRewards = 0;
    }

    /**
     * @dev Returns the address of the current admin
     */
    function getAdmin() public view returns (address) {
        return admin;
    }

    /**
     * @dev Burn the current admin
     */
    function burnAdmin() public onlyAdmin {
        emit AdminTransfered(admin, address(0));
        admin = address(0);
    }

    /**
     * @dev Set the current admin to new address
     */
    function setNewAdmin(address newAdmin) public onlyAdmin {
        require(newAdmin != address(0), "new owner is the zero address");
        emit AdminTransfered(admin, newAdmin);
        admin = newAdmin;
    }

    /*** Admin Functions ***/

    function _become(YAIVaultProxy yaiVaultProxy) public {
        require(msg.sender == yaiVaultProxy.admin(), "only proxy admin can change brains");
        require(yaiVaultProxy._acceptImplementation() == 0, "change not authorized");
    }

    function setDeswapInfo(address _daw, address _yai) public onlyAdmin {
        daw = IBEP20(_daw);
        yai = IBEP20(_yai);

        _notEntered = true;
    }
}

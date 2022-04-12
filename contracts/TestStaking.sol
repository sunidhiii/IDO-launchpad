// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./SafeMath.sol";
import "./IERC20.sol";
import "./Address.sol";
import "./SafeERC20.sol";
import "./Context.sol";
import "./Ownable.sol";

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
  // Booleans are more expensive than uint256 or any type that takes up a full
  // word because each write operation emits an extra SLOAD to first read the
  // slot's contents, replace the bits taken up by the boolean, and then write
  // back. This is the compiler's defense against contract upgrades and
  // pointer aliasing, and it cannot be disabled.

  // The values being non-zero value makes deployment a bit more expensive,
  // but in exchange the refund on every call to nonReentrant will be lower in
  // amount. Since refunds are capped to a percentage of the total
  // transaction's gas, it is best to keep them low in cases like this one, to
  // increase the likelihood of the full refund coming into effect.
  uint256 private constant _NOT_ENTERED = 1;
  uint256 private constant _ENTERED = 2;

  uint256 private _status;

  constructor () public {
    _status = _NOT_ENTERED;
  }

  /**
   * @dev Prevents a contract from calling itself, directly or indirectly.
   * Calling a `nonReentrant` function from another `nonReentrant`
   * function is not supported. It is possible to prevent this from happening
   * by making the `nonReentrant` function external, and make it call a
   * `private` function that does the actual work.
   */
  modifier nonReentrant() {
    // On the first call to nonReentrant, _notEntered will be true
    require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

    // Any calls to nonReentrant after this point will fail
    _status = _ENTERED;

    _;

    // By storing the original value once again, a refund is triggered (see
    // https://eips.ethereum.org/EIPS/eip-2200)
    _status = _NOT_ENTERED;
  }
}

contract TestStaking is Ownable, ReentrancyGuard {
  using SafeMath for uint256;

  using SafeERC20 for IERC20;
  // The address of the smart chef factory
  address public SMART_CHEF_FACTORY;

  // Whether a limit is set for users
  bool public hasUserLimit;

  // Whether it is initialized
  bool public isInitialized;

  // Accrued token per share
  uint256 public accTokenPerShare;

  // The block number when Pool mining ends.
  uint256 public bonusEndBlock;

  // The block number when Pool mining starts.
  uint256 public startBlock;

  // The block number of the last pool update
  uint256 public lastRewardBlock;

  // The pool limit (0 if none)
  uint256 public poolLimitPerUser;

  // CAKE tokens created per block.
  uint256 public rewardPerBlock;

  // The precision factor
  uint256 public PRECISION_FACTOR;

  // The reward token
  IERC20 public rewardToken;

  // The staked token
  IERC20 public stakedToken;

  // Total staking tokens
  uint256 public totalStakingTokens;

  // Total reward tokens
  uint256 public totalRewardTokens;

  // Freeze start block
  uint256 public freezeStartBlock;

  // Freeze end block
  uint256 public freezeEndBlock;

  address[] public userList;

  // Info of each user that stakes tokens (stakedToken)
  mapping(address => UserInfo) public userInfo;

  struct UserInfo {
    address addr; //address of user
    uint256 amount; // How many staked tokens the user has provided
    uint256 rewardDebt; // Reward debt
    bool registered; // it will add user in address list on first deposit
  }

  event AdminTokenRecovery(address tokenRecovered, uint256 amount);
  event Deposit(address indexed user, uint256 amount);
  event EmergencyWithdraw(address indexed user, uint256 amount);
  event NewStartAndEndBlocks(uint256 startBlock, uint256 endBlock);
  event NewRewardPerBlock(uint256 rewardPerBlock);
  event NewFreezeBlocks(uint256 freezeStartBlock, uint256 freezeEndBlock);
  event NewPoolLimit(uint256 poolLimitPerUser);
  event RewardsStop(uint256 blockNumber);
  event Withdraw(address indexed user, uint256 amount);
  event AddRewardTokens(address indexed user, uint256 amount);

  constructor() public {
    SMART_CHEF_FACTORY = msg.sender;
  }

  /*
   * @notice Initialize the contract
   * @param _stakedToken: staked token address
   * @param _rewardToken: reward token address
   * @param _rewardPerBlock: reward per block (in rewardToken)
   * @param _startBlock: start block
   * @param _bonusEndBlock: end block
   * @param _poolLimitPerUser: pool limit per user in stakedToken (if any, else 0)
   * @param _admin: admin address with ownership
   */
  function initialize(
    IERC20 _stakedToken,
    IERC20 _rewardToken,
    uint256 _rewardPerBlock,
    uint256 _startBlock,
    uint256 _bonusEndBlock,
    uint256 _poolLimitPerUser,
    address _admin
  ) external {
    require(!isInitialized, "Already initialized");
    require(msg.sender == SMART_CHEF_FACTORY, "Not factory");

    // Make this contract initialized
    isInitialized = true;

    stakedToken = _stakedToken;
    rewardToken = _rewardToken;
    rewardPerBlock = _rewardPerBlock;
    startBlock = _startBlock;
    bonusEndBlock = _bonusEndBlock;

    if (_poolLimitPerUser > 0) {
      hasUserLimit = true;
      poolLimitPerUser = _poolLimitPerUser;
    }

    uint256 decimalsRewardToken = uint256(rewardToken.decimals());
    require(decimalsRewardToken < 30, "Must be inferior to 30");

    PRECISION_FACTOR = uint256(10 ** (uint256(30).sub(decimalsRewardToken)));

    // Set the lastRewardBlock as the startBlock
    lastRewardBlock = startBlock;

    if(_admin != _msgSender()) {
      // Transfer ownership to the admin address who becomes owner of the contract
      transferOwnership(_admin);
    }
  }

  /*
   * @notice Deposit staked tokens and collect reward tokens (if any)
   * @param _amount: amount to withdraw (in rewardToken)
   */
  function deposit(uint256 _amount) external nonReentrant {
    require(isFrozen() == false, "deposit is frozen");
    UserInfo storage user = userInfo[msg.sender];

    if (hasUserLimit) {
      require(_amount.add(user.amount) <= poolLimitPerUser, "User amount above limit");
    }

    _updatePool();

    if (user.amount > 0) {
      uint256 pending = user.amount.mul(accTokenPerShare).div(PRECISION_FACTOR).sub(user.rewardDebt);
      if (pending > 0) {
        _safeRewardTransfer(address(msg.sender), pending);
      }
    } else {
      if (user.registered == false) {
        userList.push(msg.sender);
        user.registered = true;
        user.addr = address(msg.sender);
      }
    }

    if (_amount > 0) {
      user.amount = user.amount.add(_amount);
      stakedToken.safeTransferFrom(address(msg.sender), address(this), _amount);
      totalStakingTokens = totalStakingTokens.add(_amount);
    }

    user.rewardDebt = user.amount.mul(accTokenPerShare).div(PRECISION_FACTOR);

    emit Deposit(msg.sender, _amount);
  }

  /*
   * @notice Withdraw staked tokens and collect reward tokens
   * @param _amount: amount to withdraw (in rewardToken)
   */
  function withdraw(uint256 _amount) external nonReentrant {
    require(isFrozen() == false, "withdraw is frozen");

    UserInfo storage user = userInfo[msg.sender];
    require(user.amount >= _amount, "Amount to withdraw too high");

    _updatePool();

    uint256 pending = user.amount.mul(accTokenPerShare).div(PRECISION_FACTOR).sub(user.rewardDebt);

    if (_amount > 0) {
      user.amount = user.amount.sub(_amount);
      stakedToken.safeTransfer(address(msg.sender), _amount);
      totalStakingTokens = totalStakingTokens.sub(_amount);
    }

    if (pending > 0) {
      _safeRewardTransfer(address(msg.sender), pending);
    }

    user.rewardDebt = user.amount.mul(accTokenPerShare).div(PRECISION_FACTOR);

    emit Withdraw(msg.sender, _amount);
  }

  /*
   * @notice Withdraw staked tokens without caring about rewards rewards
   * @dev Needs to be for emergency.
   */
  function emergencyWithdraw() external nonReentrant {
    require(isFrozen() == false, "emergency withdraw is frozen");

    UserInfo storage user = userInfo[msg.sender];
    uint256 amountToTransfer = user.amount;
    user.amount = 0;
    user.rewardDebt = 0;

    if (amountToTransfer > 0) {
      stakedToken.safeTransfer(address(msg.sender), amountToTransfer);
      totalStakingTokens = totalStakingTokens.sub(amountToTransfer);
    }

    emit EmergencyWithdraw(msg.sender, user.amount);
  }

  /*
   * @notice return length of user addresses
   */
  function getUserListLength() external view returns (uint){
    return userList.length;
  }

  /*
   * @notice View function to get users.
   * @param _offset: offset for paging
   * @param _limit: limit for paging
   * @return get users, next offset and total users
   */
  function getUsersPaging(uint _offset, uint _limit) public view returns (UserInfo[] memory users, uint nextOffset, uint total) {
    uint totalUsers = userList.length;
    if (_limit == 0) {
      _limit = 1;
    }

    if (_limit > totalUsers - _offset) {
      _limit = totalUsers - _offset;
    }

    UserInfo[] memory values = new UserInfo[] (_limit);
    for (uint i = 0; i < _limit; i++) {
      values[i] = userInfo[userList[_offset + i]];
    }

    return (values, _offset + _limit, totalUsers);
  }

  /*
   * @notice isFrozed returns if contract is frozen, user cannot call deposit, withdraw, emergencyWithdraw function
   */
  function isFrozen() public view returns (bool){
    return block.number >= freezeStartBlock && block.number <= freezeEndBlock;
  }

  /*
   * @notice Stop rewards
   * @dev Only callable by owner. Needs to be for emergency.
   */
  function emergencyRewardWithdraw(uint256 _amount) external onlyOwner {
    totalRewardTokens = totalRewardTokens.sub(_amount);
    rewardToken.safeTransfer(address(msg.sender), _amount);
  }

  /**
   * @notice It allows the admin to reward tokens
   * @param _amount: amount of tokens
   * @dev This function is only callable by admin.
   */
  function addRewardTokens(uint256 _amount) external onlyOwner {
    totalRewardTokens = totalRewardTokens.add(_amount);
    rewardToken.safeTransferFrom(address(msg.sender), address(this), _amount);
    emit AddRewardTokens(msg.sender, _amount);
  }

  /**
   * @notice It allows the admin to recover wrong tokens sent to the contract
   * @param _tokenAddress: the address of the token to withdraw
   * @param _tokenAmount: the number of tokens to withdraw
   * @dev This function is only callable by admin.
   */
  function recoverWrongTokens(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
    require(_tokenAddress != address(stakedToken), "Cannot be staked token");
    require(_tokenAddress != address(rewardToken), "Cannot be reward token");

    IERC20(_tokenAddress).safeTransfer(address(msg.sender), _tokenAmount);

    emit AdminTokenRecovery(_tokenAddress, _tokenAmount);
  }

  /*
   * @notice Stop rewards
   * @dev Only callable by owner
   */
  function stopReward() external onlyOwner {
    bonusEndBlock = block.number;
  }

  /*
   * @notice Stop Freeze
   * @dev Only callable by owner
   */
  function stopFreeze() external onlyOwner {
    freezeStartBlock = 0;
    freezeEndBlock = 0;
  }

  /*
   * @notice Update pool limit per user
   * @dev Only callable by owner.
   * @param _hasUserLimit: whether the limit remains forced
   * @param _poolLimitPerUser: new pool limit per user
   */
  function updatePoolLimitPerUser(bool _hasUserLimit, uint256 _poolLimitPerUser) external onlyOwner {
    require(hasUserLimit, "Must be set");
    if (_hasUserLimit) {
      require(_poolLimitPerUser > poolLimitPerUser, "New limit must be higher");
      poolLimitPerUser = _poolLimitPerUser;
    } else {
      hasUserLimit = _hasUserLimit;
      poolLimitPerUser = 0;
    }
    emit NewPoolLimit(poolLimitPerUser);
  }

  /*
   * @notice Update reward per block
   * @dev Only callable by owner.
   * @param _rewardPerBlock: the reward per block
   */
  function updateRewardPerBlock(uint256 _rewardPerBlock) external onlyOwner {
    require(block.number < startBlock || block.number > bonusEndBlock, "Pool has started");
    rewardPerBlock = _rewardPerBlock;
    emit NewRewardPerBlock(_rewardPerBlock);
  }

  /**
   * @notice It allows the admin to update start and end blocks
   * @dev This function is only callable by owner.
   * @param _startBlock: the new start block
   * @param _bonusEndBlock: the new end block
   */
  function updateStartAndEndBlocks(uint256 _startBlock, uint256 _bonusEndBlock) external onlyOwner {
    require(block.number < startBlock || block.number > bonusEndBlock, "Pool has started");
    require(_startBlock < _bonusEndBlock, "New startBlock must be lower than new end block");
    require(block.number < _startBlock, "New startBlock must be higher than current block");

    startBlock = _startBlock;
    bonusEndBlock = _bonusEndBlock;

    // Set the lastRewardBlock as the startBlock
    lastRewardBlock = startBlock;

    emit NewStartAndEndBlocks(_startBlock, _bonusEndBlock);
  }

  /**
   * @notice It allows the admin to update freeze start and end blocks
   * @dev This function is only callable by owner.
   * @param _freezeStartBlock: the new freeze start block
   * @param _freezeEndBlock: the new freeze end block
   */
  function updateFreezaBlocks(uint256 _freezeStartBlock, uint256 _freezeEndBlock) external onlyOwner {
    require(_freezeStartBlock < _freezeEndBlock, "New freeze startBlock must be lower than new endBlock");
    require(block.number < _freezeStartBlock, "freeze start block must be higher than current block");

    freezeStartBlock = _freezeStartBlock;
    freezeEndBlock = _freezeEndBlock;
    emit NewFreezeBlocks(freezeStartBlock, freezeEndBlock);
  }

  /*
   * @notice View function to see pending reward on frontend.
   * @param _user: user address
   * @return Pending reward for a given user
   */
  function pendingReward(address _user) external view returns (uint256) {
    UserInfo storage user = userInfo[_user];
    uint256 stakedTokenSupply = totalStakingTokens;
    if (block.number > lastRewardBlock && stakedTokenSupply != 0) {
      uint256 multiplier = _getMultiplier(lastRewardBlock, block.number);
      uint256 cakeReward = multiplier.mul(rewardPerBlock);
      uint256 adjustedTokenPerShare =
      accTokenPerShare.add(cakeReward.mul(PRECISION_FACTOR).div(stakedTokenSupply));
      return user.amount.mul(adjustedTokenPerShare).div(PRECISION_FACTOR).sub(user.rewardDebt);
    } else {
      return user.amount.mul(accTokenPerShare).div(PRECISION_FACTOR).sub(user.rewardDebt);
    }
  }

  /*
   * @notice Update reward variables of the given pool to be up-to-date.
   */
  function _updatePool() internal {
    if (block.number <= lastRewardBlock) {
      return;
    }

    uint256 stakedTokenSupply = totalStakingTokens;

    if (stakedTokenSupply == 0) {
      lastRewardBlock = block.number;
      return;
    }

    uint256 multiplier = _getMultiplier(lastRewardBlock, block.number);
    uint256 cakeReward = multiplier.mul(rewardPerBlock);
    accTokenPerShare = accTokenPerShare.add(cakeReward.mul(PRECISION_FACTOR).div(stakedTokenSupply));
    lastRewardBlock = block.number;
  }

  /*
   * @notice Return reward multiplier over the given _from to _to block.
   * @param _from: block to start
   * @param _to: block to finish
   */
  function _getMultiplier(uint256 _from, uint256 _to) internal view returns (uint256) {
    if (_to <= bonusEndBlock) {
      return _to.sub(_from);
    } else if (_from >= bonusEndBlock) {
      return 0;
    } else {
      return bonusEndBlock.sub(_from);
    }
  }

  /*
   * @notice transfer reward tokens.
   * @param _to: address where tokens will transfer
   * @param _amount: amount of tokens
   */
  function _safeRewardTransfer(address _to, uint256 _amount) internal {
    uint256 rewardTokenBal = totalRewardTokens;
    if (_amount > rewardTokenBal) {
      totalRewardTokens = totalRewardTokens.sub(rewardTokenBal);
      rewardToken.safeTransfer(_to, rewardTokenBal);
    } else {
      totalRewardTokens = totalRewardTokens.sub(_amount);
      rewardToken.safeTransfer(_to, _amount);
    }

  }

}
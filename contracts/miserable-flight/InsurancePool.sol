// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../libraries/SafePRBMath.sol";

import "../lucky-box/interfaces/IDegisLottery.sol";

import "../utils/OwnableWithoutContext.sol";

import "./abstracts/InsurancePoolStore.sol";

/**
 * @title  Insurance Pool
 * @notice Insurance pool is the reserved risk pool for flight delay product.
 *         For simplicity, some state variables are in the InsurancePoolStore contract.
 */
contract InsurancePool is
    ERC20("Degis FlightDelay LPToken", "DLP"),
    InsurancePoolStore,
    OwnableWithoutContext,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    using SafePRBMath for uint256;

    // ---------------------------------------------------------------------------------------- //
    // *********************************** Other Contracts ************************************ //
    // ---------------------------------------------------------------------------------------- //

    IERC20 public USDToken;
    IDegisLottery public degisLottery;

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Constructor ************************************** //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Constructor function
     * @param _emergencyPool Emergency pool address
     * @param _degisLottery Lottery address
     * @param _usdAddress USDToken address
     */
    constructor(
        address _emergencyPool,
        address _degisLottery,
        address _usdAddress
    ) {
        // Initialize some factors
        collateralFactor = 1e18;
        lockedRatio = 1e18;
        LPValue = 1e18;

        emergencyPool = _emergencyPool;

        USDToken = IERC20(_usdAddress);

        degisLottery = IDegisLottery(_degisLottery);

        // Initial distribution, 0: LP 1: Lottery 2: Emergency
        rewardDistribution[0] = 50;
        rewardDistribution[1] = 40;
        rewardDistribution[2] = 10;

        frozenTime = 7 days;
        MAX_UNSTAKE_LENGTH = 50;
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************** Modifiers *************************************** //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Only the policyFlow contract can call some functions
     */
    modifier onlyPolicyFlow() {
        require(
            _msgSender() == policyFlow,
            "Only the policyFlow contract can call this function"
        );
        _;
    }

    /**
     * @notice The address can not be zero
     */
    modifier notZeroAddress(address _address) {
        require(_address != address(0), "Can not be zero address");
        _;
    }

    /**
     * @notice There is a frozen time for unstaking
     */
    modifier afterFrozenTime(address _user) {
        require(
            block.timestamp >= userInfo[_user].depositTime + frozenTime,
            "Can not withdraw until the fronzen time"
        );
        _;
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ View Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Get the real balance: LPValue * LP_Num
     * @dev Used in many places so give it a seperate function
     * @param _user User's address
     * @return _userBalance Real balance of this user
     */
    function getUserBalance(address _user)
        public
        view
        returns (uint256 _userBalance)
    {
        uint256 lp_num = balanceOf(_user);
        _userBalance = lp_num.mul(LPValue);
    }

    /**
     * @notice Get the balance that one user(LP) can unlock
     * @param _user User's address
     * @return _unlockedAmount Unlocked amount of the user
     */
    function getUnlockedFor(address _user)
        public
        view
        returns (uint256 _unlockedAmount)
    {
        uint256 userBalance = getUserBalance(_user);
        _unlockedAmount = availableCapacity >= userBalance
            ? userBalance
            : availableCapacity;
    }

    /**
     * @notice Check the conditions when receive new buying request
     * @param _payoff Payoff of the policy to be bought
     * @return Whether there is enough capacity in the pool for this payoff
     */
    function checkCapacity(uint256 _payoff) external view returns (bool) {
        return availableCapacity >= _payoff;
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Owner Functions *********************************** //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Set a new frozen time
     * @param _newFrozenTime New frozen time, in timestamp(s)
     */
    function setFrozenTime(uint256 _newFrozenTime) external onlyOwner {
        frozenTime = _newFrozenTime;
        emit FrozenTimeChanged(_newFrozenTime);
    }

    /**
     * @notice Set the address of policyFlow
     */
    function setPolicyFlow(address _policyFlowAddress)
        public
        onlyOwner
        notZeroAddress(_policyFlowAddress)
    {
        policyFlow = _policyFlowAddress;
        emit PolicyFlowChanged(_policyFlowAddress);
    }

    /**
     * @notice Set the premium reward distribution
     * @param _newDistribution New distribution [LP, Lottery, Emergency]
     */
    function setRewardDistribution(uint256[3] memory _newDistribution)
        public
        onlyOwner
    {
        uint256 sum = _newDistribution[0] +
            _newDistribution[1] +
            _newDistribution[2];
        require(sum == 100, "Reward distribution must sum to 100");

        for (uint256 i = 0; i < 3; i++) {
            rewardDistribution[i] = _newDistribution[i];
        }
        emit RewardDistributionChanged(
            _newDistribution[0],
            _newDistribution[1],
            _newDistribution[2]
        );
    }

    /**
     * @notice Change the collateral factor
     * @param _factor The new collateral factor
     */
    function setCollateralFactor(uint256 _factor) public onlyOwner {
        require(_factor > 0, "Collateral Factor should be larger than 0");
        uint256 oldFactor = collateralFactor;
        collateralFactor = _factor.div(100);
        emit CollateralFactorChanged(oldFactor, _factor);
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Main Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice LPs stake assets into the pool
     * @param _amount The amount that the user want to stake
     */
    function stake(uint256 _amount) external nonReentrant {
        require(
            IERC20(USDToken).balanceOf(_msgSender()) >= _amount && _amount > 0,
            "You do not have enough USD or input 0 amount"
        );

        _updateLPValue();

        _deposit(_msgSender(), _amount);
    }

    /**
     * @notice Unstake from the pool (May fail if a claim happens before this operation)
     * @dev Only unstake by yourself
     * @param _amount The amount that the user want to unstake
     */
    function unstake(uint256 _amount)
        external
        afterFrozenTime(_msgSender())
        nonReentrant
    {
        address _user = _msgSender();

        _updateLPValue();

        uint256 userBalance = getUserBalance(_user);
        require(
            _amount <= userBalance && _amount > 0,
            "Not enough balance to be unlocked or your withdraw amount is 0"
        );

        uint256 unlocked = totalStakingBalance - lockedBalance;
        uint256 unstakeAmount = _amount;

        // Will jump this part when the pool has enough liquidity
        if (_amount > unlocked) {
            require(
                unstakeQueue.length < MAX_UNSTAKE_LENGTH,
                "Unstake queue is full"
            );

            uint256 remainingURequest = _amount - unlocked;
            unstakeRequests[_user].push(
                UnstakeRequest(remainingURequest, 0, false)
            );
            unstakeQueue.push(_user);
            unstakeAmount = unlocked; // only withdraw the unlocked value
            userInfo[_user].pendingBalance += remainingURequest;

            // Update real staking balance
            realStakingBalance -= remainingURequest;
        }

        _withdraw(_user, unstakeAmount);
    }

    /**
     * @notice Unstake the max amount of a user
     */
    function unstakeMax() external afterFrozenTime(_msgSender()) nonReentrant {
        address _user = _msgSender();

        _updateLPValue();

        uint256 userBalance = getUserBalance(_user);

        uint256 unlocked = totalStakingBalance - lockedBalance;
        uint256 unstakeAmount = userBalance;

        // Will jump this part when the pool has enough liquidity
        if (userBalance > unlocked) {
            require(
                unstakeQueue.length < MAX_UNSTAKE_LENGTH,
                "Unstake queue is full"
            );

            uint256 remainingURequest = userBalance - unlocked;
            unstakeRequests[_user].push(
                UnstakeRequest(remainingURequest, 0, false)
            );
            unstakeQueue.push(_user);
            unstakeAmount = unlocked; // only withdraw the unlocked value
            userInfo[_user].pendingBalance += remainingURequest;

            // Update real staking balance
            realStakingBalance -= remainingURequest;
        }

        _withdraw(_user, unstakeAmount);
    }

    /**
     * @notice Update the pool variables when buying policies
     * @dev Capacity check is done before calling this function
     * @param _premium Policy's premium
     * @param _payoff Policy's payoff (max payoff)
     * @param _user Address of the buyer
     */
    function updateWhenBuy(
        uint256 _premium,
        uint256 _payoff,
        address _user
    ) external onlyPolicyFlow {
        // Update pool status
        lockedBalance += _payoff;
        activePremiums += _premium;
        availableCapacity -= _payoff;

        // Update lockedRatio
        _updateLockedRatio();

        // Remember approval
        USDToken.safeTransferFrom(_user, address(this), _premium);

        emit BuyNewPolicy(_user, _premium, _payoff);
    }

    /**
     * @notice Update the status when a policy expires
     * @param _premium Policy's premium
     * @param _payoff Policy's payoff (max payoff)
     */
    function updateWhenExpire(uint256 _premium, uint256 _payoff)
        external
        onlyPolicyFlow
    {
        // Distribute the premium
        uint256 remainingPremium = _distributePremium(_premium);

        // Update pool status
        activePremiums -= _premium;
        lockedBalance -= _payoff;

        availableCapacity += _payoff + remainingPremium;
        totalStakingBalance += remainingPremium;

        // If there is any unstake request in the queue
        uint256 remainingPayoff = _payoff;

        if (unstakeQueue.length > 0) {
            _dealUnstakeQueue(remainingPayoff);
        }

        _updateLPValue();
    }

    /**
     * @notice Pay a claim
     * @param _premium Premium of the policy
     * @param _payoff Max payoff of the policy
     * @param _realPayoff Real payoff of the policy
     * @param _user Address of the policy claimer
     */
    function payClaim(
        uint256 _premium,
        uint256 _payoff,
        uint256 _realPayoff,
        address _user
    ) external onlyPolicyFlow notZeroAddress(_user) {
        // Distribute the premium
        uint256 remainingPremium = _distributePremium(_premium);

        // Update the pool status
        lockedBalance -= _payoff;

        totalStakingBalance =
            totalStakingBalance -
            _realPayoff +
            remainingPremium;

        realStakingBalance =
            realStakingBalance -
            _realPayoff +
            remainingPremium;

        availableCapacity += (_payoff - _realPayoff + remainingPremium);

        activePremiums -= _premium;

        // Pay the claim
        USDToken.safeTransfer(_user, _realPayoff);

        _updateLPValue();
    }

    /**
     * @notice Revert the last unstake request for a user
     */
    function revertLatestUnstakeRequest() public {
        // Use memory for less gas
        UnstakeRequest[] memory userRequests = unstakeRequests[_msgSender()];

        require(userRequests.length > 0, "No pending unstake request");

        uint256 index = userRequests.length - 1;

        realStakingBalance += userRequests[index].pendingAmount;
        userInfo[_msgSender()].pendingBalance -= userRequests[index]
            .pendingAmount;

        _removeOneRequest(_msgSender());
    }

    /**
     * @notice revert all unstake requests for a user
     */
    function revertAllUnstakeRequest() public {
        require(
            unstakeRequests[_msgSender()].length > 0,
            "No pending unstake request"
        );

        _removeAllRequest(_msgSender());

        delete unstakeRequests[_msgSender()];

        uint256 remainingRequest = userInfo[_msgSender()].pendingBalance;

        realStakingBalance += remainingRequest;
        userInfo[_msgSender()].pendingBalance = 0;
    }

    // ---------------------------------------------------------------------------------------- //
    // ********************************** Internal Functions ********************************** //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Remove all unstake requests for a user
     * @param _user User's address
     */
    function _removeAllRequest(address _user) internal {
        uint256 length = unstakeRequests[_user].length;
        for (uint256 i = 0; i < length; i++) {
            // Remove the latest unstake request from the queue
            _removeOneRequest(_user);
        }
    }

    /**
     * @notice Remove one(the latest) unstake requests for a user
     * @param _user User's address
     */
    function _removeOneRequest(address _user) internal {
        uint256 index = unstakeQueue.length - 1;

        while (index >= 0) {
            if (unstakeQueue[index] == _user) break;
            index -= 1;
        }

        for (uint256 j = index; j < unstakeQueue.length - 1; j += 1) {
            unstakeQueue[j] = unstakeQueue[j + 1];
        }

        unstakeQueue.pop();
    }

    /**
     * @notice Finish the deposit process
     * @dev LPValue will not change during deposit
     * @param _user Address of the user who deposits
     * @param _amount Amount he deposits
     */
    function _deposit(address _user, uint256 _amount) internal {
        uint256 amountWithFactor = _amount.mul(collateralFactor);

        // Update the pool's status
        totalStakingBalance += _amount;
        realStakingBalance += _amount;
        availableCapacity += amountWithFactor;

        _updateLockedRatio();

        // msg.sender always pays
        USDToken.safeTransferFrom(_user, address(this), _amount);

        // LP Token number need to be newly minted
        uint256 lp_num = _amount.div(LPValue);
        _mint(_user, lp_num);

        userInfo[_user].depositTime = block.timestamp;

        emit Stake(_user, _amount);
    }

    /**
     * @notice _withdraw: finish the withdraw action, only when meeting the conditions
     * @dev LPValue will not change during withdraw
     * @param _user address of the user who withdraws
     * @param _amount the amount he withdraws
     */
    function _withdraw(address _user, uint256 _amount) internal {
        uint256 amountWithFactor = _amount.mul(collateralFactor);
        // Update the pool's status
        totalStakingBalance -= _amount;
        realStakingBalance -= _amount;
        availableCapacity -= amountWithFactor;

        _updateLockedRatio();

        USDToken.safeTransfer(_user, _amount);

        uint256 lp_num = _amount.div(LPValue);
        _burn(_user, lp_num);

        emit Unstake(_user, _amount);
    }

    /**
     * @notice Distribute the premium to lottery and emergency pool
     * @param _premium Premium amount to be distributed
     */
    function _distributePremium(uint256 _premium) internal returns (uint256) {
        uint256 premiumToLottery = _premium.mul(rewardDistribution[1].div(100));

        uint256 premiumToEmergency = _premium.mul(
            rewardDistribution[2].div(100)
        );

        // Transfer some reward to emergency pool
        USDToken.safeTransfer(emergencyPool, premiumToEmergency);

        // Transfer some reward to lottery
        // Check the allowance first
        if (
            USDToken.allowance(address(this), address(degisLottery)) <
            10000000 ether
        ) {
            USDToken.approve(address(degisLottery), type(uint256).max);
        }

        degisLottery.injectFunds(premiumToLottery);

        emit PremiumDistributed(premiumToEmergency, premiumToLottery);

        return _premium - premiumToEmergency - premiumToLottery;
    }

    /**
     * @notice Update the value of each lp token
     * @dev Normally it will update when claim or expire
     */
    function _updateLPValue() internal {
        uint256 totalLP = totalSupply();

        if (totalLP == 0) return;
        else {
            uint256 totalBalance = IERC20(USDToken).balanceOf(address(this));

            LPValue = (totalBalance - activePremiums).div(totalLP);
        }
    }

    /**
     * @notice Update the pool's locked ratio
     */
    function _updateLockedRatio() internal {
        if (lockedBalance == 0) lockedRatio = 0;
        else lockedRatio = lockedBalance.div(totalStakingBalance);
    }

    /**
     * @notice When some capacity unlocked, deal with the unstake queue
     * @dev Normally we do not need this process
     * @param remainingPayoff Remaining payoff amount
     */
    function _dealUnstakeQueue(uint256 remainingPayoff) internal {
        uint256 pendingAmount;
        for (uint256 i = unstakeQueue.length - 1; i >= 0; i -= 1) {
            if (remainingPayoff >= 0) {
                address pendingUser = unstakeQueue[i];
                for (
                    uint256 j = 0;
                    j < unstakeRequests[pendingUser].length;
                    j++
                ) {
                    pendingAmount = unstakeRequests[pendingUser][j]
                        .pendingAmount;
                    if (remainingPayoff > pendingAmount) {
                        remainingPayoff -= pendingAmount;

                        for (
                            uint256 k = 0;
                            k < unstakeRequests[pendingUser].length - 1;
                            k += 1
                        ) {
                            unstakeRequests[pendingUser][k] = unstakeRequests[
                                pendingUser
                            ][k + 1];
                        }
                        unstakeRequests[pendingUser].pop();

                        _withdraw(pendingUser, pendingAmount);
                    } else {
                        unstakeRequests[pendingUser][j]
                            .pendingAmount -= remainingPayoff;
                        unstakeRequests[pendingUser][j]
                            .fulfilledAmount += remainingPayoff;
                        _withdraw(pendingUser, remainingPayoff);

                        remainingPayoff = 0;
                        break;
                    }
                }
            } else break;
        }
    }
}

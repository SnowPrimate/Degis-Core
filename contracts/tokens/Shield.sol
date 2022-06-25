// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { IVeDEG } from "../governance/interfaces/IVeDEG.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ICurve } from "../interfaces/ICurve.sol";
import { IPTP } from "../interfaces/IPTP.sol";

/**
 * @title  Shield Token (Derived Stablecoin on Degis)
 * @author Eric Lee (ylikp.ust@gmail.com)
 * @dev    Users can swap other stablecoins to Shield
 *         Shield can be used in NaughtyPrice and future products
 *
 *         When users want to withdraw, their shield tokens will be burned
 *         and USDC will be sent back to them
 *
 *         Currently, the swap is done inside Platypus
 */
contract Shield is ERC20Upgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Constants **************************************** //
    // ---------------------------------------------------------------------------------------- //

    // PTP USD Pool to be used for swapping stablecoins
    address public PTP_POOL = 0x66357dCaCe80431aee0A7507e2E361B7e2402370;
    address public P_YUSD_POOL = 0xC828D995C686AaBA78A4aC89dfc8eC0Ff4C5be83;

    address public C_YUSD_USDC_USDT_POOL = 0x1da20Ac34187b2d9c74F729B85acB225D3341b25;
    address public C_USDC_eUSDC_POOL = 0x3a43A5851A3e3E0e25A3c1089670269786be1577;
    address public C_DAIe_USDCe_USDTe_POOL = 0xB755B949C126C04e0348DD881a5cF55d424742B2;

    


    // Constant stablecoin addresses
    address public constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address public constant USDCe = 0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664;
    address public constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    address public constant USDTe = 0xc7198437980c041c805A1EDcbA50c1Ce5db95118;
    address public constant DAIe = 0xd586E7F844cEa2F87f50152665BCbc2C279D8d70;
    address public constant YUSD = 0x111111111111ed1D73f860F57b2798b683f2d325;

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Variables **************************************** //
    // ---------------------------------------------------------------------------------------- //

    IVeDEG public veDEG;

    struct Stablecoin {
        bool isSupported;
        uint256 collateralRatio;
    }

    struct Target {
        address poolToUse;
        address toAddress;
        int128 fromIndex;
        int128 toIndex;
    }

    

    // stablecoin => whether supported
    mapping(address => bool) public supportedStablecoin;

    mapping(address => uint256) public users;
    // stablecoin => pool&address to use
    mapping(address => Target) public curveTarget;
    // yusd => c_yusd, 0, 1, USDC
    // usdt => c_yusd, 2, 1, USDC
    // eusdc => c_usdc, 0, 1, USDC
    // usdte => c_daie, 2, 1, USDCe
    // daie => c_daie, 0, 1, USDCe

    // ------------------------------------------------------------------------- --------------- //
    // *************************************** Events ***************************************** //
    // ---------------------------------------------------------------------------------------- //

    event AddStablecoin(address stablecoin);
    event SetPTPPool(address oldPool, address newPool);
    event Deposit(
        address indexed user,
        address indexed stablecoin,
        uint256 inAmount,
        uint256 outAmount
    );
    event Withdraw(address indexed user, uint256 amount);

    // ---------------------------------------------------------------------------------------- //
    // ************************************* Constructor ************************************** //
    // ---------------------------------------------------------------------------------------- //

    function initialize(address _veDEG) public initializer {
        __ERC20_init("Shield Token", "SHD");
        __Ownable_init();

        veDEG = IVeDEG(_veDEG);

        // USDT.e
        supportedStablecoin[USDTe] = true;
        // USDT
        supportedStablecoin[USDT] = true;
        // USDC.e
        supportedStablecoin[USDCe] = true;
        // USDC
        supportedStablecoin[USDC] = true;
        // DAI.e
        supportedStablecoin[DAIe] = true;
        // YUSD
        supportedStablecoin[YUSD] = true;


    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ View Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    function getCurveMinAmount(address _stablecoin, uint256 _amount) public view returns (uint256) {
        require(_stablecoin != address(0));
        require(supportedStablecoin[_stablecoin]);
        address stablecoin = _stablecoin;
        uint256 minAmount;
        while (stablecoin != USDC){
            minAmount = _getMinAmount(_stablecoin, _amount);
            stablecoin = curveTarget[stablecoin]._toAddress;
        }
        return minAmount;
    }

    function getPTPMinAmount(address _from, address _to, uint256 _amount) public view returns (uint256) {
        require(_from != address(0), "from address cannot be 0");
        require(_to != address(0), "to address cannot be 0");
        require(supportedStablecoin[_from], "from address is not supported");
        require(supportedStablecoin[_to],  "to address is not supported");
        (uint256 potentialOutcome, ) = IPTP(PTP_POOL).quotePotentialSwap(_from, _to, _amount);
        return potentialOutcome;
    }



    // ---------------------------------------------------------------------------------------- //
    // ************************************ Set Functions ************************************* //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Add new supported stablecoin
     *
     * @dev Set the token address and collateral ratio at the same time
     *      The collateral ratio need to be less than 100
     *      Only callable by the owner
     *
     * @param _stablecoin Stablecoin address
     */
    function addSupportedStablecoin(address _stablecoin)
        external
        onlyOwner
    {
        supportedStablecoin[_stablecoin] = true;
     
        emit AddStablecoin(_stablecoin);
    }

    function setPTPPool(address _ptpPool) external onlyOwner {
        emit SetPTPPool(PTPPOOL, _ptpPool);
        PTPPOOL = _ptpPool;
    }

    function setPTPYUSDPool(address _ptpYUSDPool) external onlyOwner {
        emit SetPTPPool(PTPYUSDPOOL, _ptpYUSDPool);
        PTPYUSDPOOL = _ptpYUSDPool;
    }

    function setCurvePool(address _curvePool) external onlyOwner {
        emit SetCurvePool(CURVEPOOL, _curvePool);
        CURVEPOOL = _curvePool;
    }

    function addCurvePool(
        address _stablecoin,
        address _poolToUse,
        address _toAddress,
        int128 _fromIndex,
        int128 _toIndex
        ) external onlyOwner {
            curveTarget[_stablecoin] = Target(_poolToUse, _toAddress, _fromIndex, _toIndex);
    }

    /**
     * @notice Get discount by veDEG
     * @dev The discount depends on veDEG
     * @return discount The discount for the user
     */
    function _getDiscount() internal view returns (uint256) {
        uint256 balance = veDEG.balanceOf(msg.sender);
        return balance;
    }

    function approveStablecoin(address _token) external {
        IERC20(_token).approve(PTPPOOL, type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------- //
    // ************************************ Main Functions ************************************ //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Deposit tokens and mint Shield
     * @param _stablecoin Stablecoin address
     * @param _amount     Input stablecoin amount
     * @param _minAmount  Minimum amount output (if need swap)
     */
    function deposit(
        address _stablecoin,
        bool _curve,
        uint256 _amount,
        uint256 _minAmount
    ) external {
        require(supportedStablecoin[_stablecoin], "Stablecoin not supported");

        // Actual shield amount
        uint256 outAmount;

        // Collateral ratio
        uint256 inAmount = _amount;

        // Transfer stablecoin to this contract
        // Transfer to this, no need for safeTransferFrom
        IERC20(_stablecoin).safeTransferFrom(msg.sender, address(this), _amount);


        if (_stablecoin != USDC) {
            if (_curve) {
                outAmount = _curveSwap(_stablecoin, _amount, _minToAmount);
            } else {
            // Swap stablecoin to USDC and directly goes to this contract
            outAmount = _swap (
                _stablecoin,
                USDC,
                _curve,
                inAmount,
                _minAmount,
                address(this),
                block.timestamp + 60
            );
            }
        } else {
            outAmount = inAmount;
        }

        // Record user balance
        users[msg.sender] += outAmount;

        // Mint shield
        _mint(msg.sender, outAmount);

        emit Deposit(msg.sender, _stablecoin, _amount, outAmount);
    }

    /**
     * @notice Withdraw stablecoins
     * @param _amount Amount of Shield to be burned
     */
    function withdraw(uint256 _amount) public {
        require(users[msg.sender] >= _amount, "Insufficient balance");
        users[msg.sender] -= _amount;

        // Transfer USDC back
        uint256 realAmount = _safeTokenTransfer(USDC, _amount);

        // Burn shield token
        _burn(msg.sender, realAmount);

        // Transfer USDC back
        IERC20(USDC).safeTransfer(msg.sender, _amount);

        emit Withdraw(msg.sender, realAmount);
    }

    /**
     * @notice Withdraw all stablecoins
     */
    function withdrawAll() external {
        require(users[msg.sender] > 0, "Insufficient balance");
        withdraw(users[msg.sender]);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // ---------------------------------------------------------------------------------------- //
    // *********************************** Internal Functions ********************************* //
    // ---------------------------------------------------------------------------------------- //

    /**
     * @notice Swap stablecoin to USDC in PTP
     * @param _fromToken   From token address
     * @param _toToken     To token address
     * @param _fromAmount  Amount of from token
     * @param _minToAmount Minimun output amount
     * @param _to          Address that will receive the output token
     * @param _deadline    Deadline for this transaction
     */
    function _swap(
        address _fromToken,
        address _toToken,
        uint256 _fromAmount,
        uint256 _minToAmount,
        address _to,
        uint256 _deadline
    ) internal returns (uint256) {
        bytes memory data = abi.encodeWithSignature(
        "swap(address,address,uint256,uint256,address,uint256)",
        _fromToken,
        _toToken,
        _fromAmount,
        _minToAmount,
        _to,
        _deadline
        );

        if (_fromToken == YUSD){
            (bool success, bytes memory res) = P_YUSD_POOL.call(data);
        } else {
            (bool success, bytes memory res) = PTPPOOL.call(data);
        }
        
        require(success, "swap failed");

        (uint256 actualAmount, ) = abi.decode(res, (uint256, uint256));

        return actualAmount;
    }

    function _curveSwap(
        address _fromToken,
        uint256 _fromAmount,
        uint256 _minToAmount
    ) internal returns (uint256) {
        int128 i = curveTarget[_fromToken].fromIndex;
        int128 j = curveTarget[_fromToken].toIndex;

        bytes memory data = abi.encodeWithSignature(
            "exchange(int128,int128,uint256,uint256)",
            i,
            j,
            _fromAmount,
            _minToAmount
        );

        (bool success, bytes memory res) = curveTarget[_fromToken].poolToUse.call(data);
        require(success, "swap failed");
        (uint256 actualAmount, ) = abi.decode(res, (uint256, uint256));
        if (curveTarget[_fromToken].toAddress != USDC) {
            uint256 min = _getMinAmount(curveTarget[_fromToken].toAddress);
            _curveSwap(curveTarget[_fromToken].toAddress,  actualAmount, min);
        }
        return actualAmount;
    }

    function _getMinAmount(address _fromAddress, uint256 _amount) internal view returns(uint256) {
        int128 i = curveTarget[_fromToken].fromIndex;
        int128 j = curveTarget[_fromToken].toIndex;
        uint256 expected = curveTarget[_fromAddress].poolToUse.get_dy(i, j, _amount) * 0.99;
        return expected;
    }

    /**
     * @notice Safe token transfer
     * @dev Not allowed to transfer more tokens than the current balance
     * @param _token  Token address to be transferred
     * @param _amount Amount of token to be transferred
     * @return realAmount Real amount that has been transferred
     */
    function _safeTokenTransfer(address _token, uint256 _amount)
        internal
        returns (uint256 realAmount)
    {
        uint256 balance = IERC20(_token).balanceOf(address(this));

        if (balance > _amount) {
            realAmount = _amount;
        } else {
            realAmount = balance;
        }
        IERC20(_token).safeTransfer(msg.sender, realAmount);
    }
}

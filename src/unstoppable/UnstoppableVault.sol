// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Owned} from "solmate/auth/Owned.sol";
import {SafeTransferLib, ERC4626, ERC20} from "solmate/tokens/ERC4626.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156.sol";

/**
 * An ERC4626-compliant tokenized vault offering flashloans for a fee.
 * An owner can pause the contract and execute arbitrary changes.
 */
contract UnstoppableVault is IERC3156FlashLender, ReentrancyGuard, Owned, ERC4626, Pausable {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    uint256 public constant FEE_FACTOR = 0.05 ether; // @ques 5%?
    uint64 public constant GRACE_PERIOD = 30 days; // @ques Some period, don't know what

    uint64 public immutable end = uint64(block.timestamp) + GRACE_PERIOD; // @ques Some kind of end_time, wait...it's uint64? @note But this doesn't seem to be an issue tho, as it will be a damn long time to get the block.timestamp to even on the max value of uint64

    address public feeRecipient; // Probably an address to receive fees

    error InvalidAmount(uint256 amount);
    error InvalidBalance();
    error CallbackFailed();
    error UnsupportedCurrency();

    event FeeRecipientUpdated(address indexed newFeeRecipient);

    constructor(ERC20 _token, address _owner, address _feeRecipient)
        ERC4626(_token, "Too Damn Valuable Token", "tDVT")
        Owned(_owner)
    {
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    /**
     * @inheritdoc IERC3156FlashLender
     */
    function maxFlashLoan(address _token) public view nonReadReentrant returns (uint256) {
        if (address(asset) != _token) { // Here asset means the ERC20 tokens in the vault (ERC4626)
            return 0;
        }

        return totalAssets();
    }

    /**
     * @inheritdoc IERC3156FlashLender
     */
    function flashFee(address _token, uint256 _amount) public view returns (uint256 fee) {
        if (address(asset) != _token) {
            revert UnsupportedCurrency();
        }

        if (block.timestamp < end && _amount < maxFlashLoan(_token)) { // @note block.timestamp uint256 is compared to `end` which is originally uint64, and is now converted to uint256
            return 0; // @note If someone tries to get the flashloan fee before the end of the grace period, the fee is 0
        } else {
            return _amount.mulWadUp(FEE_FACTOR);
        }
    }

    /**
     * @inheritdoc ERC4626
     */
    function totalAssets() public view override nonReadReentrant returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /**
     * @inheritdoc IERC3156FlashLender
     */
    function flashLoan(IERC3156FlashBorrower receiver, address _token, uint256 amount, bytes calldata data)
        external
        returns (bool)
    {
        if (amount == 0) revert InvalidAmount(0); // fail early
        if (address(asset) != _token) revert UnsupportedCurrency(); // enforce ERC3156 requirement
        uint256 balanceBefore = totalAssets();
        if (convertToShares(totalSupply) != balanceBefore) revert InvalidBalance(); // enforce ERC4626 requirement  // @audit feels like `convertToAssets` be used here. However, I am quite skeptical about that. But one more thing, it reverts if the totalAssets (i.e. the balance of ERC20 tokens in the vault) is not equal to the totalSupply (i.e. the combined value of shares in this vault after converting into assets). This mean, if anyone supplied some ERC20 tokens into this vault, then the revert chances are high

        // transfer tokens out + execute callback on receiver
        ERC20(_token).safeTransfer(address(receiver), amount);

        // callback must return magic value, otherwise assume it failed
        uint256 fee = flashFee(_token, amount);
        if (
            receiver.onFlashLoan(msg.sender, address(asset), amount, fee, data)
                != keccak256("IERC3156FlashBorrower.onFlashLoan")
        ) {
            revert CallbackFailed();
        }

        // pull amount + fee from receiver, then pay the fee to the recipient
        ERC20(_token).safeTransferFrom(address(receiver), address(this), amount + fee);
        ERC20(_token).safeTransfer(feeRecipient, fee);

        return true;
    }

    /**
     * @inheritdoc ERC4626
     */
    function beforeWithdraw(uint256 assets, uint256 shares) internal override nonReentrant {}

    /**
     * @inheritdoc ERC4626
     */
    function afterDeposit(uint256 assets, uint256 shares) internal override nonReentrant whenNotPaused {}

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        if (_feeRecipient != address(this)) {
            feeRecipient = _feeRecipient;
            emit FeeRecipientUpdated(_feeRecipient);
        }
    }

    // Allow owner to execute arbitrary changes when paused
    function execute(address target, bytes memory data) external onlyOwner whenPaused {
        (bool success,) = target.delegatecall(data);
        require(success);
    }

    // Allow owner pausing/unpausing this contract
    function setPause(bool flag) external onlyOwner {
        if (flag) _pause();
        else _unpause();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {
    AdminAlreadyAssigned,
    AlreadyVotedToSlash,
    CannotVoteForSelf,
    ClaimNotReady,
    CommissionExceedsMaxAllowed,
    CommissionRateTooHigh,
    InvalidAmount,
    InvalidUpdateType,
    NativeTransferFailed,
    NoPendingAdmin,
    NoPendingClaim,
    NotActive,
    NotPendingAdmin,
    NotValidatorAdmin,
    PendingClaimExists,
    SlashConditionsNotMet,
    SlashVoteDurationTooLong,
    SlashVoteExpired,
    TokenDoesNotExist,
    TooManyStakers,
    TreasuryNotSet,
    UnanimityNotReached,
    Unauthorized,
    ValidatorAlreadyExists,
    ValidatorAlreadySlashed,
    ValidatorDoesNotExist,
    ValidatorInactive,
    ZeroAddress
} from "../lib/PlumeErrors.sol";
import {
    AdminProposed,
    CommissionClaimFinalized,
    CommissionClaimRequested,
    SlashVoteCast,
    ValidatorAdded,
    ValidatorAddressesSet,
    ValidatorCapacityUpdated,
    ValidatorCommissionClaimed,
    ValidatorCommissionSet,
    ValidatorSlashed,
    ValidatorStatusUpdated,
    ValidatorUpdated
} from "../lib/PlumeEvents.sol";

import { PlumeRewardLogic } from "../lib/PlumeRewardLogic.sol";
import { PlumeStakingStorage } from "../lib/PlumeStakingStorage.sol";

import { OwnableInternal } from "@solidstate/access/ownable/OwnableInternal.sol";
import { OwnableStorage } from "@solidstate/access/ownable/OwnableStorage.sol";
import { DiamondBaseStorage } from "@solidstate/proxy/diamond/base/DiamondBaseStorage.sol";

import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IAccessControl } from "../interfaces/IAccessControl.sol";

import { IPlumeStakingRewardTreasury } from "../interfaces/IPlumeStakingRewardTreasury.sol";
import { PlumeRoles } from "../lib/PlumeRoles.sol";
import { RewardsFacet } from "./RewardsFacet.sol";
/**
 * @title ValidatorFacet
 * @author Eugene Y. Q. Shen, Alp Guneysel
 * @notice Facet handling validator management: adding, updating, commission, capacity.
 */

contract ValidatorFacet is ReentrancyGuardUpgradeable, OwnableInternal {

    struct ValidatorListData {
        uint16 id;
        uint256 totalStaked;
        uint256 commission;
    }

    using SafeERC20 for IERC20;
    using Address for address payable;
    using PlumeStakingStorage for PlumeStakingStorage.Layout;
    using SafeCast for uint256;

    // Modifier for Validator Admin checks
    modifier onlyValidatorAdmin(
        uint16 validatorId
    ) {
        // Use PlumeStakingStorage.layout() directly
        if (!PlumeStakingStorage.layout().validatorExists[validatorId]) {
            revert ValidatorDoesNotExist(validatorId);
        }
        if (msg.sender != PlumeStakingStorage.layout().validators[validatorId].l2AdminAddress) {
            revert NotValidatorAdmin(msg.sender);
        }
        _;
    }

    // --- Modifiers ---

    /**
     * @dev Modifier to check role using the AccessControlFacet.
     */
    modifier onlyRole(
        bytes32 _role
    ) {
        if (!IAccessControl(address(this)).hasRole(_role, msg.sender)) {
            revert Unauthorized(msg.sender, _role);
        }
        _;
    }

    /**
     * @dev Modifier to check if a validator exists.
     */
    modifier _validateValidatorExists(
        uint16 validatorId
    ) {
        if (!PlumeStakingStorage.layout().validatorExists[validatorId]) {
            revert ValidatorDoesNotExist(validatorId);
        }
        _;
    }

    modifier _validateIsToken(
        address token
    ) {
        if (!PlumeStakingStorage.layout().isRewardToken[token]) {
            revert TokenDoesNotExist(token);
        }
        _;
    }

    // --- Validator Management (Owner/Admin) ---

    /**
     * @notice Add a new validator (Owner only)
     * @param validatorId UUID for the validator
     * @param commission Commission rate (as fraction of REWARD_PRECISION)
     * @param l2AdminAddress Admin address for the validator
     * @param l2WithdrawAddress Withdrawal address for validator rewards
     * @param l1ValidatorAddress Address of validator on L1 (informational)
     * @param l1AccountAddress Address of account on L1 (informational)
     * @param l1AccountEvmAddress EVM address of account on L1 (informational)
     */
    function addValidator(
        uint16 validatorId,
        uint256 commission,
        address l2AdminAddress,
        address l2WithdrawAddress,
        string calldata l1ValidatorAddress,
        string calldata l1AccountAddress,
        address l1AccountEvmAddress,
        uint256 maxCapacity
    ) external onlyRole(PlumeRoles.VALIDATOR_ROLE) {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();

        if ($.validatorExists[validatorId]) {
            revert ValidatorAlreadyExists(validatorId);
        }
        if (l2AdminAddress == address(0)) {
            revert ZeroAddress("l2AdminAddress");
        }
        if (l2WithdrawAddress == address(0)) {
            revert ZeroAddress("l2WithdrawAddress");
        }

        // Check against the system-wide maximum allowed commission.
        // maxAllowedValidatorCommission defaults to 0 if not set by admin.
        // If it's 0, any commission > 0 will fail, forcing admin to set a rate.
        // The setter for maxAllowedValidatorCommission ensures it's <= REWARD_PRECISION / 2 (50%).
        if (commission > $.maxAllowedValidatorCommission) {
            revert CommissionExceedsMaxAllowed(commission, $.maxAllowedValidatorCommission);
        }

        // Check if admin address is already assigned using the dedicated mapping
        if ($.isAdminAssigned[l2AdminAddress]) {
            revert AdminAlreadyAssigned(l2AdminAddress);
        }

        PlumeStakingStorage.ValidatorInfo storage validator = $.validators[validatorId];
        validator.validatorId = validatorId;
        validator.commission = commission;
        validator.delegatedAmount = 0;
        validator.l2AdminAddress = l2AdminAddress;
        validator.l2WithdrawAddress = l2WithdrawAddress;
        validator.l1ValidatorAddress = l1ValidatorAddress;
        validator.l1AccountAddress = l1AccountAddress;
        validator.l1AccountEvmAddress = l1AccountEvmAddress;
        validator.active = true;
        validator.slashed = false;
        validator.maxCapacity = maxCapacity;

        $.validatorIds.push(validatorId);
        $.validatorExists[validatorId] = true;
        // Add admin to ID mapping
        $.adminToValidatorId[l2AdminAddress] = validatorId;
        // Mark admin as assigned in the dedicated mapping
        $.isAdminAssigned[l2AdminAddress] = true;

        // Initialize last update times and create initial checkpoints for all reward tokens
        address[] memory rewardTokens = $.rewardTokens;
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            $.validatorLastUpdateTimes[validatorId][token] = block.timestamp;
            // The validator inherits the current global rate for this token.
            uint256 currentGlobalRate = $.rewardRates[token];
            PlumeRewardLogic.createRewardRateCheckpoint($, token, validatorId, currentGlobalRate);
        }

        emit ValidatorAdded(
            validatorId,
            commission,
            l2AdminAddress,
            l2WithdrawAddress,
            l1ValidatorAddress,
            l1AccountAddress,
            l1AccountEvmAddress
        );
    }

    /**
     * @notice Set the maximum capacity for a validator (Owner only)
     * @param validatorId ID of the validator
     * @param maxCapacity New maximum capacity
     */
    function setValidatorCapacity(
        uint16 validatorId,
        uint256 maxCapacity
    ) external onlyRole(PlumeRoles.VALIDATOR_ROLE) _validateValidatorExists(validatorId) {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();
        PlumeStakingStorage.ValidatorInfo storage validator = $.validators[validatorId];

        // Check if validator is active and not slashed
        if (!validator.active || validator.slashed) {
            revert ValidatorInactive(validatorId);
        }

        uint256 oldCapacity = validator.maxCapacity;
        validator.maxCapacity = maxCapacity;

        emit ValidatorCapacityUpdated(validatorId, oldCapacity, maxCapacity);
    }

    /**
     * @notice Set the active/inactive status for a validator
     * @dev Caller must have ADMIN_ROLE.
     * @param validatorId ID of the validator
     * @param newActiveStatus The desired active status (true for active, false for inactive)
     */
    function setValidatorStatus(
        uint16 validatorId,
        bool newActiveStatus
    ) external onlyRole(PlumeRoles.ADMIN_ROLE) _validateValidatorExists(validatorId) {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();
        PlumeStakingStorage.ValidatorInfo storage validator = $.validators[validatorId];

        // Prevent activating an already slashed validator through this function
        if (newActiveStatus && validator.slashed) {
            revert ValidatorAlreadySlashed(validatorId);
        }

        bool currentStatus = validator.active;

        // If status is actually changing
        if (currentStatus != newActiveStatus) {
            address[] memory rewardTokens = $.rewardTokens;

            // If going INACTIVE: settle validator commission and record timestamp
            if (!newActiveStatus && currentStatus) {
                // Settle commission for validator using current rates
                PlumeRewardLogic._settleCommissionForValidatorUpToNow($, validatorId);

                // Record when the validator became inactive (reuse slashedAtTimestamp field)
                // This allows existing reward logic to cap rewards at this timestamp
                validator.slashedAtTimestamp = block.timestamp;

                // Create a zero-rate checkpoint for all reward tokens to signal inactivity start
                for (uint256 i = 0; i < rewardTokens.length; i++) {
                    PlumeRewardLogic.createRewardRateCheckpoint($, rewardTokens[i], validatorId, 0);
                }

                // NOTE: User rewards will be settled naturally when users interact
                // (stake, unstake, claim, etc.) due to the timestamp cap in reward logic
            }

            // Update the status
            validator.active = newActiveStatus;

            // If going ACTIVE: reset timestamps and clear the timestamp cap
            if (newActiveStatus && !currentStatus) {
                // Create a new checkpoint to restore the reward rate, signaling activity resumes
                for (uint256 i = 0; i < rewardTokens.length; i++) {
                    address token = rewardTokens[i];
                    $.validatorLastUpdateTimes[validatorId][token] = block.timestamp;
                    uint256 currentGlobalRate = $.rewardRates[token];
                    PlumeRewardLogic.createRewardRateCheckpoint($, token, validatorId, currentGlobalRate);
                }
                // Clear the timestamp since validator is active again (unless actually slashed)
                if (!validator.slashed) {
                    validator.slashedAtTimestamp = 0;
                }
            }
        }

        emit ValidatorStatusUpdated(validatorId, newActiveStatus, validator.slashed);
    }

    /**
     * @notice Set the commission rate for a specific validator.
     * @dev Caller must be the l2AdminAddress for the validator.
     *      Triggers reward updates for stakers and creates a commission checkpoint.
     * @param validatorId ID of the validator to update.
     * @param newCommission The new commission rate (scaled by 1e18).
     */
    function setValidatorCommission(
        uint16 validatorId,
        uint256 newCommission
    ) external onlyValidatorAdmin(validatorId) {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();
        PlumeStakingStorage.ValidatorInfo storage validator = $.validators[validatorId];

        // Check if validator is active and not slashed
        if (!validator.active || validator.slashed) {
            revert ValidatorInactive(validatorId);
        }

        // Check against the system-wide maximum allowed commission.
        if (newCommission > $.maxAllowedValidatorCommission) {
            revert CommissionExceedsMaxAllowed(newCommission, $.maxAllowedValidatorCommission);
        }

        uint256 oldCommission = validator.commission;

        // If the commission rate is the same, there's nothing to do.
        if (oldCommission == newCommission) {
            return;
        }

        // Settle commissions accrued with the old rate up to this point.
        PlumeRewardLogic._settleCommissionForValidatorUpToNow($, validatorId);

        // Now update the validator's commission rate to the new rate.
        validator.commission = newCommission;

        // Create a checkpoint for the new commission rate.
        // This records the new rate effective from this block.timestamp.
        PlumeRewardLogic.createCommissionRateCheckpoint($, validatorId, newCommission);

        emit ValidatorCommissionSet(validatorId, oldCommission, newCommission);
    }

    /**
     * @notice Set various addresses associated with a validator.
     * @dev Caller must be the l2AdminAddress for the validator.
     *      Updates are optional: pass address(0) or "" to keep the current value.
     * @param validatorId ID of the validator to update.
     * @param newL2AdminAddress The new admin address (or address(0) to keep current).
     * @param newL2WithdrawAddress The new withdraw address (or address(0) to keep current).
     * @param newL1ValidatorAddress The new L1 validator address string (or "" to keep current).
     * @param newL1AccountAddress The new L1 account address string (or "" to keep current).
     * @param newL1AccountEvmAddress The new L1 account EVM address (or address(0) to keep current).
     */
    function setValidatorAddresses(
        uint16 validatorId,
        address newL2AdminAddress,
        address newL2WithdrawAddress,
        string calldata newL1ValidatorAddress,
        string calldata newL1AccountAddress,
        address newL1AccountEvmAddress
    ) external onlyValidatorAdmin(validatorId) {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();
        PlumeStakingStorage.ValidatorInfo storage validator = $.validators[validatorId];

        // Check if validator is active and not slashed
        if (!validator.active || validator.slashed) {
            revert ValidatorInactive(validatorId);
        }

        address oldL2AdminAddress = validator.l2AdminAddress;
        address oldL2WithdrawAddress = validator.l2WithdrawAddress;
        string memory oldL1ValidatorAddress = validator.l1ValidatorAddress;
        string memory oldL1AccountAddress = validator.l1AccountAddress;
        address oldL1AccountEvmAddress = validator.l1AccountEvmAddress;

        // Update L2 Admin Address if provided and different
        if (newL2AdminAddress != address(0) && newL2AdminAddress != validator.l2AdminAddress) {
            // This now becomes a proposal, not a direct change.
            // The check for whether the new admin is already assigned moves to acceptAdmin.
            $.pendingAdmins[validatorId] = newL2AdminAddress;
            emit AdminProposed(validatorId, newL2AdminAddress);
        }

        // Update L2 Withdraw Address if provided and different
        if (newL2WithdrawAddress != address(0) && newL2WithdrawAddress != validator.l2WithdrawAddress) {
            if (newL2WithdrawAddress == address(0)) {
                // Add specific check for zero address
                revert ZeroAddress("newL2WithdrawAddress");
            }
            validator.l2WithdrawAddress = newL2WithdrawAddress;
        }

        // Update L1 Validator Address string if provided
        if (bytes(newL1ValidatorAddress).length > 0) {
            validator.l1ValidatorAddress = newL1ValidatorAddress;
        }

        // Update L1 Account Address string if provided
        if (bytes(newL1AccountAddress).length > 0) {
            validator.l1AccountAddress = newL1AccountAddress;
        }

        // Update L1 Account EVM Address if provided
        // No need to check for zero address here, as address(0) might be valid representation
        if (newL1AccountEvmAddress != address(0)) {
            validator.l1AccountEvmAddress = newL1AccountEvmAddress;
        }

        // Emit the correct event with old and new values
        // Note: The newL2AdminAddress in this event will reflect the *current* admin,
        // as the change is now pending and not yet effective.
        emit ValidatorAddressesSet(
            validatorId,
            oldL2AdminAddress,
            validator.l2AdminAddress, // This remains the old admin until accepted
            oldL2WithdrawAddress,
            validator.l2WithdrawAddress,
            oldL1ValidatorAddress,
            validator.l1ValidatorAddress,
            oldL1AccountAddress,
            validator.l1AccountAddress,
            oldL1AccountEvmAddress,
            validator.l1AccountEvmAddress
        );
    }

    /**
     * @notice Allows a proposed new admin to accept the admin role for a validator.
     * @dev Completes the two-step admin transfer process initiated by `setValidatorAddresses`.
     * @param validatorId The ID of the validator for which to accept the admin role.
     */
    function acceptAdmin(
        uint16 validatorId
    ) external nonReentrant _validateValidatorExists(validatorId) {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();
        address newAdmin = msg.sender;

        // Check 1: There must be a pending admin for this validator.
        address pendingAdmin = $.pendingAdmins[validatorId];
        if (pendingAdmin == address(0)) {
            revert NoPendingAdmin(validatorId);
        }

        // Check 2: The caller must be the designated pending admin.
        if (newAdmin != pendingAdmin) {
            revert NotPendingAdmin(newAdmin, validatorId);
        }

        // Check 3: The new admin cannot already be assigned to another validator.
        if ($.isAdminAssigned[newAdmin]) {
            revert AdminAlreadyAssigned(newAdmin);
        }

        PlumeStakingStorage.ValidatorInfo storage validator = $.validators[validatorId];
        address oldAdmin = validator.l2AdminAddress;

        // Finalize the change
        validator.l2AdminAddress = newAdmin;

        // Update admin tracking mappings
        delete $.adminToValidatorId[oldAdmin];
        $.adminToValidatorId[newAdmin] = validatorId;
        $.isAdminAssigned[oldAdmin] = false;
        $.isAdminAssigned[newAdmin] = true;

        // Clear the pending admin
        delete $.pendingAdmins[validatorId];

        // Emit the final event showing the successful change
        emit ValidatorAddressesSet(
            validatorId,
            oldAdmin,
            newAdmin,
            validator.l2WithdrawAddress, // Unchanged
            validator.l2WithdrawAddress, // Unchanged
            validator.l1ValidatorAddress, // Unchanged
            validator.l1ValidatorAddress, // Unchanged
            validator.l1AccountAddress, // Unchanged
            validator.l1AccountAddress, // Unchanged
            validator.l1AccountEvmAddress, // Unchanged
            validator.l1AccountEvmAddress // Unchanged
        );
    }

    /**
     * @notice Request a commission claim for a validator and token (starts timelock)
     * @dev Only callable by validator admin. Amount is locked at request time.
     */
    function requestCommissionClaim(
        uint16 validatorId,
        address token
    )
        external
        onlyValidatorAdmin(validatorId)
        nonReentrant
        _validateValidatorExists(validatorId)
        _validateIsToken(token)
    {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();
        PlumeStakingStorage.ValidatorInfo storage validator = $.validators[validatorId];

        if (!validator.active || validator.slashed) {
            revert ValidatorInactive(validatorId);
        }

        // Settle commission up to now to ensure accurate amount
        PlumeRewardLogic._settleCommissionForValidatorUpToNow($, validatorId);

        uint256 amount = $.validatorAccruedCommission[validatorId][token];
        if (amount == 0) {
            revert InvalidAmount(0);
        }
        if ($.pendingCommissionClaims[validatorId][token].amount > 0) {
            revert PendingClaimExists(validatorId, token);
        }
        address recipient = validator.l2WithdrawAddress;
        uint256 nowTs = block.timestamp;
        $.pendingCommissionClaims[validatorId][token] = PlumeStakingStorage.PendingCommissionClaim({
            amount: amount,
            requestTimestamp: nowTs,
            token: token,
            recipient: recipient
        });
        // Zero out accrued commission immediately
        $.validatorAccruedCommission[validatorId][token] = 0;

        emit CommissionClaimRequested(validatorId, token, recipient, amount, nowTs);
    }

    /**
     * @notice Finalize a commission claim after timelock expires
     * @dev Only callable by validator admin. Pays out the pending claim if ready.
     */
    function finalizeCommissionClaim(
        uint16 validatorId,
        address token
    ) external onlyValidatorAdmin(validatorId) nonReentrant returns (uint256) {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();
        PlumeStakingStorage.ValidatorInfo storage validator = $.validators[validatorId];

        PlumeStakingStorage.PendingCommissionClaim storage claim = $.pendingCommissionClaims[validatorId][token];

        if (claim.amount == 0) {
            revert NoPendingClaim(validatorId, token);
        }

        uint256 readyTimestamp = claim.requestTimestamp + PlumeStakingStorage.COMMISSION_CLAIM_TIMELOCK;

        // First, check if the timelock has passed from the perspective of the current block.
        if (block.timestamp < readyTimestamp) {
            revert ClaimNotReady(validatorId, token, readyTimestamp);
        }

        // --- REVISED SLASHING CHECK ---
        // If the validator is slashed, the claim is only considered valid if its timelock was
        // fully completed BEFORE the slash occurred. This invalidates any pending claims.
        if (validator.slashed && readyTimestamp >= validator.slashedAtTimestamp) {
            revert ValidatorInactive(validatorId);
        }

        // For a non-slashed validator, simply require it to be active to finalize a claim.
        if (!validator.slashed && !validator.active) {
            revert ValidatorInactive(validatorId);
        }

        uint256 amount = claim.amount;
        address recipient = claim.recipient;
        // Clear pending claim
        delete $.pendingCommissionClaims[validatorId][token];
        // Transfer from treasury
        address treasury = RewardsFacet(address(this)).getTreasury();
        if (treasury == address(0)) {
            revert TreasuryNotSet();
        }
        IPlumeStakingRewardTreasury(treasury).distributeReward(token, amount, recipient);
        emit CommissionClaimFinalized(validatorId, token, recipient, amount, block.timestamp);
        return amount;
    }

    /**
     * @notice Clean up expired votes for a validator and return the current valid vote count
     * @dev This function removes expired votes and updates the vote count accordingly
     * @param validatorId The validator to clean up votes for
     * @return newActiveVoteCount The number of valid (non-expired) votes remaining
     */
    function _cleanupExpiredVotes(
        uint16 validatorId
    ) internal returns (uint256 newActiveVoteCount) {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();

        uint256 voteCount = $.slashVoteCounts[validatorId];
        if (voteCount == 0) {
            return 0; // No votes to clean up
        }

        uint16[] memory allValidatorIds = $.validatorIds;
        uint256 newActiveVoteCount = 0;

        for (uint256 i = 0; i < allValidatorIds.length; i++) {
            uint16 voterValidatorId = allValidatorIds[i];
            if (voterValidatorId == validatorId) {
                continue;
            }

            uint256 voteExpiration = $.slashingVotes[validatorId][voterValidatorId];
            if (voteExpiration > 0) {
                // A vote from this validator exists.
                PlumeStakingStorage.ValidatorInfo storage voterValidator = $.validators[voterValidatorId];
                bool voterIsEligible = voterValidator.active && !voterValidator.slashed;
                bool voteHasExpired = block.timestamp >= voteExpiration;

                if (voterIsEligible && !voteHasExpired) {
                    // Vote is valid and active.
                    newActiveVoteCount++;
                } else {
                    // Vote is invalid (voter ineligible or vote expired). Clean it up.
                    delete $.slashingVotes[validatorId][voterValidatorId];
                }
            }
        }

        // Update the vote count to reflect only the currently valid, active votes.
        $.slashVoteCounts[validatorId] = newActiveVoteCount;
        return newActiveVoteCount;
    }

    /**
     * @notice Vote to slash a malicious validator
     * @dev Caller must be the L2 admin of an *active* validator.
     * @param maliciousValidatorId ID of the malicious validator to vote against
     * @param voteExpiration Timestamp when this vote expires
     */
    function voteToSlashValidator(uint16 maliciousValidatorId, uint256 voteExpiration) external nonReentrant {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();
        address voterAdmin = msg.sender;
        uint16 voterValidatorId = $.adminToValidatorId[voterAdmin];

        // Check 1: Voter is an active validator admin for the ID derived from the mapping
        if ($.validators[voterValidatorId].l2AdminAddress != voterAdmin || !$.validators[voterValidatorId].active) {
            revert NotValidatorAdmin(voterAdmin);
        }

        // Check 2: Target validator exists, not slashed, and is active
        PlumeStakingStorage.ValidatorInfo storage targetValidator = $.validators[maliciousValidatorId];
        if (!$.validatorExists[maliciousValidatorId]) {
            revert ValidatorDoesNotExist(maliciousValidatorId);
        }
        if (targetValidator.slashed) {
            revert ValidatorAlreadySlashed(maliciousValidatorId);
        }
        if (!targetValidator.active) {
            revert ValidatorInactive(maliciousValidatorId);
        }

        // Check 3: Cannot vote for self
        if (voterValidatorId == maliciousValidatorId) {
            revert CannotVoteForSelf();
        }

        // Check 4: Vote expiration validity
        if (
            voteExpiration <= block.timestamp || $.maxSlashVoteDurationInSeconds == 0 // Prevent voting if duration not // set
           || voteExpiration > block.timestamp + $.maxSlashVoteDurationInSeconds
        ) {
            revert SlashVoteDurationTooLong();
        }

        // Check 5: Voter hasn't already voted recently (check existing vote expiration)
        uint256 currentVoteExpiration = $.slashingVotes[maliciousValidatorId][voterValidatorId];
        if (currentVoteExpiration > block.timestamp) {
            revert AlreadyVotedToSlash(maliciousValidatorId, voterValidatorId);
        }

        // Clean up expired votes before processing new vote
        _cleanupExpiredVotes(maliciousValidatorId);

        // Store the vote
        $.slashingVotes[maliciousValidatorId][voterValidatorId] = voteExpiration;

        // Increment vote count (cleanup already ensured accurate count)
        $.slashVoteCounts[maliciousValidatorId]++;

        emit SlashVoteCast(maliciousValidatorId, voterValidatorId, voteExpiration);

        // --- AUTO-SLASH TRIGGER ---
        // After casting the vote, check if the unanimity threshold has been met.
        uint256 activeVoteCount = $.slashVoteCounts[maliciousValidatorId];
        uint256 totalEligibleValidators = _countEligibleValidators(maliciousValidatorId);

        if (activeVoteCount >= totalEligibleValidators && totalEligibleValidators > 0) {
            _performSlash(maliciousValidatorId, msg.sender);
        }
    }

    /**
     * @notice Slash a malicious validator if enough valid votes have been cast.
     * @dev Callable by anyone with ADMIN_ROLE.
     * @param validatorId ID of the validator to potentially slash
     */
    function slashValidator(
        uint16 validatorId
    ) external nonReentrant onlyRole(PlumeRoles.TIMELOCK_ROLE) {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();

        if (!$.validatorExists[validatorId]) {
            revert ValidatorDoesNotExist(validatorId);
        }

        PlumeStakingStorage.ValidatorInfo storage validatorToSlash = $.validators[validatorId];

        if (validatorToSlash.slashed) {
            revert ValidatorAlreadySlashed(validatorId);
        }

        // Clean up expired votes first to get accurate count
        uint256 activeVoteCount = _cleanupExpiredVotes(validatorId);
        uint256 totalEligibleValidators = _countEligibleValidators(validatorId);

        // ALL eligible validators must vote for slashing (unanimous consensus)
        if (activeVoteCount < totalEligibleValidators) {
            revert UnanimityNotReached(activeVoteCount, totalEligibleValidators);
        }

        _performSlash(validatorId, msg.sender);
    }

    /**
     * @notice Manually triggers the settlement of accrued commission for a specific validator.
     * @dev This updates the validator's cumulative reward per token indices (for all reward tokens)
     *      and their accrued commission storage. It uses the validator's current commission rate for settlement.
     *      Can be called for any validator (active, inactive, or slashed) to force settlement.
     * @param validatorId The ID of the validator.
     */
    function forceSettleValidatorCommission(
        uint16 validatorId
    ) external {
        PlumeStakingStorage.Layout storage $s = PlumeStakingStorage.layout();

        // Perform validator existence check directly
        if (!$s.validatorExists[validatorId]) {
            revert ValidatorDoesNotExist(validatorId);
        }

        PlumeRewardLogic._settleCommissionForValidatorUpToNow($s, validatorId);
    }

    /**
     * @notice Manually clean up expired votes for a validator
     * @dev Anyone can call this to clean up expired votes and get accurate vote counts
     * @param validatorId The validator to clean up votes for
     * @return validVoteCount The number of valid (non-expired) votes remaining
     */
    function cleanupExpiredVotes(
        uint16 validatorId
    ) external returns (uint256 validVoteCount) {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();

        if (!$.validatorExists[validatorId]) {
            revert ValidatorDoesNotExist(validatorId);
        }

        return _cleanupExpiredVotes(validatorId);
    }

    // --- Private Helper Functions ---

    /**
     * @notice Internal logic to perform the slash action on a validator.
     * @dev Separated to prevent code duplication between auto-slash and manual slash.
     * @param validatorId The ID of the validator to slash.
     * @param slasher The address that triggered the slash action.
     */
    function _performSlash(uint16 validatorId, address slasher) internal {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();
        PlumeStakingStorage.ValidatorInfo storage validatorToSlash = $.validators[validatorId];

        // This check is important to prevent re-entrancy or double-slashing
        if (validatorToSlash.slashed) {
            return;
        }

        // Record amounts being lost for the event BEFORE any state changes
        uint256 stakeLost = $.validatorTotalStaked[validatorId];
        uint256 cooledLost = $.validatorTotalCooling[validatorId];

        // Mark validator as slashed FIRST
        validatorToSlash.active = false;
        validatorToSlash.slashed = true;
        validatorToSlash.slashedAtTimestamp = block.timestamp;

        // Update global accounting - reduce totals by the amounts being lost
        $.totalStaked -= stakeLost;
        $.totalCooling -= cooledLost;

        // IMPORTANT: Zero out validator totals - slashed funds are lost/burned
        $.validatorTotalStaked[validatorId] = 0;
        $.validatorTotalCooling[validatorId] = 0;
        validatorToSlash.delegatedAmount = 0;

        // Clear the stakers array - slashed validator should show 0 stakers
        delete $.validatorStakers[validatorId];

        // Clear voting records for the slashed validator
        $.slashVoteCounts[validatorId] = 0;
        uint16[] memory validatorIds = $.validatorIds;
        for (uint256 i = 0; i < validatorIds.length; i++) {
            delete $.slashingVotes[validatorId][validatorIds[i]];
        }

        emit ValidatorSlashed(validatorId, slasher, stakeLost + cooledLost);
        emit ValidatorStatusUpdated(validatorId, false, true);
    }

    /**
     * @notice Internal helper to count the number of validators eligible to vote on a slash.
     * @dev An eligible validator is active, not slashed, and not the one being voted on.
     * @param validatorToExclude The ID of the validator being voted on (to exclude from the count).
     * @return The number of eligible voting validators.
     */
    function _countEligibleValidators(
        uint16 validatorToExclude
    ) internal view returns (uint256) {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();
        uint256 totalActive = _countActiveValidators();

        // If the validator being voted on is part of the active set, then the number
        // of eligible voters is one less than the total.
        PlumeStakingStorage.ValidatorInfo storage excludedInfo = $.validators[validatorToExclude];
        if (excludedInfo.active && !excludedInfo.slashed) {
            // Ensure we don't underflow if totalActive is somehow 0, though this is unlikely.
            if (totalActive > 0) {
                return totalActive - 1;
            }
        }

        // If the excluded validator was not active anyway, then the total number of active
        // validators is the correct count of eligible voters.
        return totalActive;
    }

    /**
     * @notice Internal helper to count the total number of active, non-slashed validators.
     * @dev The single source of truth for counting active validators.
     * @return The total number of active and non-slashed validators.
     */
    function _countActiveValidators() internal view returns (uint256) {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();
        uint16[] memory ids = $.validatorIds;
        uint256 count = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            PlumeStakingStorage.ValidatorInfo storage info = $.validators[ids[i]];
            if (info.active && !info.slashed) {
                count++;
            }
        }
        return count;
    }

    // --- View Functions ---

    /**
     * @notice Get information about a validator including total staked amount and staker count
     */
    function getValidatorInfo(
        uint16 validatorId
    )
        external
        view
        returns (PlumeStakingStorage.ValidatorInfo memory info, uint256 totalStaked, uint256 stakersCount)
    {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();
        if (!$.validatorExists[validatorId]) {
            revert ValidatorDoesNotExist(validatorId);
        }
        info = $.validators[validatorId];
        totalStaked = $.validatorTotalStaked[validatorId];
        stakersCount = $.validatorStakers[validatorId].length;

        // Ensure the returned struct has the correct delegated amount.
        info.delegatedAmount = totalStaked;

        return (info, totalStaked, stakersCount);
    }

    /**
     * @notice Get essential statistics about a validator
     */
    function getValidatorStats(
        uint16 validatorId
    ) external view returns (bool active, uint256 commission, uint256 totalStaked, uint256 stakersCount) {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();
        if (!$.validatorExists[validatorId]) {
            revert ValidatorDoesNotExist(validatorId);
        }
        PlumeStakingStorage.ValidatorInfo storage validator = $.validators[validatorId];
        active = validator.active;
        commission = validator.commission;
        totalStaked = $.validatorTotalStaked[validatorId];
        stakersCount = $.validatorStakers[validatorId].length;
        return (active, commission, totalStaked, stakersCount);
    }

    /**
     * @notice Get the list of validators a user has staked with
     */
    function getUserValidators(
        address user
    ) external view returns (uint16[] memory) {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();
        uint16[] storage userAssociatedValidators = $.userValidators[user];
        uint256 associatedCount = userAssociatedValidators.length;

        if (associatedCount == 0) {
            return new uint16[](0);
        }

        uint16[] memory tempNonSlashedValidators = new uint16[](associatedCount); // Max possible size
        uint256 actualCount = 0;

        for (uint256 i = 0; i < associatedCount; i++) {
            uint16 valId = userAssociatedValidators[i];
            if ($.validatorExists[valId] && !$.validators[valId].slashed) {
                // Also check .validatorExists for safety
                tempNonSlashedValidators[actualCount] = valId;
                actualCount++;
            }
        }

        uint16[] memory finalNonSlashedValidators = new uint16[](actualCount);
        for (uint256 i = 0; i < actualCount; i++) {
            finalNonSlashedValidators[i] = tempNonSlashedValidators[i];
        }

        return finalNonSlashedValidators;
    }

    /**
     * @notice Get the amount of commission accrued for a specific token by a validator but not yet claimed.
     * @return The total accrued commission for the specified token.
     */
    function getAccruedCommission(uint16 validatorId, address token) public view returns (uint256) {
        PlumeStakingStorage.Layout storage $s = PlumeStakingStorage.layout();
        if (!$s.validatorExists[validatorId]) {
            revert ValidatorDoesNotExist(validatorId);
        }
        if (!$s.isRewardToken[token]) {
            revert TokenDoesNotExist(token);
        }

        return $s.validatorAccruedCommission[validatorId][token];
    }

    /**
     * @notice Returns a list of all validators with their basic data.
     * @return list An array of ValidatorListData structs.
     */
    function getValidatorsList() external view virtual returns (ValidatorFacet.ValidatorListData[] memory list) {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();
        uint16[] memory ids = $.validatorIds;
        uint256 numValidators = ids.length;
        list = new ValidatorFacet.ValidatorListData[](numValidators);

        for (uint256 i = 0; i < numValidators; i++) {
            uint16 id = ids[i];
            PlumeStakingStorage.ValidatorInfo storage info = $.validators[id];
            list[i] = ValidatorFacet.ValidatorListData({
                id: id,
                totalStaked: $.validatorTotalStaked[id],
                commission: info.commission
            });
        }
    }

    /**
     * @notice Returns the number of currently active validators.
     * @dev An active validator is one that is marked as active and has not been slashed.
     */
    function getActiveValidatorCount() external view returns (uint256 count) {
        return _countActiveValidators();
    }

    /**
     * @notice Get the number of valid (non-expired) votes for a validator
     * @param validatorId The ID of the validator
     * @return validVoteCount The number of valid (non-expired) votes
     */
    function getSlashVoteCount(
        uint16 validatorId
    ) external view returns (uint256) {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();

        if (!$.validatorExists[validatorId]) {
            revert ValidatorDoesNotExist(validatorId);
        }

        // Count only valid (non-expired) votes from eligible validators
        uint256 validVoteCount = 0;
        uint256 currentTime = block.timestamp;

        for (uint256 i = 0; i < $.validatorIds.length; i++) {
            uint16 voterValidatorId = $.validatorIds[i];

            if (voterValidatorId == validatorId) {
                continue;
            }

            uint256 voteExpiration = $.slashingVotes[validatorId][voterValidatorId];
            if (voteExpiration > 0) {
                // Check if the voting validator is eligible (active and not slashed)
                PlumeStakingStorage.ValidatorInfo storage voterValidator = $.validators[voterValidatorId];
                bool voterIsEligible = voterValidator.active && !voterValidator.slashed;
                
                // Check if vote has not expired (align with _cleanupExpiredVotes logic)
                bool voteHasNotExpired = currentTime < voteExpiration;

                if (voterIsEligible && voteHasNotExpired) {
                    validVoteCount++;
                }
            }
        }

        return validVoteCount;
    }

    /**
     * @notice Returns the list of commission checkpoints for a validator.
     * @dev Primarily for testing and off-chain tooling.
     * @param validatorId The ID of the validator.
     * @return An array of RateCheckpoint structs.
     */
    function getValidatorCommissionCheckpoints(
        uint16 validatorId
    ) external view returns (PlumeStakingStorage.RateCheckpoint[] memory) {
        PlumeStakingStorage.Layout storage $ = PlumeStakingStorage.layout();
        if (!$.validatorExists[validatorId]) {
            revert ValidatorDoesNotExist(validatorId);
        }
        return $.validatorCommissionCheckpoints[validatorId];
    }

}

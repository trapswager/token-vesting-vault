// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VestingVault — token vesting with cliff, linear unlock and revocation
/// @notice Vault contract that holds ERC-20 tokens and releases them according to schedules.
contract VestingVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================
    //  PROVIDED PART (identical to the student starter file)
    // ============================================================
    struct Schedule {
        address beneficiary;
        uint256 total;      // total tokens promised
        uint256 released;   // tokens already paid out
        uint64 start;       // unix time when vesting starts
        uint64 cliff;       // seconds after `start` before ANY token vests
        uint64 duration;    // seconds after `start` when 100% is vested
        uint64 revokedAt;   // 0 while not revoked
        bool revocable;
        bool revoked;
    }

    IERC20 public immutable token;
    uint256 public scheduleCount;                       // ids start from 1
    uint256 public totalAllocated;                      // tokens promised to beneficiaries and not yet paid out
    mapping(uint256 => Schedule) public schedules;
    mapping(address => uint256[]) private _schedulesOf;

    event ScheduleCreated(uint256 indexed id, address indexed beneficiary, uint256 amount, uint64 start, uint64 cliff, uint64 duration, bool revocable);
    event Released(uint256 indexed id, address indexed beneficiary, uint256 amount);
    event Revoked(uint256 indexed id, uint256 returnedToOwner);
    event ScheduleTransferred(uint256 indexed id, address indexed from, address indexed to);

    constructor(IERC20 token_) Ownable(msg.sender) {
        require(address(token_) != address(0), "zero token");
        token = token_;
    }

    // ============================================================
    //  YOUR CODE STARTS HERE
    // ============================================================

    /// @notice Create a vesting schedule for a beneficiary (owner only).
    /// @param beneficiary Recipient of the vested tokens.
    /// @param amount Total tokens for this schedule.
    /// @param start Start timestamp in seconds.
    /// @param cliff Cliff period in seconds after `start`.
    /// @param duration Total duration in seconds after `start`.
    /// @param revocable Whether the schedule can be revoked by the owner.
    /// @return id New schedule id.
    function createSchedule(
        address beneficiary,
        uint256 amount,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bool revocable
    ) external onlyOwner returns (uint256 id) {
        require(beneficiary != address(0), "zero beneficiary");
        require(amount > 0, "amount is zero");
        require(duration > 0, "duration is zero");
        require(cliff <= duration, "cliff > duration");
        require(
            token.balanceOf(address(this)) - totalAllocated >= amount,
            "not enough tokens"
        );

        id = ++scheduleCount;

        schedules[id] = Schedule({
            beneficiary: beneficiary,
            total: amount,
            released: 0,
            start: start,
            cliff: cliff,
            duration: duration,
            revokedAt: 0,
            revocable: revocable,
            revoked: false
        });

        _schedulesOf[beneficiary].push(id);
        totalAllocated += amount;

        emit ScheduleCreated(id, beneficiary, amount, start, cliff, duration, revocable);
    }

    /// @notice Calculate how many tokens are vested so far for schedule `id`.
    /// @param id Schedule id.
    /// @return Vested token amount.
    function vestedAmount(uint256 id) public view returns (uint256) {
        Schedule storage s = schedules[id];
        require(s.beneficiary != address(0), "schedule does not exist");
        return _calcVested(s);
    }

    /// @notice Calculate how many tokens can be claimed right now for schedule `id`.
    /// @param id Schedule id.
    /// @return Releasable token amount.
    function releasable(uint256 id) public view returns (uint256) {
        Schedule storage s = schedules[id];
        require(s.beneficiary != address(0), "schedule does not exist");
        return _calcVested(s) - s.released;
    }

    /// @notice Release vested tokens to the beneficiary (anyone can call).
    /// @param id Schedule id.
    function release(uint256 id) external nonReentrant {
        Schedule storage s = schedules[id];
        require(s.beneficiary != address(0), "schedule does not exist");

        uint256 amount = _calcVested(s) - s.released;
        require(amount > 0, "nothing to release");

        s.released += amount;
        totalAllocated -= amount;

        token.safeTransfer(s.beneficiary, amount);
        emit Released(id, s.beneficiary, amount);
    }

    /// @notice Revoke a revocable schedule and return unvested tokens to the owner.
    /// @param id Schedule id.
    function revoke(uint256 id) external onlyOwner nonReentrant {
        Schedule storage s = schedules[id];
        require(s.beneficiary != address(0), "schedule does not exist");
        require(s.revocable, "not revocable");
        require(!s.revoked, "already revoked");

        uint256 vestedNow = _calcVested(s);
        uint256 unvested = s.total - vestedNow;

        s.revoked = true;
        s.revokedAt = uint64(block.timestamp);
        totalAllocated -= unvested;

        if (unvested > 0) {
            token.safeTransfer(owner(), unvested);
        }

        emit Revoked(id, unvested);
    }

    /// @notice Withdraw tokens sent to the contract that are not allocated to schedules.
    /// @param to Recipient address.
    /// @return amount Withdrawn token amount.
    function withdrawUnallocated(address to) external onlyOwner nonReentrant returns (uint256 amount) {
        require(to != address(0), "zero address");

        amount = token.balanceOf(address(this)) - totalAllocated;
        require(amount > 0, "nothing to withdraw");

        token.safeTransfer(to, amount);
    }

    /// @notice Get schedule ids belonging to `beneficiary`.
    /// @param beneficiary Beneficiary address.
    /// @return Array of schedule ids.
    function schedulesOf(address beneficiary) external view returns (uint256[] memory) {
        return _schedulesOf[beneficiary];
    }

    /// @notice Transfer a schedule to a new beneficiary (current beneficiary only).
    /// @param id Schedule id.
    /// @param newBeneficiary New beneficiary address.
    function transferSchedule(uint256 id, address newBeneficiary) external {
        Schedule storage s = schedules[id];
        require(s.beneficiary != address(0), "schedule does not exist");
        require(msg.sender == s.beneficiary, "not beneficiary");
        require(newBeneficiary != address(0), "zero address");
        require(newBeneficiary != s.beneficiary, "same beneficiary");

        address oldBeneficiary = s.beneficiary;
        s.beneficiary = newBeneficiary;

        uint256[] storage list = _schedulesOf[oldBeneficiary];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == id) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }

        _schedulesOf[newBeneficiary].push(id);
        emit ScheduleTransferred(id, oldBeneficiary, newBeneficiary);
    }

    /// @dev Helper to calculate vested amount using the required formula.
    function _calcVested(Schedule storage s) internal view returns (uint256) {
        uint256 t = s.revoked ? uint256(s.revokedAt) : block.timestamp;
        uint256 start = uint256(s.start);
        uint256 cliff = uint256(s.cliff);
        uint256 duration = uint256(s.duration);

        if (t < start + cliff) {
            return 0;
        }
        if (t >= start + duration) {
            return s.total;
        }

        return (s.total * (t - start)) / duration;
    }
}

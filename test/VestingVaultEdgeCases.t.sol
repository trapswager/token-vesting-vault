// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VestingVault} from "../src/VestingVault.sol";

contract EdgeMockToken is ERC20 {
    constructor() ERC20("Edge Token", "EDGE") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

contract VestingVaultEdgeCasesTest is Test {
    EdgeMockToken internal token;
    VestingVault internal vault;

    address internal owner = address(this);
    address internal alice = address(0x1111);
    address internal bob = address(0x2222);
    address internal stranger = address(0x3333);

    uint64 internal start;

    function setUp() public {
        start = uint64(block.timestamp + 50);
        token = new EdgeMockToken();
        vault = new VestingVault(IERC20(address(token)));
        token.transfer(address(vault), 500_000 ether);
    }

    function test_RevertInvalidScheduleParams() public {
        vm.expectRevert(bytes("amount is zero"));
        vault.createSchedule(alice, 0, start, 10, 100, true);

        vm.expectRevert(bytes("duration is zero"));
        vault.createSchedule(alice, 100 ether, start, 0, 0, true);

        vm.expectRevert(bytes("cliff > duration"));
        vault.createSchedule(alice, 100 ether, start, 150, 100, true);
    }

    function test_RevertWhenNothingToRelease() public {
        uint256 id = vault.createSchedule(alice, 1000 ether, start, 100, 500, false);
        vm.warp(start + 10);
        vm.expectRevert(bytes("nothing to release"));
        vault.release(id);
    }

    function test_RevertTransferScheduleUnauthorizedOrInvalid() public {
        uint256 id = vault.createSchedule(alice, 1000 ether, start, 100, 500, false);

        vm.prank(stranger);
        vm.expectRevert(bytes("not beneficiary"));
        vault.transferSchedule(id, bob);

        vm.prank(alice);
        vm.expectRevert(bytes("zero address"));
        vault.transferSchedule(id, address(0));

        vm.prank(alice);
        vm.expectRevert(bytes("same beneficiary"));
        vault.transferSchedule(id, alice);
    }

    function test_RevertWithdrawUnallocatedWhenZeroOrNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        vault.withdrawUnallocated(stranger);

        vault.createSchedule(alice, 500_000 ether, start, 0, 1000, false);

        vm.expectRevert(bytes("nothing to withdraw"));
        vault.withdrawUnallocated(owner);
    }

    function testFuzz_ReleaseAfterFullDuration(uint96 amt, uint64 extraTime) public {
        vm.assume(amt > 0);
        uint256 totalAmt = uint256(amt);
        uint256 available = token.balanceOf(address(vault)) - vault.totalAllocated();
        if (totalAmt > available) {
            totalAmt = available;
        }
        vm.assume(totalAmt > 0);

        uint64 dur = 1000;
        uint256 id = vault.createSchedule(alice, totalAmt, start, 100, dur, false);

        vm.warp(uint256(start) + uint256(dur) + uint256(extraTime));
        vault.release(id);

        assertEq(token.balanceOf(alice), totalAmt);
    }
}

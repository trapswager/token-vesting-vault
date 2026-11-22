// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VestingVault} from "../src/VestingVault.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MCK") {
        _mint(msg.sender, 10_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VestingVaultTest is Test {
    MockERC20 internal token;
    VestingVault internal vault;

    address internal owner = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal attacker = address(0xBAD);

    uint64 internal start;
    uint64 internal cliff = 200;
    uint64 internal duration = 1000;
    uint256 internal amount = 1000 ether;

    function setUp() public {
        start = uint64(block.timestamp + 100);
        token = new MockERC20();
        vault = new VestingVault(IERC20(address(token)));
        token.transfer(address(vault), 5_000_000 ether);
    }

    // 1. Before cliff -> 0 vested
    function test_BeforeCliffIsZero() public {
        uint256 id = vault.createSchedule(alice, amount, start, cliff, duration, true);
        vm.warp(start + cliff - 1);
        assertEq(vault.vestedAmount(id), 0);
        assertEq(vault.releasable(id), 0);
    }

    // 2. Right at cliff boundary
    function test_AtCliffBoundary() public {
        uint256 id = vault.createSchedule(alice, amount, start, cliff, duration, true);
        vm.warp(start + cliff);
        uint256 expected = (amount * cliff) / duration;
        assertEq(vault.vestedAmount(id), expected);
    }

    // 3. Mid-duration linear unlock
    function test_MidDurationLinear() public {
        uint256 id = vault.createSchedule(alice, amount, start, cliff, duration, true);
        vm.warp(start + 500);
        uint256 expected = (amount * 500) / duration;
        assertEq(vault.vestedAmount(id), expected);
    }

    // 4. At and after duration -> 100% vested
    function test_AtAndAfterDurationFullVested() public {
        uint256 id = vault.createSchedule(alice, amount, start, cliff, duration, true);
        vm.warp(start + duration);
        assertEq(vault.vestedAmount(id), amount);

        vm.warp(start + duration + 5000);
        assertEq(vault.vestedAmount(id), amount);
    }

    // 5. Partial release and second release
    function test_PartialReleaseAndSecondRelease() public {
        uint256 id = vault.createSchedule(alice, amount, start, cliff, duration, false);

        vm.warp(start + 400);
        vault.release(id);
        assertEq(token.balanceOf(alice), 400 ether);

        vm.warp(start + 800);
        vault.release(id);
        assertEq(token.balanceOf(alice), 800 ether);
    }

    // 6. Anyone can call release and tokens go to beneficiary
    function test_AnyoneCanReleaseToBeneficiary() public {
        uint256 id = vault.createSchedule(alice, amount, start, cliff, duration, false);
        vm.warp(start + 500);

        vm.prank(attacker);
        vault.release(id);

        assertEq(token.balanceOf(alice), 500 ether);
        assertEq(token.balanceOf(attacker), 0);
    }

    // 7. Revoke returns unvested tokens and keeps vested claimable
    function test_RevokeReturnsUnvestedAndFreezes() public {
        uint256 id = vault.createSchedule(alice, amount, start, cliff, duration, true);
        vm.warp(start + 400);

        uint256 ownerBefore = token.balanceOf(owner);
        vault.revoke(id);
        assertEq(token.balanceOf(owner), ownerBefore + 600 ether);

        // Advance time after revoke -> vested does not increase
        vm.warp(start + duration);
        assertEq(vault.vestedAmount(id), 400 ether);

        // Beneficiary can still claim vested 400
        vault.release(id);
        assertEq(token.balanceOf(alice), 400 ether);
    }

    // 8. Cannot revoke non-revocable schedule
    function test_RevertWhenRevokingNonRevocable() public {
        uint256 id = vault.createSchedule(alice, amount, start, cliff, duration, false);
        vm.expectRevert(bytes("not revocable"));
        vault.revoke(id);
    }

    // 9. Cannot revoke twice
    function test_RevertWhenRevokingTwice() public {
        uint256 id = vault.createSchedule(alice, amount, start, cliff, duration, true);
        vault.revoke(id);
        vm.expectRevert(bytes("already revoked"));
        vault.revoke(id);
    }

    // 10. Non-owner cannot create schedule or revoke
    function test_RevertNonOwnerAdminActions() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.createSchedule(alice, amount, start, cliff, duration, true);

        uint256 id = vault.createSchedule(alice, amount, start, cliff, duration, true);
        vm.prank(attacker);
        vm.expectRevert();
        vault.revoke(id);
    }

    // 11. Cannot over-allocate more than unallocated balance
    function test_RevertWhenNotEnoughTokens() public {
        uint256 extra = token.balanceOf(address(vault)) + 1;
        vm.expectRevert(bytes("not enough tokens"));
        vault.createSchedule(alice, extra, start, cliff, duration, true);
    }

    // 12. Withdraw unallocated tokens
    function test_WithdrawUnallocated() public {
        token.mint(address(vault), 250 ether);
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 withdrawn = vault.withdrawUnallocated(owner);
        assertEq(withdrawn, 250 ether);
        assertEq(token.balanceOf(owner), ownerBefore + 250 ether);
    }

    // 13. Transfer schedule to new beneficiary
    function test_TransferSchedule() public {
        uint256 id = vault.createSchedule(alice, amount, start, cliff, duration, false);

        vm.prank(alice);
        vault.transferSchedule(id, bob);

        assertEq(vault.schedulesOf(alice).length, 0);
        assertEq(vault.schedulesOf(bob).length, 1);
        assertEq(vault.schedulesOf(bob)[0], id);
    }

    // 14. Fuzz test over time and total amount
    function testFuzz_VestedBounds(uint256 totalAmt, uint64 elapsed) public {
        totalAmt = bound(totalAmt, 1 ether, 1_000_000 ether);
        uint64 dur = 1000;
        uint64 cl = 200;

        uint256 id = vault.createSchedule(alice, totalAmt, start, cl, dur, false);
        vm.warp(uint256(start) + uint256(elapsed));

        uint256 vested = vault.vestedAmount(id);
        assertLe(vested, totalAmt);

        if (elapsed < cl) {
            assertEq(vested, 0);
        } else if (elapsed >= dur) {
            assertEq(vested, totalAmt);
        }
    }
}

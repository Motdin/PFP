# F‑02 — `MorphoBlueFlashLoanAssetManagerLib.onMorphoFlashLoan()` tidak memvalidasi initiator

| | |
|---|---|
| **File** | `contracts/persistent/smart-accounts/morpho-blue-flash-loan-asset-manager/MorphoBlueFlashLoanAssetManagerLib.sol` |
| **Severity** | Informational (latent / defense‑in‑depth) — **belum** reachable oleh pihak ketiga |
| **Status scope** | Di dalam scope (kontrak terdaftar sebagai smart account), tapi dampak hari ini = 0 |
| **PoC** | `tests/F02_MorphoFlashLoan_NoInitiatorCheck.t.sol` |

---

## 1. Vulnerability Summary

`onMorphoFlashLoan()` mengeksekusi **arbitrary calls** dari smart account, dan hanya memvalidasi
`msg.sender == MORPHO` — **tidak** memvalidasi siapa initiator flash loan.

```solidity
function onMorphoFlashLoan(uint256 _amount, bytes calldata _data) external {
    if (msg.sender != address(MORPHO)) revert ...UnauthorizedCaller();

    ForwardData memory forwardData = abi.decode(_data, (ForwardData));
    IERC20 asset = IERC20(forwardData.borrowedAssetAddress);
    asset.safeTransfer(getBorrowedAssetsRecipient(), asset.balanceOf(address(this)));

    for (uint256 i; i < calls.length; i++) {
        Address.functionCall({target: call.target, data: call.data});   // <-- arbitrary calls
    }
    asset.safeApprove(address(MORPHO), _amount);
}
```

Bandingkan dengan varian Aave di repo yang sama, yang punya dua lapis otentikasi:

```solidity
// AaveV3FlashLoanAssetManagerLib.executeOperation
if (_initiator != address(this)) revert ...UnauthorizedInitiator();   // <-- tidak ada di Morpho
address poolAddress = POOL();
if (msg.sender != poolAddress) revert ...UnauthorizedCaller();
```

Alasannya penting: `Aave flashLoan(_receiverAddress = siapa saja, …)` bisa **dipicu siapa pun** dengan
`_receiverAddress` diarahkan ke smart account, sehingga callback `executeOperation` bisa dibuka attacker —
`_initiator` adalah satu‑satunya pembeda. Cek itu wajib di sana.

## 2. Impact Assessment

**Hari ini: tidak ada dampak.** `Morpho.flashLoan()` memanggil balik **`msg.sender`** (=
`lib/morpho-blue/src/Morpho.sol:422‑432`), sehingga target callback selalu sama dengan initiator, dan
satu‑satunya initiator adalah `flashLoan()` milik smart account yang `msg.sender == owner`.

**Dampak bila asumsi itu berubah:** kontrak ini adalah *asset manager* dari sebuah Enzyme vault
(`IVault(vaultProxy).canManageAssets(address(assetManager)) == true`). Siapa pun yang bisa memicu
callback‑nya dapat mengeksekusi `ComptrollerProxy.callOnIntegration(...)` / `ExternalPositionManager.*`
**sebagai asset manager vault** → drain seluruh TVL vault (Critical).

Karena itu ini dilaporkan sebagai *hardening*, bukan Critical: provider flash loan lain sudah beberapa
kali memakai pola "callback target ditentukan initiator", dan adaptor Aave di codebase yang sama sudah
pernah kena kelas bug ini.

## 3. Executable Foundry PoC

File lengkap: `tests/F02_MorphoFlashLoan_NoInitiatorCheck.t.sol`.

PoC memakai kontrak Enzyme asli (`MorphoBlueFlashLoanAssetManagerLib`) + model faithful
`Morpho.flashLoan()` (transfer → callback `msg.sender` → tarik balik), `MockVault` dengan semantik
`canManageAssets`, dan `MockIntegrationManager`.

```solidity
function test_CallbackExecutesArbitraryCallsAsVaultAssetManager() public {
    IMorphoBlueFlashLoanAssetManager.Call[] memory calls = new IMorphoBlueFlashLoanAssetManager.Call[](2);

    // 1 wei untuk repay pinjaman
    calls[0] = IMorphoBlueFlashLoanAssetManager.Call({
        target: address(integrationManager),
        data: abi.encodeWithSelector(MockIntegrationManager.drain.selector, address(usdc), address(assetManager), 1)
    });

    // sisanya untuk attacker
    calls[1] = IMorphoBlueFlashLoanAssetManager.Call({
        target: address(integrationManager),
        data: abi.encodeWithSelector(MockIntegrationManager.drain.selector, address(usdc), ATTACKER, 1_000_000e18)
    });

    bytes memory data = abi.encode(
        IMorphoBlueFlashLoanAssetManager.ForwardData({borrowedAssetAddress: address(usdc), calls: calls})
    );

    // simulasi provider yang memisahkan callback-target dari initiator
    vm.prank(address(morpho));
    assetManager.onMorphoFlashLoan(1, data);

    assertEq(usdc.balanceOf(ATTACKER), 1_000_000e18);   // vault terkuras
}
```

Jalankan:

```powershell
forge test --match-path "tests/arena-poc/F02_MorphoFlashLoan_NoInitiatorCheck.t.sol" -vvv
```

## 4. Remediation

Karena `Morpho.flashLoan()` tidak mengirim `initiator`, tambahkan penanda initiator yang eksplisit dan
tidak bisa dipalsukan attacker — misalnya flag storage yang hanya diset oleh `flashLoan()` milik kontrak
dan langsung dihapus di callback:

```diff
+    bool internal flashLoanInProgress;
+
     function flashLoan(address _assetAddress, uint256 _amount, Call[] calldata _calls) external override {
         if (msg.sender != getOwner()) revert ...Unauthorized();
+        flashLoanInProgress = true;
         MORPHO.flashLoan({_token: _assetAddress, _assets: _amount, _data: ...});
+        flashLoanInProgress = false;
     }

     function onMorphoFlashLoan(uint256 _amount, bytes calldata _data) external {
         if (msg.sender != address(MORPHO)) revert ...UnauthorizedCaller();
+        if (!flashLoanInProgress) revert ...UnauthorizedInitiator();
         ...
     }
```

Atau (lebih murah, tanpa storage): tambahkan `address(this)` + `msg.sender` + nonce ke dalam `_data` dan
verifikasi hash‑nya terhadap nilai yang disimpan selama durasi `flashLoan()`.

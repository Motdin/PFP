# F‑04 — `ThreeOneThirdAdapter.takeOrder()` (deployment live Polygon/Base/Arbitrum) tanpa autentikasi + `_assetData` dikendalikan pemanggil

| | |
|---|---|
| **Kontrak** | `ThreeOneThirdAdapter` — `0x5a1c0E89133C4Cd844A8B345370565f1368A79A8` (Polygon; alamat sama di Base & Arbitrum) |
| **Source** | **Tidak ada di repo publik.** Diverifikasi dari source terverifikasi explorer (Blockscout `?module=contract&action=getsourcecode`), solc 0.8.19, optimizer 200 run, evmVersion `paris`, **bukan** proxy |
| **Constructor args** | `0x92fcde09790671cf085864182b9670c77da0884b` (IntegrationManager), `0xd20c024560cca40288c05bab650ac087ae9b0f6e` (31Third `BatchTrade`) |
| **Severity** | Low (butuh saldo token yang sudah ada di adaptor) |
| **Status scope** | **OOS by policy** — halaman program mencarve‑out eksplisit “missing `onlyIntegrationManager` on adapters”. **JANGAN disubmit.** |
| **PoC** | Tidak ada (alasan di §4) |

---

## 1. Vulnerability Summary

`takeOrder(address _vaultProxy, bytes _integrationData, bytes _assetData)` adalah `external` **tanpa**
`onlyIntegrationManager`, dan `_assetData` diperlakukan sebagai input tepercaya. Dekode:

```solidity
// fungsi: takeOrder
(IThreeOneThird.Trade[] memory trades, bool checkFeelessWallets) =
    abi.decode(_integrationData, (IThreeOneThird.Trade[], bool));

// _assetData = abi.encode(spendAssets_, spendAssetAmounts_, incomingAssets_)
//   -> dipakai apa adanya oleh post-action handler
__threeOneThirdBatchTrade(trades, IThreeOneThird.BatchTradeConfig(checkFeelessWallets, true));
```

Dua modifier post‑action terpasang pada `takeOrder`, keduanya menerima `_vaultProxy` **dari pemanggil**:

```solidity
function takeOrder(address _vaultProxy, bytes calldata _integrationData, bytes calldata _assetData)
    external
    postActionIncomingAssetsTransferHandler(_vaultProxy, _assetData)
    postActionSpendAssetsTransferHandler(_vaultProxy, _assetData)
{ ... }
```

Keduanya memanggil `__pushFullAssetBalances(_vaultProxy, assets)` — yaitu **seluruh** saldo adaptor untuk
setiap token yang tercantum di `_assetData` dikirim ke `_vaultProxy`. Karena `_assetData` sepenuhnya
disuplai pemanggil, pihak ketiga dapat menulis daftar token apa pun (mis. USDC, WETH, WBTC) dan
menetapkan `_vaultProxy = alamat penyerang`.

Bandingkan dengan adaptor lain di repo yang perilakunya identik: `ERC4626Adapter.lend/redeem`,
`ParaSwapV6Adapter.action`, `ZeroExV4Adapter.takeOrder` (men‑push **semua** incoming balance adaptor ke
`_vaultProxy` yang dikirim pemanggil), `OneInchV5Adapter.takeOrder/takeMultipleOrders/
takeOrderAndValidateIncoming`. F‑01 mendokumentasikan kelas yang sama untuk repo; **F‑04 membuktikan
kelas yang sama hidup di deployment yang sudah diaudit ChainSecurity dan terdaftar di scope**.

### `parseAssetsForAction` (dipakai IntegrationManager) — bersih secara logika

Perhitungan net delta dari `trades`, yang relevan untuk memastikan tidak ada bug *tambahan* di jalur
normal:

- `Trade.from` / `fromAmount` → delta negatif (spend asset)
- `Trade.to` / `minToReceiveBeforeFees` → delta positif (incoming asset)
- fee: `ceilDiv(minToReceiveBeforeFees * (10000 - __getThreeOneThirdFeeBasisPoints()), 10000)`
- delta akhir < 0 → masuk `spendAssets_`, selain itu → `incomingAssets_`
- return `SpendAssetsHandleType.Transfer`

Karena agregasi per token dilakukan sebelum dikembalikan, `isUniqueSet()` di `__preProcessCoI` selalu
lolos, dan token yang muncul sebagai `from` **dan** `to` di trade berbeda dikolaps menjadi satu delta
neto — sesuai dengan perilaku `batchTrade` yang juga netto. Tidak ditemukan selisih pembulatan yang
menguntungkan pihak ketiga: pembulatan fee memakai `ceilDiv` (membulatkan ke sisi fund), dan
`minIncomingAssetAmount` divalidasi IntegrationManager terhadap delta saldo vault yang sebenarnya.

## 2. Impact Assessment

- **Butuh** saldo token yang sudah berada di adaptor pada saat pemanggilan. Alur normal
  `SpendAssetsHandleType.Transfer` menyisakan saldo hanya secara **sementara** (IM transfer masuk →
  `takeOrder` → handler push kembali ke vault dalam satu transaksi), dan siapa pun dapat memanggil
  `takeOrder` dengan `_assetData` kosong yang tetap men‑sweep seluruh saldo tersebut ke alamat pilihannya
  di dalam transaksi yang sama.
- **Prasyarat tambahan**: `__threeOneThirdBatchTrade` harus **tidak revert** agar handler post‑action
  sempat berjalan; `BatchTradeConfig(..., revertOnError = true)` di‑hardcode, sehingga penyerang perlu
  menyusun array `Trade` yang valid untuk kontrak 31Third. Ini menaikkan biaya serangan tetapi tidak
  menghilangkan kelas kerentanannya. Saya **tidak** membuktikan langkah ini (lihat §4).
- **Bukan** jalur pencurian dana vault secara langsung: dana vault hanya berpindah ke adaptor lewat
  IntegrationManager yang sudah terautentikasi. Karena itu severity = Low, dan program menyatakan
  eksplisit kelas ini OOS.
- **Catatan tambahan (bukan temuan)**: `takeOrder` **tidak** `payable`, sedangkan
  `IThreeOneThird.batchTrade` `payable` → trade dengan ETH native tidak dapat dijalankan lewat adaptor
  ini. Ini keterbatasan fungsi, bukan kehilangan dana.

## 3. Remediation

Samakan dengan adaptor lain dan dengan `AdapterBase`:

```diff
 function takeOrder(address _vaultProxy, bytes calldata _integrationData, bytes calldata _assetData)
     external
+    onlyIntegrationManager
     postActionIncomingAssetsTransferHandler(_vaultProxy, _assetData)
     postActionSpendAssetsTransferHandler(_vaultProxy, _assetData)
 { ... }
```

Karena kontrak live tidak dapat di‑*upgrade* (bukan proxy), mitigasi operasional:

1. Jangan pernah membiarkan adaptor menyimpan saldo token antar transaksi (tidak ada yang perlu diubah
   pada alur normal, tetapi hindari `VaultLib.callOnContract` yang mengirim token ke adaptor).
2. Bila Enzyme mem‑redeploy adaptor, terapkan `onlyIntegrationManager` + `payable` bila ETH didukung.
3. Tambahkan invariant test di repo: untuk setiap adaptor, semua `external`/`public` fungsi selain
   `parseAssetsForAction` **wajib** memiliki `onlyIntegrationManager`.

## 4. Mengapa tidak ada PoC

1. Reproduksi lokal memerlukan mock kontrak 31Third `BatchTrade` → PoC berbasis mock **otomatis
   diinvalidasi** oleh program (“mocked-only PoC”).
2. Reproduksi di fork memerlukan interaksi dengan **kontrak pihak ketiga** (31Third), dan aturan program
   melarang pengujian terhadap kontrak pihak ketiga / oracle.
3. Karena kelas temuan ini eksplisit OOS, PoC tidak menambah nilai submisi apa pun.

Verifikasi ulang source (silakan dijalankan sendiri, butuh akses internet):

```
https://polygon.blockscout.com/api?module=contract&action=getsourcecode&address=0x5a1c0E89133C4Cd844A8B345370565f1368A79A8
```

Cari di bagian `ThreeOneThirdAdapter`: definisi `takeOrder` (tanpa `onlyIntegrationManager`), dua
modifier `postAction*TransferHandler`, dan `abi.decode(_actionData, ...)` di dalam
`postActionIncomingAssetsTransferHandler`/`postActionSpendAssetsTransferHandler`.

## 5. Kesimpulan

Tidak ada temuan baru yang dapat disubmit dari area ini. Nilainya: (a) menutup area “belum tercakup”
§6.1 `REPORT.md`, (b) membuktikan pola F‑01 bukan artefak repo tetapi ada di deployment live 3 chain,
(c) memastikan `parseAssetsForAction` (jalur yang benar‑benar dipakai IntegrationManager) bersih dari
kesalahan pembulatan/agregasi.

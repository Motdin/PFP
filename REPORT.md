# Enzyme Blue — Smart Contract Security Review

**Target program:** [Immunefi — Enzyme Finance](https://immunefi.com/bug-bounty/enzymefinance) (max bounty $200k, PoC required)
**Code reviewed:** `enzymefinance/protocol` @ `7200e4d` (2026‑09‑25) — the public repo build that matches the live deployments
**Reviewer mindset:** attacker, value‑extraction only (no gas/QA noise), Immunefi severity system
**Date:** 2026‑11‑02

---

## 0. Ringkasan Eksekutif (Bahasa Indonesia)

Saya melakukan review manual menyeluruh terhadap kontrak‑kontrak yang masuk scope dan memegang dana user
(queue, wrapper, splitter, smart account, adaptor, core vault/comptroller, fee/policy).

**Kesimpulan jujur:** saya **tidak menemukan Critical/High baru yang bisa dieksploitasi oleh attacker
tanpa privilege** pada surface yang saya review. Yang saya temukan adalah **3 isu nyata di level kode**
(2 hardening/defense‑in‑depth, 1 latent) yang saya dokumentasikan lengkap dengan PoC Foundry yang bisa
dijalankan, plus satu analisa tentang **keterbatasan fundamental** dari kontrol keamanan
`SharePriceThrottledAssetManager` (throttle‑nya hanya mengukur kerugian yang bersifat *atomik*).

Sebagai tambahan, area yang sebelumnya buta (`ThreeOneThirdAdapter` — source-nya **tidak ada di repo
publik**, hanya ada di explorer) sudah saya tutup dengan mengambil source terverifikasi dari deployment
live Polygon. Hasilnya **F‑04**: `takeOrder()` juga tanpa `onlyIntegrationManager`, yaitu kelas yang
*sama persis* dengan F‑01 dan eksplisit OOS oleh program. Jadi area ini **tidak** menghasilkan klaim
yang bisa disubmit, tetapi sekarang statusnya jelas (lihat §6.1).

Saya sengaja **tidak** membuat laporan palsu/overclaim. Bagian 5 berisi daftar hipotesis serangan yang
sudah saya uji dan **terbukti bersih** — ini menghemat waktu Anda, karena saya sudah menutup jalur‑jalur itu.
Bagian 6 berisi daftar hal yang **secara eksplisit OOS** menurut program, supaya Anda tidak membuang waktu.

| ID | Temuan | Severity (Immunefi) | Status scope |
|----|--------|--------------------|--------------|
| F‑01 | `ERC4626Adapter.lend()` / `redeem()` tanpa `onlyIntegrationManager` → unlimited allowance + arbitrary call dari adaptor | Low (perlu dana di adaptor) | **OOS by policy** (lihat §4.1) |
| F‑02 | `MorphoBlueFlashLoanAssetManagerLib.onMorphoFlashLoan()` tidak memvalidasi initiator (beda dengan varian Aave) | Informational (latent) | Di scope, tapi belum reachable |
| F‑03 | `SharePriceThrottledAssetManager`: (a) `init()` bisa dipanggil ulang bila vault == 0; (b) throttle hanya membatasi kerugian atomik | (a) Low / (b) High secara desain | (a) di scope, (b) butuh signer privileged |
| F‑04 | `ThreeOneThirdAdapter` live (Polygon/Base/Arbitrum `0x5a1c…79A8`, source hanya di explorer): `takeOrder()` tanpa `onlyIntegrationManager`, `_assetData` dikendalikan pemanggil → sweep seluruh saldo adaptor | Low | **OOS by policy** (kelas yang sama dengan F‑01) |

---

## 1. Scope & metodologi

### 1.1 Aset yang diperiksa (dari daftar scope + seluruh surface yang dipakai aset tersebut)

```
persistent/shares-wrappers/gated-redemption-queue/      GatedRedemptionQueueSharesWrapperLib + Factory
persistent/shares-splitter/                             SharesSplitterLib + Factory + TreasurySplitterMixin
persistent/single-asset-redemption-queue/               SingleAssetRedemptionQueueLib
persistent/single-asset-deposit-queue/                  SingleAssetDepositQueueLib
persistent/smart-accounts/                              SharePriceThrottledAssetManager(Lib|Factory),
                                                        AaveV3FlashLoanAssetManagerLib,
                                                        MorphoBlueFlashLoanAssetManagerLib,
                                                        MultiCallAccountMixin
persistent/arbitrary-value-oracles/manual-value/         ManualValueOracleLib + Factory
persistent/global-config/                                GlobalConfigLib (format*/validate helpers)
persistent/protocol-fee-reserve/                         ProtocolFeeReserveLib
persistent/fund-value-calculator/                        FundValueCalculatorRouter
persistent/address-list-registry/                        AddressListRegistry (GSN trust gate)
release/core/fund/{vault,comptroller}/                   VaultLib, ComptrollerLib
release/extensions/fee-manager/                          FeeManager + all fees
release/extensions/integration-manager/                  IntegrationManager + adapters (Bebop, ERC4626, ...)
release/extensions/external-position-manager/            ExternalPositionManager
release/extensions/policy-manager/                       CumulativeSlippageTolerance, OnlyUntrackDust…, dst.
infrastructure/gas-relayer/                              GasRelayPaymasterLib
```

### 1.2 Metode

1. **Macro architecture / invariant mapping** — untuk tiap kontrak yang memegang dana user, saya tuliskan
   invariant‑nya lalu saya coba patahkan (lihat §5).
2. **Edge‑case matrix** — oracles & staleness, share accounting & rounding, state manipulation/reentrancy,
   access control & proxy init, non‑standard token assumptions (FoT/rebasing/non‑18 decimals).
3. **Impact validation** — hanya dilaporkan bila (a) ada jalur attacker non‑privileged, atau (b) kontrol
   keamanan yang dijanjikan kontrak bisa di‑bypass, dan (c) dampaknya terukur (drain / freeze / insolvency).
4. **Reproducible PoC** — setiap temuan punya file test Foundry terpisah (tidak digabung), memakai
   **kode produksi Enzyme apa adanya** (bukan fork dari source yang dimodifikasi).

---

## 2. Temuan

Setiap temuan punya file sendiri:

* [`findings/F01-erc4626-adapter-unauthenticated.md`](findings/F01-erc4626-adapter-unauthenticated.md)
  → PoC: `tests/F01_ERC4626Adapter_NoAuth.t.sol`
* [`findings/F02-morpho-flashloan-no-initiator-check.md`](findings/F02-morpho-flashloan-no-initiator-check.md)
  → PoC: `tests/F02_MorphoFlashLoan_NoInitiatorCheck.t.sol`
* [`findings/F03-share-price-throttle.md`](findings/F03-share-price-throttle.md)
  → PoC: `tests/F03_SharePriceThrottle_InitAndAtomicOnly.t.sol`

Cara menjalankan (Windows + VSCode + Foundry): lihat [`RUNBOOK-WINDOWS.md`](RUNBOOK-WINDOWS.md).

---

## 3. Catatan penting sebelum submit

1. **Program ini menolak laporan tanpa PoC yang reproducible pada fork deployment live.** Dua dari tiga
   temuan saya di bawah ini bersifat *logic/local*, jadi sebelum submit ke Immunefi Anda harus
   mereproduksinya pada **fork** kontrak live (lihat §7 untuk cara cepat membuat harness fork).
2. Baca ulang daftar **Out of Scope** (§4) — beberapa temuan saya secara eksplisit masuk daftar itu.
   Saya menuliskannya tetap, supaya Anda tahu *kenapa* bukan bug bounty material.

---

## 4. Out of scope (dari halaman program) yang relevan dengan review ini

Program menyatakan (verbatim, disarikan):

* `GatedRedemptionQueueSharesWrapperLib` yang dipakai dengan `sharesActionTimelock`
* **first depositor share inflation attack**
* missing wrapped‑native fallback di `redeemFromQueue` (griefing native batch redemption)
* **malicious vault owner**
* external position bisa di‑remove dengan nilai negatif (debt)
* mengambil ETH/token yang "accidentally sent" ke kontrak di luar flow protokol —
  *"Common example: reports claiming an attacker can drain tokens from an adapter due to a missing
  onlyIntegrationManager check are invalid if the funds can only exist there via accidental direct
  transfers, or other non‑protocol flows."*
* front‑running contract initialization (factory memanggil `init` di tx yang sama)
* griefing queue (spam request / revert‑on‑execute) — kedua queue punya mekanisme skip
* `Convex ClaimRewards` reward tidak ter‑track; `OneInchV5Adapter` batch callback reentrancy
* **Known issues**: (1) auto‑buyback protocol fee shares → share price salah; (2) `SharesSplitter.redeemShares()`
  + exit‑fee net‑delta heuristic; (3) stale high‑water mark bila performance fee membulat ke 0

> **Konsekuensi:** F‑01 saya **tidak** memenuhi syarat submit (persis pola yang disebut di atas) dan F‑03(b)
> berada di batas "privileged address". Yang paling layak dijadikan *hardening report* adalah F‑02 + F‑03(a).

---

## 5. Hipotesis serangan yang SUDAH diuji dan terbukti bersih

Ini hasil kerja nyata — silakan lanjutkan dari titik lain, bukan dari sini.

| # | Contract | Hipotesis | Hasil |
|---|----------|-----------|-------|
| 1 | `GatedRedemptionQueueSharesWrapperLib` | `sharesPending` bisa melebihi `balanceOf(user)` sehingga `__preProcessTransfer` underflow / user lolos dari queue | **Bersih.** Satu‑satunya jalur penurunan balance adalah `kick` (burn seluruh saldo, request dihapus dulu), `redeemFromQueue` (pending dikurangi sebesar yang di‑burn), dan transfer (dibatasi `balance − pending`). Invariant terjaga di semua urutan. |
| 2 | idem | `redeemFromQueue` mencampur aset queue deposit dengan hasil redeem | **Bersih.** `balanceToDisperse` dihitung sebagai **delta** saldo, bukan saldo total. |
| 3 | idem | manipulasi `relativeSharesAllowed` (checkpoint) untuk melampaui `relativeSharesCap` | **Bersih.** Checkpoint hanya bisa menjadi *lebih ketat* (deposit yang memicu checkpoint mint setelah checkpoint; `kick` checkpoint sebelum burn). `lastRedeemed` mengunci 1 redemption per user per window. |
| 4 | idem | reentrancy via dispersal native asset (ETH ke receiver yang punya hook) | **Bersih.** `nonReentrant` pada semua entrypoint yang mengubah queue; state sudah di‑commit sebelum transfer. Griefing‑nya sudah OOS. |
| 5 | idem | `depositFromQueue` dengan `_users` duplikat / user tanpa request | **Bersih.** `__removeDepositRequest` revert ("No request"), index swap‑and‑pop benar. |
| 6 | `TreasurySplitterMixin` / `SharesSplitterLib` | double‑claim / claim melebihi porsi | **Bersih.** `claimable_i = (totalClaimed + balance)·p_i − claimed_i`; Σ claimable = balance selama Σ p_i = 100% (dipaksa saat init). State di‑update **sebelum** transfer. |
| 7 | `SharesSplitterLib.redeemShares` | redeem lebih dari yang di‑claim, atau arahkan hasil ke pihak lain | **Bersih (di luar known issue #2).** `isValidRedeemSharesCall` memaksa `sharesAmount == sharesRedeemed_` (tidak boleh `max`), kontrak = accessor, selector terbatas. Reentrancy ke Comptroller diblok `locksReentrance`; accounting konsisten bahkan bila ada callback token saat payout. |
| 8 | `SharesSplitterLib` | accounting rusak bila exit fee (burn/direct) menyala saat redeem | **Bersih.** burn = `requested − fee`, transfer fee = `fee` → total keluar = `requested`; `T+B` konstan. Hanya varian *mint* offset yang rusak = known issue #2. |
| 9 | `SingleAssetRedemptionQueueLib` | `withdrawRequest` untuk id yang belum di‑bypass; double refund | **Bersih.** `withdrawable = shutdown || id < nextQueuedId`; request dihapus sebelum transfer; `idToUser` kosong → `Unauthorized`. |
| 10 | `SingleAssetDepositQueueLib` | cancel request yang sudah diproses / double refund | **Bersih.** Request dihapus saat deposit; `cancelRequest` melihat `request.user == 0` → revert. |
| 11 | keduanya | pointer `nextQueuedId` stuck (DoS permanen) | Hanya self‑inflicted (manager bypass semua request dalam range → `total==0` → call revert). Tidak permanen. |
| 12 | `GSNRecipientMixin` (dipakai semua queue + smart account) | impersonation `__msgSender()` lewat 20 byte appended calldata | **Bersih.** Digerbang `AddressListRegistry.isInList(...)`; `isInList(0,·) == false`. |
| 13 | `AaveV3FlashLoanAssetManagerLib` | attacker memicu `executeOperation` dengan `_receiverAddress` = smart account | **Bersih.** Ada `_initiator == address(this)` **dan** `msg.sender == POOL()`. (Justru varian Morpho yang tidak punya cek initiator → F‑02.) |
| 14 | `ComptrollerLib.__redeemSharesSetup` | net‑delta heuristic dipakai untuk mencuri share user lain di luar jalur SharesSplitter | **Bersih** selain known issue #2 (butuh fee *mint* ke redeemer yang sama). |
| 15 | `ComptrollerLib.__buyShares` | double rounding / mint 0 share | **Bersih.** `sharePrice` floor lalu `sharesIssued` floor → membulat ke sisi fund; `_minSharesQuantity > 0`. |
| 16 | `VaultLib` | fungsi pemindah dana tanpa `onlyAccessor` | **Bersih.** Semua `burnShares/mintShares/withdrawAssetTo/transferShares/receiveValidatedVaultAction` = `onlyAccessor`; `notShares()` mencegah withdrawal share token. |
| 17 | `IntegrationManager` | approval vault→adapter tertinggal (dipakai `ERC4626Adapter.redeem` tanpa auth) | **Bersih.** `__postProcessCoI` reset allowance ke 0 untuk `SpendAssetsHandleType.Approve`. |
| 18 | `CumulativeSlippageTolerancePolicy` | cumulative slippage di‑write walau melebihi tolerance (uint64 cast) | **Bersih.** Return > tolerance → PolicyManager revert → seluruh state rollback. uint64 aman (tolerance < 1e18 < 2^64). |
| 19 | `FeeManager.__settleFee` | payer fee = pihak ketiga (orang lain kehilangan share) | **Bersih.** `payer` datang dari `_settlementData` yang di‑encode Comptroller dari `canonicalSender` (redeemer/buyer). |
| 20 | `BebopBlendAdapter` | order dengan maker tidak trusted / receiver bukan vault | **Bersih** untuk attacker eksternal: keduanya divalidasi di `parseAssetsForAction`, dan IM memverifikasi delta incoming asset di vault. |
| 21 | Factory‑factory persistent | front‑run `init` | OOS (init dijalankan di constructor proxy, tx yang sama). |
| 22 | `ManualValueOracleLib` | siapa saja update value | **Bersih.** `updateValue` hanya `updater`; oracle tidak melakukan staleness check (konsumen yang harus cek `lastUpdated`). |

---

## 6. Area yang **belum** tercakup (rekomendasi lanjutan)

1. ~~**`ThreeOneThirdAdapter`** (Polygon/Base/Arbitrum `0x5a1c…79A8`) tidak ada di repo publik.~~
   **SUDAH DIREVIEW** — source live diambil dari Blockscout (solc 0.8.19, optimizer 200, evmVersion `paris`,
   bukan proxy; ctor args IntegrationManager `0x92fc…884b`, BatchTrade `0xd20c…0f6e`). Hasil: lihat
   **F‑04**. Ringkas: `parseAssetsForAction` bersih (net delta per token, fee `ceilDiv`, `Transfer` handle),
   `revertOnError` di‑hardcode `true`, `takeOrder` tidak `payable` (ETH tidak didukung — keterbatasan, bukan
   loss), dan **satu** masalah = kelas F‑01 (tanpa `onlyIntegrationManager`, `_assetData` bebas) yang
   eksplisit OOS. Tidak ada temuan baru yang bisa disubmit dari area ini.
2. **Bebop dengan `TRUSTED_MAKERS_LIST_ID == 0`** → semua maker diperbolehkan; hanya mengandalkan signature
   maker. Perlu dicek di on‑chain config tiap deployment.
3. **Value interpreter / price feed** (chainlink‑like, `SimulatedAggregator`, LP fair‑value) — saya tidak
   melakukan review mendalam pada derivasi harga turunan (3‑hop, inverse rate, primitives→derivatives).
   Ini area klasik untuk "incorrect share price".
4. **`GatedRedemptionQueueSharesWrapper*` versi `Base2+`** — repo hanya memuat `Base1`; pastikan tidak ada
   base baru di implementasi live yang mengubah layout storage.
5. **Migrasi/rekonfigurasi vault** (`FundDeployer`, `ComptrollerProxy` lama, `sharesActionTimelock`) —
   interaksi dengan wrapper/queue saat migrasi belum saya uji secara dinamis.

---

## 7. Cara memperluas PoC menjadi mainnet‑fork PoC (syarat Immunefi)

Repo sudah punya harness fork siap pakai (`tests/bases/IntegrationTest.sol`):

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {IntegrationTest} from "tests/bases/IntegrationTest.sol";

contract ForkPoC is IntegrationTest {
    function setUp() public override {
        // fork mainnet / polygon / base / arbitrum pada blok terbaru
        setUpLiveBaseChainEnvironment();
        // -> core.persistent / core.release berisi ALAMAT DEPLOYMENT LIVE
    }
}
```

Jalankan dengan RPC:

```powershell
$env:ETHEREUM_NODE_MAINNET="https://eth-mainnet.g.alchemy.com/v2/XXX"
$env:ETHERSCAN_API_KEY_MAINNET="XXX"
forge test --match-contract ForkPoC -vvv
```

---

## 8. Kesimpulan

* Tidak ada jalur **unprivileged → direct theft / permanent freeze / insolvency** yang saya temukan pada
  surface yang direview.
* Tiga isu yang saya laporkan nyata di level kode, tetapi: satu persis termasuk pola OOS program (F‑01),
  satu masih latent (F‑02), satu butuh aktor privileged untuk dampak maksimalnya (F‑03).
* Nilai praktis terbesar dari dokumen ini adalah **§5 (22 hipotesis yang sudah ditutup)** dan **§6 (di mana
  harus lanjut)** — supaya usaha berikutnya tidak mengulang jalur yang sama.

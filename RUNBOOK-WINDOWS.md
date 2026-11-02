# Runbook — menjalankan PoC di Windows + VSCode + Foundry

Semua PoC di repo ini **tidak butuh fork / RPC** (self‑contained), karena memakai kode produksi Enzyme
yang di‑deploy lokal di EVM Foundry. Setiap temuan punya file test sendiri.

---

## 0. Prasyarat

| Tool | Versi yang diuji | Cek |
|---|---|---|
| Windows 10/11 + PowerShell | — | — |
| Git for Windows | ≥ 2.40 | `git --version` |
| Foundry | v1.8.x | `forge --version` |
| VSCode + ekstensi **Solidity** (JuanBlanco) | opsional | — |

Kalau Foundry belum ada:

```powershell
# PowerShell (bukan cmd), jalankan sebagai user biasa
iwr -useb https://foundry.paradigm.xyz | iex
# tutup lalu buka PowerShell baru
foundryup
forge --version
```

> Windows: Foundry butuh **Git Bash / WSL‑style PATH**. `foundryup` sudah menambahkan
> `%USERPROFILE%\.foundry\bin`. Kalau `forge` tidak dikenali: `$env:Path += ";$env:USERPROFILE\.foundry\bin"`.

---

## 1. Clone repo target + submodule

```powershell
cd $HOME\Documents
git clone https://github.com/enzymefinance/protocol.git enzyme
cd enzyme
git submodule update --init --recursive
```

> Build tanpa submodule akan gagal (`forge-std`, `openzeppelin-solc-0.6/0.7/0.8` dibutuhkan).

## 2. Salin PoC ke dalam repo

Semua file `*.t.sol` dari folder `tests/` di repo ini harus berada di dalam folder `tests/` project
Enzyme (agar `forge test` meng‑compile‑nya). Buat subfolder khusus:

```powershell
mkdir tests\arena-poc
copy <path-ke-repo-ini>\tests\F01_ERC4626Adapter_NoAuth.t.sol                    tests\arena-poc\
copy <path-ke-repo-ini>\tests\F02_MorphoFlashLoan_NoInitiatorCheck.t.sol         tests\arena-poc\
copy <path-ke-repo-ini>\tests\F03_SharePriceThrottle_InitAndAtomicOnly.t.sol     tests\arena-poc\
```

Buka folder `enzyme` di VSCode (`code .`).

## 3. Jalankan

```powershell
# 1) pastikan project bisa compile dulu
forge build

# 2) jalankan semua PoC (verbose)
forge test --match-path "tests/arena-poc/*" -vvv

# atau satu per satu:
forge test --match-path "tests/arena-poc/F01_ERC4626Adapter_NoAuth.t.sol" -vvv
forge test --match-path "tests/arena-poc/F02_MorphoFlashLoan_NoInitiatorCheck.t.sol" -vvv
forge test --match-path "tests/arena-poc/F03_SharePriceThrottle_InitAndAtomicOnly.t.sol" -vvv
```

Arti flag:

* `-vvv` → tampilkan `console2.log` (dipakai untuk membuktikan state sebelum/sesudah exploit)
* `--match-path` → hanya jalankan file itu (jangan digabung, sesuai permintaan: 1 temuan = 1 file)

## 4. Output yang diharapkan

**F‑01** (`AnyoneCanDrainAdapterAndForceArbitraryCall`) — lulus bila:

```
adapter USDC balance   : 0
attacker contract USDC : 1000000000000000000000
allowance adapter->attacker: 115792089237316195423570985008687907853269984665640564039457584007913129639935
[PASS] test_AnyoneCanDrainAdapterAndForceArbitraryCall()
```

**F‑02** (`CallbackExecutesArbitraryCallsAsVaultAssetManager`) — lulus bila attacker EOA berakhir dengan
1_000_000e18 USDC milik vault; artinya callback mengeksekusi calls sebagai asset manager vault.

**F‑03** (`A_proxyDeployedWithZeroVaultIsHijackable`) — lulus bila `getOwner()` berubah dari
`0x…5164E7` → `0x…0BAD` → `0x…1234` (re‑init berulang).

## 5. Troubleshooting

| Gejala | Penyebab / solusi |
|---|---|
| `Error: No such file or directory 'forge'` | PATH belum di‑reload; jalankan PowerShell baru atau tambahkan `$env:Path += ";$env:USERPROFILE\.foundry\bin"` |
| `Source "forge-std/Test.sol" not found` | submodule belum di‑init → `git submodule update --init --recursive` |
| `Invalid EVM version requested` | project menset `evm_version = "cancun"`; pakai Foundry versi baru (`foundryup`) |
| `Compiler run failed … openzeppelin-solc-0.8` | `lib/openzeppelin-solc-0.8` kosong → submodule belum lengkap |
| Test F‑01 gagal `adapter drained` | pastikan `usdc.mint(address(adapter), …)` terjadi **sebelum** `adapter.lend(...)` (ada di `setUp`) |
| Antivirus memblokir `forge.exe` | tambahkan exclusion folder `%USERPROFILE%\.foundry` |

## 6. Menjalankan mode fork (syarat submit Immunefi)

Tiga PoC di atas self‑contained. Untuk submit ke Immunefi Anda harus mereproduksi bug pada **fork
deployment live**. Tambahkan file baru, contoh:

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {IntegrationTest} from "tests/bases/IntegrationTest.sol";

contract F01_Fork is IntegrationTest {
    function setUp() public override {
        setUpLiveBaseChainEnvironment();     // atau Mainnet / Polygon / Arbitrum
        // core.persistent.* / core.release.* berisi alamat deployment live
    }

    function test_fork() public { /* ... */ }
}
```

```powershell
$env:ETHEREUM_NODE_MAINNET   = "https://eth-mainnet.g.alchemy.com/v2/XXX"
$env:ETHEREUM_NODE_BASE      = "https://base-mainnet.g.alchemy.com/v2/XXX"
$env:ETHERSCAN_API_KEY_MAINNET = "XXX"
forge test --match-contract F01_Fork -vvv
```

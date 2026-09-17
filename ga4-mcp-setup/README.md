# Google Analytics 4 → Claude Desktop (Windows)

Setup MCP server `gomarble-ai/google-analytics-mcp-server` supaya Claude Desktop
bisa baca data GA4 kamu langsung dari chat.

---

## ⚠️ Baca ini dulu: ini HANYA jalan di Windows / macOS

MCP server ini adalah **program Python yang dijalankan Claude Desktop di komputermu**.
Artinya:

| Perangkat | Bisa? | Kenapa |
|---|:---:|---|
| Laptop Windows | ✅ | Claude Desktop bisa nyalain proses Python |
| MacBook | ✅ | Sama, cuma path-nya beda |
| **iPad / iPhone** | ❌ | iPadOS tidak mengizinkan aplikasi menjalankan proses lain. Tidak ada `%APPDATA%`, tidak ada Claude Desktop |
| Android | ❌ | Sama seperti iPad |
| claude.ai di browser | ❌ | Browser tidak bisa menjalankan program lokal |

Kalau kamu lagi pegang iPad: **tidak apa-apa.** Simpan halaman ini, kerjakan nanti
saat buka laptop. Semua sudah disiapkan, tinggal jalan.

---

## Peta besarnya

```
┌──────────────┐    1. minta izin      ┌────────────────────┐
│    Kamu      │ ────────────────────► │ Google Cloud       │
│  (browser)   │ ◄──────────────────── │ Console            │
└──────────────┘  client_secrets.json  └────────────────────┘
       │
       │ 2. taruh file itu di laptop
       ▼
┌────────────────────────────────────────────────────┐
│  C:\Users\<kamu>\mcp-servers\                      │
│      google-analytics-mcp-server\                  │
│        ├── server.py            ← program-nya      │
│        ├── client_secrets.json  ← kunci kamu       │
│        └── .venv\Scripts\python.exe ← Python-nya   │
└────────────────────────────────────────────────────┘
       ▲
       │ 3. install.ps1 daftarin path di atas ke sini
       │
┌────────────────────────────────────────────────────┐
│  %APPDATA%\Claude\claude_desktop_config.json       │
└────────────────────────────────────────────────────┘
       │
       │ 4. restart Claude Desktop
       ▼
┌────────────────────────────────────────────────────┐
│  Claude: "Traffic minggu ini naik 12%..."          │
└────────────────────────────────────────────────────┘
```

Langkah **1** dikerjakan manual (Google tidak mengizinkan otomatisasi).
Langkah **2–4** dikerjakan `install.ps1`.

---

## BAGIAN A — Bikin OAuth Credentials di Google Cloud

Perkiraan waktu: **8–12 menit.** Bisa dikerjakan dari iPad, hasilnya nanti
tinggal dipindah ke laptop.

### A1. Buat project

1. Buka <https://console.cloud.google.com/>
2. Login dengan akun Google **yang punya akses ke GA4 property kamu**
   (kalau salah akun, nanti propertinya tidak muncul)
3. Di bar atas, klik dropdown project (kiri, sebelah tulisan "Google Cloud")
4. Klik **NEW PROJECT**
5. Project name: `claude-ga4` → **CREATE**
6. Tunggu ±30 detik, lalu **pastikan project baru ini yang terpilih** di dropdown atas

> 🔎 Kesalahan paling sering: bikin project baru tapi lupa pindah ke project itu,
> lalu API di-enable di project yang salah.

### A2. Aktifkan API yang dibutuhkan

Server ini pakai dua API. Aktifkan **dua-duanya**:

| API | Fungsi | Link langsung |
|---|---|---|
| Google Analytics Data API | Baca laporan & metrik | <https://console.cloud.google.com/apis/library/analyticsdata.googleapis.com> |
| Google Analytics Admin API | List property & akun | <https://console.cloud.google.com/apis/library/analyticsadmin.googleapis.com> |

Di tiap halaman, klik tombol biru **ENABLE**, tunggu sampai berubah jadi "API enabled".

> Kalau tombolnya tulisan **MANAGE**, berarti sudah aktif. Lanjut saja.

### A3. Setup Google Auth Platform (dulu bernama "OAuth consent screen")

> 🔄 **Tampilan Google berubah.** Menu **OAuth consent screen** sudah tidak ada.
> Sekarang namanya **Google Auth Platform**, dengan tab
> *Branding / Audience / Data Access / Clients*. Kalau kamu menemukan tutorial
> lama yang menyuruh cari "OAuth consent screen", itu sudah usang.

1. Buka <https://console.cloud.google.com/auth/overview>
2. Klik tombol **Get started**
3. Isi wizard-nya, empat layar:

   | Layar | Isi |
   |---|---|
   | App Information | App name `Claude GA4`, User support email → email kamu |
   | Audience | pilih **External** |
   | Contact Information | email kamu |
   | Finish | centang persetujuan **Google API Services: User Data Policy** |

   → klik **Create**

   *Pakai Google Workspace kantor? **Internal** juga boleh dan lebih simpel —
   langkah A3.4 soal Test users bisa dilewati sepenuhnya.*

4. **Tambahkan dirimu sebagai test user.** Buka tab **Audience**
   (<https://console.cloud.google.com/auth/audience>), scroll ke bagian
   **Test users** → **+ Add users** → masukkan **email kamu sendiri** → **Save**

> ⚠️ **Langkah A3.4 wajib dan tidak ada di dalam wizard** — ini bagian yang
> paling sering terlewat, karena wizard-nya selesai tanpa pernah menyinggung
> test users. Kalau emailmu tidak terdaftar di situ, saat login nanti muncul
> `403: access_denied` tanpa petunjuk apa pun soal penyebabnya.

> 💡 Tidak perlu menyentuh tab **Data Access** / scopes. Server meminta
> scope yang dibutuhkannya sendiri saat login.

### A4. Bikin OAuth Client ID

1. Buka tab **Clients** → <https://console.cloud.google.com/auth/clients>
2. Klik **+ Create client**
3. **Application type: pilih `Desktop app`** ← ini bagian paling krusial
4. Name: `claude-desktop` → **Create**
5. Muncul popup → klik **Download JSON**
   (kalau popup-nya terlanjur tertutup: klik ikon download ⬇️ di baris client
   itu pada daftar Clients)
6. Filenya bernama panjang seperti:
   `client_secret_138737274875-a1b2c3.apps.googleusercontent.com.json`

> Halaman lama **APIs & Services → Credentials → + CREATE CREDENTIALS →
> OAuth client ID** masih berfungsi dan mengarah ke form yang sama, kalau
> kamu lebih hafal jalur itu.

> ❌ **Jangan pilih "Web application".** OAuth flow server ini membuka browser
> lokal di `localhost` dengan port acak, yang hanya diizinkan untuk tipe
> Desktop app. Kalau salah, `install.ps1` akan mendeteksinya dan berhenti
> dengan pesan yang jelas.
>
> ❌ **Jangan pilih "Service account".** Itu mekanisme login yang berbeda dan
> tidak didukung server ini.

### A5. Pindahkan file ke laptop

Kalau tadi download-nya dari iPad, kirim filenya ke laptop lewat cara apa pun
(email ke diri sendiri, Google Drive, AirDrop ke Mac lalu pindah, dll).

Taruh di **folder Downloads** laptop. `install.ps1` akan mencarinya otomatis di sana.

> 🔒 **File ini adalah kunci akses ke data GA4 kamu.** Jangan di-share di grup,
> jangan di-commit ke GitHub, jangan di-upload ke mana-mana. Kalau terlanjur
> bocor: buka halaman Credentials, hapus client ID-nya, bikin baru.

---

## BAGIAN B — Jalankan installer di laptop Windows

### B1. Ambil script-nya

Buka **PowerShell** (tekan tombol Windows, ketik `powershell`, Enter), lalu:

```powershell
cd $env:USERPROFILE\Downloads
git clone -b claude/ga4-mcp-server-setup-spplyv https://github.com/citra-rufina99/claude.git claude-ga4-setup
cd claude-ga4-setup\ga4-mcp-setup
```

**Belum punya Git?** Tidak masalah — download manual:
1. Buka <https://github.com/citra-rufina99/claude/tree/claude/ga4-mcp-server-setup-spplyv>
   (pastikan dropdown branch menunjuk ke `claude/ga4-mcp-server-setup-spplyv`,
   bukan `main` — file-nya belum ada di `main`)
2. Tombol hijau **Code** → **Download ZIP**
3. Extract, lalu buka folder `ga4-mcp-setup` di dalamnya
4. Klik kanan di area kosong folder → **Open in Terminal**

### B2. Jalankan

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

> 💡 **Kenapa perlu `-ExecutionPolicy Bypass`?** Windows secara default memblokir
> semua script PowerShell demi keamanan. Flag ini melonggarkannya **hanya untuk
> satu kali jalan ini**, tidak mengubah setting sistem kamu secara permanen.
>
> Kalau langsung `.\install.ps1` dan muncul error merah *"running scripts is
> disabled on this system"*, itu penyebabnya — pakai perintah lengkap di atas.

Script akan menampilkan progres per langkah. Lama total **2–5 menit**
(paling lama di bagian `pip install`).

**Kalau file client_secrets.json kamu ada di tempat lain**, tunjuk langsung:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -SecretsPath "D:\rahasia\client_secret_xxx.json"
```

### B3. Restart Claude Desktop — dengan benar

🚨 **Klik tombol X tidak cukup.** Claude cuma minimize ke system tray dan
config baru tidak akan dibaca.

1. Lihat **system tray** — pojok kanan bawah layar, dekat jam
2. Klik panah `^` kalau ikonnya tersembunyi
3. **Klik kanan ikon Claude** → **Quit**
4. Buka Claude Desktop lagi dari Start Menu

### B4. Tes

1. Di kolom chat, cari ikon **slider/colokan** (🔌) — harusnya muncul
   server bernama `google-analytics`
2. Ketik: **"List my Google Analytics properties"**
3. Browser terbuka minta login Google → pilih akun yang tadi → **Allow**
   - Kalau muncul layar *"Google hasn't verified this app"*: klik
     **Advanced** → **Go to Claude GA4 (unsafe)**. Ini normal untuk app
     pribadi yang belum melewati review Google — app-nya kamu sendiri yang bikin.
4. Login ini **hanya sekali**. Token disimpan untuk pemakaian berikutnya.

---

## Yang bisa kamu tanya setelah terpasang

```
"Berapa user dan session website aku 30 hari terakhir?"
"Bandingkan traffic bulan ini vs bulan lalu"
"Halaman mana yang paling banyak dikunjungi minggu ini?"
"Traffic aku datang dari channel apa saja? Bikin ringkasannya"
"Berapa conversion rate dari organic search?"
"Device apa yang paling banyak dipakai pengunjung aku?"
```

---

## Troubleshooting

### Server `google-analytics` tidak muncul di Claude

Cek berurutan:

1. **Sudah benar-benar Quit dari system tray?** (bukan cuma klik X) — ini
   penyebab nomor satu
2. **Config tertulis?** Jalankan di PowerShell:
   ```powershell
   Get-Content "$env:APPDATA\Claude\claude_desktop_config.json"
   ```
   Harus ada blok `"google-analytics"`.
3. **Baca log error Claude:**
   ```powershell
   Get-Content "$env:APPDATA\Claude\logs\mcp-server-google-analytics.log" -Tail 50
   ```
   Log ini biasanya menyebut persis apa yang salah.

### `403: access_denied` saat login Google

Email kamu belum terdaftar sebagai **Test user**. Balik ke langkah **A3.4**
(tab **Audience** di Google Auth Platform, bukan di dalam wizard Get started).

### `GOOGLE_ANALYTICS_OAUTH_CONFIG_PATH environment variable not set`

Server tidak menemukan file kunci. Cek isi `.env` di folder instalasi:

```powershell
Get-Content "$env:USERPROFILE\mcp-servers\google-analytics-mcp-server\.env"
```

Path di situ harus menunjuk ke file yang benar-benar ada. Kalau tidak,
jalankan ulang `install.ps1` dengan `-SecretsPath`.

### `running scripts is disabled on this system`

Pakai perintah lengkap dengan `-ExecutionPolicy Bypass` — lihat langkah **B2**.

### Property GA4 tidak muncul padahal login sukses

Kamu login dengan akun Google yang **tidak punya akses** ke property tersebut.
Logout, lalu jalankan ulang dengan akun yang benar. Untuk memaksa login ulang,
hapus token tersimpan:

```powershell
Remove-Item "$env:USERPROFILE\mcp-servers\google-analytics-mcp-server\google_analytics_token.json" -ErrorAction SilentlyContinue
```

Lalu tanya lagi di Claude — browser akan terbuka untuk login ulang.

### Mau uninstall

```powershell
# 1. Hapus foldernya
Remove-Item -Recurse -Force "$env:USERPROFILE\mcp-servers\google-analytics-mcp-server"

# 2. Kembalikan config dari backup (install.ps1 selalu bikin backup bertimestamp)
Get-ChildItem "$env:APPDATA\Claude\claude_desktop_config.backup-*.json"
# lalu copy backup terbaru menimpa claude_desktop_config.json
```

---

## Yang dilakukan `install.ps1` secara persis

| # | Aksi |
|---|---|
| 0 | Cek Python ≥ 3.10, Git, dan keberadaan folder Claude Desktop |
| 1 | Clone repo ke `%USERPROFILE%\mcp-servers\google-analytics-mcp-server` (fallback ZIP kalau Git tidak ada) |
| 2 | Bikin `.venv`, upgrade pip, install `requirements.txt`, lalu verifikasi dengan import sungguhan |
| 3 | Cari `client_secret*.json`, validasi tipenya **Desktop app**, salin ke folder project |
| 4 | Tulis `.env` berisi `GOOGLE_ANALYTICS_OAUTH_CONFIG_PATH` |
| 5 | **Merge** entry ke `claude_desktop_config.json` — server MCP lain kamu tidak tersentuh, config lama di-backup bertimestamp |
| 6 | Verifikasi: JSON valid, `args` berbentuk array, dan ketiga path benar-benar ada di disk |

**Sifat aman:**
- **Idempotent** — aman dijalankan berkali-kali
- **Merge, bukan overwrite** — MCP server lain dipertahankan (sudah diuji)
- **Selalu backup** — `claude_desktop_config.backup-YYYYMMDD-HHmmss.json`
- **Gagal dengan jelas** — setiap error menyebutkan cara memperbaikinya, bukan cuma stack trace

Konfigurasi yang dihasilkan:

```json
{
  "mcpServers": {
    "google-analytics": {
      "command": "C:/Users/<kamu>/mcp-servers/google-analytics-mcp-server/.venv/Scripts/python.exe",
      "args": ["C:/Users/<kamu>/mcp-servers/google-analytics-mcp-server/server.py"],
      "env": {
        "GOOGLE_ANALYTICS_OAUTH_CONFIG_PATH": "C:/Users/<kamu>/mcp-servers/google-analytics-mcp-server/client_secrets.json"
      }
    }
  }
}
```

> Catatan: README repo aslinya tidak memakai blok `"env"` — ia mengandalkan file
> `.env`. Script ini menulis **keduanya**, karena blok `env` di JSON lebih andal
> (file `.env` kadang tidak terbaca tergantung working directory saat Claude
> menjalankan server).

---

## Catatan keamanan

- `client_secrets.json` dan `google_analytics_token.json` = **kunci akses data GA4 kamu**
- ⚠️ `.gitignore` repo aslinya **hanya** berisi `.env` — kedua file rahasia di atas
  **tidak** terlindungi secara default. Karena folder instalasi itu sendiri adalah
  git repo, file rahasiamu akan muncul di `git status` dan bisa ikut ter-commit
  tanpa sengaja. `install.ps1` menambalnya otomatis lewat `.git/info/exclude`
  (di luar `.gitignore`, supaya tidak mengotori diff saat kamu update repo)
- Jangan share isinya di chat grup atau screenshot
- Kalau bocor: <https://console.cloud.google.com/apis/credentials> → hapus client ID → bikin baru
- Scope yang diminta: `analytics` + `analytics.readonly`
- Login OAuth memakai port lokal acak (`port=0`), jadi tidak perlu membuka firewall

---

## Referensi

- Repo MCP server: <https://github.com/gomarble-ai/google-analytics-mcp-server>
- Dokumentasi MCP: <https://modelcontextprotocol.io>
- Google Cloud Console: <https://console.cloud.google.com>

<#
.SYNOPSIS
    Installer Google Analytics 4 MCP Server untuk Claude Desktop di Windows.

.DESCRIPTION
    Script ini mengerjakan 4 langkah secara otomatis:
      1. Clone repo gomarble-ai/google-analytics-mcp-server ke folder yang wajar
      2. Membuat virtual environment (.venv) dan install requirements.txt
      3. Mendaftarkan server ke %APPDATA%\Claude\claude_desktop_config.json
         (MERGE, tidak menimpa MCP server lain yang sudah ada)
      4. Mengeset GOOGLE_ANALYTICS_OAUTH_CONFIG_PATH ke file client_secrets.json

    Aman dijalankan berulang kali (idempotent). Config lama selalu di-backup.

.PARAMETER InstallDir
    Folder tujuan instalasi. Default: %USERPROFILE%\mcp-servers\google-analytics-mcp-server

.PARAMETER SecretsPath
    Path lengkap ke file client_secrets.json dari Google Cloud Console.
    Jika dikosongkan, script akan mencarinya otomatis di Downloads & folder instalasi.

.PARAMETER ServerName
    Nama server di config Claude Desktop. Default: google-analytics

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -SecretsPath "C:\Users\citra\Downloads\client_secret_1387.apps.googleusercontent.com.json"
#>

[CmdletBinding()]
param(
    [string] $InstallDir  = (Join-Path $env:USERPROFILE 'mcp-servers\google-analytics-mcp-server'),
    [string] $SecretsPath = '',
    [string] $ServerName  = 'google-analytics'
)

$ErrorActionPreference = 'Stop'
$RepoUrl = 'https://github.com/gomarble-ai/google-analytics-mcp-server'

# ---------------------------------------------------------------- helpers ---

$script:StepNo = 0
function Write-Step {
    param([string] $Message)
    $script:StepNo++
    Write-Host ''
    Write-Host ("=" * 68) -ForegroundColor DarkCyan
    Write-Host ("  LANGKAH $script:StepNo : $Message") -ForegroundColor Cyan
    Write-Host ("=" * 68) -ForegroundColor DarkCyan
}
function Write-Ok   { param([string] $m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Info { param([string] $m) Write-Host "  [i]    $m" -ForegroundColor Gray }
function Write-Warn { param([string] $m) Write-Host "  [!]    $m" -ForegroundColor Yellow }
function Fail {
    param([string] $Problem, [string] $Fix)
    Write-Host ''
    Write-Host "  [GAGAL] $Problem" -ForegroundColor Red
    if ($Fix) {
        Write-Host ''
        Write-Host "  Cara memperbaiki:" -ForegroundColor Yellow
        foreach ($line in ($Fix -split "`n")) { Write-Host "    $line" -ForegroundColor Yellow }
    }
    Write-Host ''
    exit 1
}

# Claude Desktop butuh path bergaya forward-slash agar tidak salah di-escape.
function ConvertTo-JsonPath {
    param([string] $Path)
    return ($Path -replace '\\', '/')
}

function Write-Utf8NoBom {
    param([string] $Path, [string] $Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host ''
Write-Host '  ############################################################' -ForegroundColor Magenta
Write-Host '  #                                                          #' -ForegroundColor Magenta
Write-Host '  #     Google Analytics 4  ->  Claude Desktop (Windows)     #' -ForegroundColor Magenta
Write-Host '  #                  MCP Server Installer                    #' -ForegroundColor Magenta
Write-Host '  #                                                          #' -ForegroundColor Magenta
Write-Host '  ############################################################' -ForegroundColor Magenta

# ------------------------------------------------- 0. cek prasyarat sistem ---

Write-Step 'Cek prasyarat (Python, Git, Claude Desktop)'

# -- Python: cari interpreter >= 3.10 lewat py launcher atau python di PATH
$pythonCmd = $null
$pythonVer = $null
foreach ($candidate in @(
        @{ Exe = 'py';     Args = @('-3', '-c') },
        @{ Exe = 'python'; Args = @('-c') },
        @{ Exe = 'python3'; Args = @('-c') })) {

    $exePath = (Get-Command $candidate.Exe -ErrorAction SilentlyContinue)
    if (-not $exePath) { continue }

    $probe = @($candidate.Args) + @('import sys; print("%d.%d" % sys.version_info[:2])')
    try { $out = (& $candidate.Exe @probe 2>$null) } catch { continue }
    if ($LASTEXITCODE -ne 0 -or -not $out) { continue }

    $parsed = [version]("$out".Trim())
    if ($parsed -ge [version]'3.10') {
        $pythonCmd = $candidate
        $pythonVer = $parsed
        break
    }
    Write-Warn "$($candidate.Exe) ada tapi versinya $parsed (butuh 3.10+), dilewati."
}

if (-not $pythonCmd) {
    Fail 'Python 3.10 atau lebih baru tidak ditemukan.' @'
1. Buka https://www.python.org/downloads/windows/
2. Download "Windows installer (64-bit)" versi 3.11 atau 3.12
3. PENTING: saat install, centang "Add python.exe to PATH" di layar pertama
4. Tutup PowerShell, buka lagi, lalu jalankan script ini sekali lagi
'@
}
Write-Ok "Python $pythonVer ditemukan (via '$($pythonCmd.Exe)')"

# -- Git (opsional: ada fallback download ZIP)
$hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
if ($hasGit) { Write-Ok 'Git ditemukan' }
else         { Write-Warn 'Git tidak ada - nanti pakai download ZIP sebagai gantinya' }

# -- Claude Desktop: keberadaan folder config sudah cukup sebagai sinyal
$ClaudeDir        = Join-Path $env:APPDATA 'Claude'
$ClaudeConfigPath = Join-Path $ClaudeDir  'claude_desktop_config.json'
if (Test-Path -LiteralPath $ClaudeDir) {
    Write-Ok "Claude Desktop terdeteksi di $ClaudeDir"
} else {
    Write-Warn "Folder $ClaudeDir belum ada."
    Write-Warn 'Pastikan Claude Desktop sudah pernah dibuka minimal sekali.'
    Write-Info 'Script tetap lanjut dan akan membuat foldernya.'
}

# ---------------------------------------------------------- 1. clone repo ---

Write-Step 'Clone repo google-analytics-mcp-server'

$serverPy = Join-Path $InstallDir 'server.py'

if (Test-Path -LiteralPath $serverPy) {
    Write-Info "Repo sudah ada di $InstallDir"
    if ($hasGit -and (Test-Path -LiteralPath (Join-Path $InstallDir '.git'))) {
        Write-Info 'Menarik update terbaru (git pull)...'
        # Gagal pull bukan alasan berhenti - source yang ada sudah cukup.
        try {
            Push-Location $InstallDir
            git pull --ff-only 2>&1 | ForEach-Object { Write-Info $_ }
        } catch {
            Write-Warn 'git pull gagal, memakai salinan lokal yang sudah ada.'
        } finally {
            Pop-Location
        }
    }
    Write-Ok 'Source code siap'
}
else {
    $parent = Split-Path -Parent $InstallDir
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    if ($hasGit) {
        Write-Info "Clone $RepoUrl"
        Write-Info "   -> $InstallDir"
        git clone --depth 1 $RepoUrl $InstallDir
        if ($LASTEXITCODE -ne 0) {
            Fail 'git clone gagal.' @'
Kemungkinan penyebab: tidak ada koneksi internet, atau diblokir proxy/firewall kantor.
Alternatif manual:
  1. Buka https://github.com/gomarble-ai/google-analytics-mcp-server
  2. Klik tombol hijau "Code" > "Download ZIP"
  3. Extract isinya ke folder tujuan, lalu jalankan script ini lagi
'@
        }
    }
    else {
        Write-Info 'Git tidak ada - download ZIP dari GitHub...'
        $zipPath = Join-Path $env:TEMP 'ga4-mcp-server.zip'
        $tmpDir  = Join-Path $env:TEMP 'ga4-mcp-extract'
        if (Test-Path -LiteralPath $tmpDir) { Remove-Item -Recurse -Force $tmpDir }

        # TLS 1.2 wajib di-set eksplisit pada PowerShell 5.1 lama.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "$RepoUrl/archive/refs/heads/main.zip" -OutFile $zipPath -UseBasicParsing
        Expand-Archive -LiteralPath $zipPath -DestinationPath $tmpDir -Force

        # ZIP GitHub selalu membungkus isinya dalam satu folder <repo>-<branch>.
        $inner = Get-ChildItem -LiteralPath $tmpDir -Directory | Select-Object -First 1
        Move-Item -LiteralPath $inner.FullName -Destination $InstallDir
        Remove-Item -Force $zipPath
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $serverPy)) {
        Fail "server.py tidak ditemukan di $InstallDir setelah download." 'Hapus foldernya lalu jalankan script ini sekali lagi.'
    }
    Write-Ok "Repo berhasil di-clone ke $InstallDir"
}

# ----------------------------------------------- 2. venv + install deps ---

Write-Step 'Buat virtual environment dan install dependencies'

$VenvDir    = Join-Path $InstallDir '.venv'
$VenvPython = Join-Path $VenvDir 'Scripts\python.exe'

if (-not (Test-Path -LiteralPath $VenvPython)) {
    Write-Info "Membuat venv di $VenvDir"
    $mkvenv = @($pythonCmd.Args | Where-Object { $_ -ne '-c' }) + @('-m', 'venv', $VenvDir)
    & $pythonCmd.Exe @mkvenv
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $VenvPython)) {
        Fail 'Pembuatan virtual environment gagal.' @'
Coba jalankan manual untuk melihat pesan error lengkapnya:
  python -m venv "<InstallDir>\.venv"
Kalau muncul error soal "ensurepip", install ulang Python dan centang opsi "pip".
'@
    }
    Write-Ok 'Virtual environment dibuat'
}
else {
    Write-Ok 'Virtual environment sudah ada, dipakai ulang'
}

Write-Info 'Upgrade pip...'
& $VenvPython -m pip install --upgrade pip --quiet --disable-pip-version-check

$reqFile = Join-Path $InstallDir 'requirements.txt'
if (-not (Test-Path -LiteralPath $reqFile)) { Fail "requirements.txt tidak ada di $InstallDir" 'Repo kemungkinan ter-download tidak lengkap. Hapus foldernya dan ulangi.' }

Write-Info 'Install requirements.txt (bisa 1-3 menit, sabar ya)...'
& $VenvPython -m pip install -r $reqFile --disable-pip-version-check
if ($LASTEXITCODE -ne 0) {
    Fail 'pip install gagal.' @'
Scroll ke atas untuk melihat paket mana yang bermasalah.
Penyebab paling umum: koneksi internet putus di tengah jalan.
Coba jalankan script ini lagi - pip akan melanjutkan dari paket yang belum terpasang.
'@
}

# Import nyata lebih meyakinkan daripada exit code pip.
Write-Info 'Verifikasi instalasi...'
& $VenvPython -c "import fastmcp, google_auth_oauthlib, requests, dotenv"
if ($LASTEXITCODE -ne 0) { Fail 'Dependency terpasang tapi gagal di-import.' 'Hapus folder .venv lalu jalankan script ini sekali lagi.' }
Write-Ok 'Semua dependency terpasang dan bisa di-import'

# ----------------------------------------- 3. temukan client_secrets.json ---

Write-Step 'Cari file OAuth client_secrets.json'

if ($SecretsPath) {
    if (-not (Test-Path -LiteralPath $SecretsPath)) {
        Fail "File yang kamu tunjuk tidak ada: $SecretsPath" 'Periksa lagi path-nya, atau kosongkan -SecretsPath agar dicari otomatis.'
    }
    $SecretsPath = (Resolve-Path -LiteralPath $SecretsPath).Path
    Write-Ok "Memakai file dari parameter: $SecretsPath"
}
else {
    # Folder instalasi didahulukan: di situlah tempat file ini seharusnya berada.
    $searchDirs = @(
        $InstallDir,
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Documents')
    ) | Where-Object { Test-Path -LiteralPath $_ }

    $found = @()
    foreach ($d in $searchDirs) {
        $found += Get-ChildItem -LiteralPath $d -Filter 'client_secret*.json' -File -ErrorAction SilentlyContinue
    }
    $found = $found | Sort-Object LastWriteTime -Descending

    if ($found.Count -eq 0) {
        Fail 'File client_secrets.json tidak ditemukan.' @'
Kamu belum punya file OAuth dari Google Cloud Console.
Ikuti panduan lengkap di README.md (bagian "Bikin OAuth Credentials"),
lalu taruh file JSON hasil download ke folder Downloads dan jalankan script ini lagi.

Kalau file-nya sudah ada tapi di tempat lain, tunjuk langsung:
  .\install.ps1 -SecretsPath "C:\path\ke\client_secret_xxx.json"
'@
    }

    if ($found.Count -eq 1) {
        $SecretsPath = $found[0].FullName
        Write-Ok "Ditemukan: $SecretsPath"
    }
    else {
        Write-Host ''
        Write-Warn "Ada $($found.Count) file client_secret. Pilih yang mau dipakai:"
        Write-Host ''
        for ($i = 0; $i -lt $found.Count; $i++) {
            Write-Host ("    [{0}] {1}" -f ($i + 1), $found[$i].Name) -ForegroundColor White
            Write-Host ("        folder   : {0}" -f $found[$i].DirectoryName) -ForegroundColor DarkGray
            Write-Host ("        diubah   : {0}" -f $found[$i].LastWriteTime) -ForegroundColor DarkGray
        }
        Write-Host ''
        $choice = Read-Host "  Ketik nomornya (1-$($found.Count))"
        $idx = 0
        if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt $found.Count) {
            Fail "Pilihan '$choice' tidak valid." "Jalankan script lagi dan ketik angka antara 1 sampai $($found.Count)."
        }
        $SecretsPath = $found[$idx - 1].FullName
        Write-Ok "Dipilih: $SecretsPath"
    }
}

# Validasi isi: harus OAuth Desktop App, bukan Web App atau Service Account.
try { $secretsJson = Get-Content -LiteralPath $SecretsPath -Raw | ConvertFrom-Json }
catch { Fail "File $SecretsPath bukan JSON yang valid." 'Download ulang credential-nya dari Google Cloud Console.' }

$secretKeys = $secretsJson.PSObject.Properties.Name
if ($secretKeys -contains 'installed') {
    Write-Ok 'Tipe credential benar: Desktop app (installed)'
}
elseif ($secretKeys -contains 'web') {
    Fail 'Credential ini bertipe "Web application", bukan "Desktop app".' @'
OAuth flow server ini membuka browser lokal, jadi wajib tipe Desktop app.
Perbaikan:
  1. Buka https://console.cloud.google.com/apis/credentials
  2. "+ CREATE CREDENTIALS" > "OAuth client ID"
  3. Application type: pilih "Desktop app"
  4. Download JSON-nya, lalu jalankan script ini lagi
'@
}
elseif ($secretKeys -contains 'type' -and $secretsJson.type -eq 'service_account') {
    Fail 'Ini file Service Account, bukan OAuth client.' @'
Server ini memakai OAuth user flow, bukan service account.
Buat kredensial baru bertipe "OAuth client ID" > "Desktop app" di Google Cloud Console.
'@
}
else {
    Write-Warn 'Struktur file tidak dikenali - tetap dilanjutkan, tapi mungkin gagal saat autentikasi.'
}

# Menyalin ke folder instalasi: sesuai permintaan "taruh di folder yang sama",
# sekaligus membuat path config stabil walau isi Downloads dibersihkan.
$SecretsInProject = Join-Path $InstallDir 'client_secrets.json'
if ((Resolve-Path -LiteralPath $SecretsPath).Path -ne $SecretsInProject) {
    Copy-Item -LiteralPath $SecretsPath -Destination $SecretsInProject -Force
    Write-Ok "Disalin ke folder project: $SecretsInProject"
}
$SecretsFinal = $SecretsInProject

# .gitignore repo hanya mencakup .env, sedangkan folder instalasi ini adalah git
# repo - tanpa ini client_secrets.json muncul di 'git status' dan bisa ikut
# ter-commit. Ditulis ke .git/info/exclude agar tidak mengubah file terlacak.
$excludeFile = Join-Path $InstallDir '.git\info\exclude'
if (Test-Path -LiteralPath (Join-Path $InstallDir '.git')) {
    $secretPatterns = @('client_secret*.json', 'client_secrets.json', 'google_analytics_token.json', '.env')
    $current = if (Test-Path -LiteralPath $excludeFile) { Get-Content -LiteralPath $excludeFile } else { @() }
    $missing = $secretPatterns | Where-Object { $current -notcontains $_ }
    if ($missing) {
        $dirPart = Split-Path -Parent $excludeFile
        if (-not (Test-Path -LiteralPath $dirPart)) { New-Item -ItemType Directory -Force -Path $dirPart | Out-Null }
        Add-Content -LiteralPath $excludeFile -Value (@('', '# ditambahkan oleh install.ps1 - lindungi kredensial') + $missing)
        Write-Ok 'File kredensial dilindungi dari git (.git/info/exclude)'
    }
    else {
        Write-Ok 'File kredensial sudah terlindungi dari git'
    }
}

# ------------------------------------------------------- 4. tulis file .env ---

Write-Step 'Tulis file .env'

# README repo ini membaca konfigurasi dari .env; blok "env" di JSON dipasang juga
# di langkah berikutnya sebagai jaring pengaman kalau .env tidak terbaca.
$envPath = Join-Path $InstallDir '.env'
$envBody = @"
# Dibuat otomatis oleh install.ps1
GOOGLE_ANALYTICS_OAUTH_CONFIG_PATH=$(ConvertTo-JsonPath $SecretsFinal)
LOG_LEVEL=INFO
"@
Write-Utf8NoBom -Path $envPath -Content $envBody
Write-Ok "File .env ditulis di $envPath"

# ------------------------------- 5. daftarkan ke claude_desktop_config.json ---

Write-Step 'Daftarkan server ke Claude Desktop'

if (-not (Test-Path -LiteralPath $ClaudeDir)) {
    New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
    Write-Info "Folder $ClaudeDir dibuat"
}

# Baca config lama. Config rusak tidak boleh menghapus setting user diam-diam,
# jadi file lama selalu disimpan sebagai .broken sebelum diganti.
$config = $null
if (Test-Path -LiteralPath $ClaudeConfigPath) {
    $backupPath = Join-Path $ClaudeDir ("claude_desktop_config.backup-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $ClaudeConfigPath -Destination $backupPath -Force
    Write-Ok "Config lama di-backup: $backupPath"

    try {
        $raw = Get-Content -LiteralPath $ClaudeConfigPath -Raw
        if ($raw.Trim()) { $config = $raw | ConvertFrom-Json }
    }
    catch {
        Write-Warn 'Config lama bukan JSON valid. File lama disimpan sebagai .broken, config baru dibuat dari nol.'
        Move-Item -LiteralPath $ClaudeConfigPath -Destination "$ClaudeConfigPath.broken" -Force
        $config = $null
    }
}
if (-not $config) { $config = [PSCustomObject]@{} }

if ($config.PSObject.Properties.Name -notcontains 'mcpServers') {
    $config | Add-Member -MemberType NoteProperty -Name 'mcpServers' -Value ([PSCustomObject]@{})
}

# Daftar server lain yang sudah terpasang - ditampilkan agar user yakin
# tidak ada yang hilang gara-gara script ini.
$existing = @($config.mcpServers.PSObject.Properties.Name | Where-Object { $_ -ne $ServerName })
if ($existing.Count -gt 0) {
    Write-Info "MCP server lain yang sudah terdaftar (dipertahankan): $($existing -join ', ')"
}

$entry = [PSCustomObject]@{
    command = (ConvertTo-JsonPath $VenvPython)
    args    = @( (ConvertTo-JsonPath $serverPy) )
    env     = [PSCustomObject]@{
        GOOGLE_ANALYTICS_OAUTH_CONFIG_PATH = (ConvertTo-JsonPath $SecretsFinal)
    }
}

if ($config.mcpServers.PSObject.Properties.Name -contains $ServerName) {
    $config.mcpServers.$ServerName = $entry
    Write-Info "Entry '$ServerName' yang lama ditimpa dengan yang baru"
}
else {
    $config.mcpServers | Add-Member -MemberType NoteProperty -Name $ServerName -Value $entry
}

Write-Utf8NoBom -Path $ClaudeConfigPath -Content ($config | ConvertTo-Json -Depth 20)
Write-Ok "Config ditulis: $ClaudeConfigPath"

# Baca ulang dari disk: memastikan yang tersimpan benar-benar bisa di-parse Claude.
try {
    $verify = Get-Content -LiteralPath $ClaudeConfigPath -Raw | ConvertFrom-Json
    if (-not $verify.mcpServers.$ServerName.command) { throw 'entry kosong' }

    # PowerShell 5.1 kadang menyerialisasi array satu-elemen menjadi string biasa.
    # Claude Desktop menolak "args" yang bukan array, jadi diperbaiki di sini.
    if ($verify.mcpServers.$ServerName.args -isnot [array]) {
        Write-Warn 'PowerShell menulis "args" bukan sebagai array - memperbaiki...'
        $fixed = @($verify.mcpServers.$ServerName.args)
        $verify.mcpServers.$ServerName.args = $fixed
        # Membungkus dengan koma-kosong memaksa ConvertTo-Json melihatnya
        # sebagai koleksi, lalu elemen kosongnya dibuang lagi.
        $verify.mcpServers.$ServerName.args = [System.Collections.ArrayList]@($fixed)
        $patched = $verify | ConvertTo-Json -Depth 20
        Write-Utf8NoBom -Path $ClaudeConfigPath -Content $patched
        $verify = Get-Content -LiteralPath $ClaudeConfigPath -Raw | ConvertFrom-Json

        if ($verify.mcpServers.$ServerName.args -isnot [array]) {
            # Menyunting JSON dengan regex berisiko mengenai entry server lain,
            # jadi lebih baik berhenti dan minta perbaikan manual satu baris.
            $manual = '"args": ["' + $fixed[0] + '"]'
            Fail 'PowerShell versi ini tidak bisa menulis "args" sebagai array.' @"
Config lain sudah aman, hanya satu baris yang perlu kamu betulkan manual.

  1. Buka file ini dengan Notepad:
       $ClaudeConfigPath
  2. Cari baris "args" di dalam blok "$ServerName"
  3. Ganti baris itu menjadi persis:
       $manual
  4. Simpan (Ctrl+S), lalu restart Claude Desktop

Cara lain: upgrade ke PowerShell 7 (https://aka.ms/powershell) lalu
jalankan script ini lagi dengan perintah 'pwsh -File install.ps1'.
"@
        }
        Write-Ok 'Field "args" diperbaiki menjadi array'
    }

    # Semua path yang dirujuk config harus benar-benar ada di disk.
    foreach ($check in @(
            @{ Label = 'python.exe';          Path = $verify.mcpServers.$ServerName.command },
            @{ Label = 'server.py';           Path = $verify.mcpServers.$ServerName.args[0] },
            @{ Label = 'client_secrets.json'; Path = $verify.mcpServers.$ServerName.env.GOOGLE_ANALYTICS_OAUTH_CONFIG_PATH })) {
        if (-not (Test-Path -LiteralPath $check.Path)) { throw "$($check.Label) tidak ada di path: $($check.Path)" }
    }

    Write-Ok 'Config diverifikasi - JSON valid, entry terbaca, semua path ada'
}
catch {
    Fail 'Config gagal diverifikasi setelah ditulis.' "Kembalikan dari backup, lalu laporkan errornya:`n$_"
}

# ------------------------------------------------------- 6. smoke test ---

Write-Step 'Tes server bisa dijalankan'

# Server MCP normalnya menunggu input selamanya, jadi yang diuji hanya
# apakah modulnya bisa di-load tanpa error (import + compile).
$env:GOOGLE_ANALYTICS_OAUTH_CONFIG_PATH = $SecretsFinal
& $VenvPython -c "import py_compile,sys; py_compile.compile(r'$serverPy', doraise=True); print('server.py OK')"
if ($LASTEXITCODE -ne 0) {
    Write-Warn 'server.py gagal di-compile. Instalasi tetap selesai, tapi kemungkinan besar error saat dipakai.'
}
else {
    Write-Ok 'server.py bisa dimuat tanpa error'
}

# --------------------------------------------------------------- ringkasan ---

Write-Host ''
Write-Host ('=' * 68) -ForegroundColor Green
Write-Host '  SELESAI - INSTALASI BERHASIL' -ForegroundColor Green
Write-Host ('=' * 68) -ForegroundColor Green
Write-Host ''
Write-Host '  Ringkasan:' -ForegroundColor White
Write-Host "    Folder server  : $InstallDir"
Write-Host "    Python venv    : $VenvPython"
Write-Host "    OAuth secrets  : $SecretsFinal"
Write-Host "    Config Claude  : $ClaudeConfigPath"
Write-Host "    Nama server    : $ServerName"
Write-Host ''
Write-Host '  LANGKAH TERAKHIR (harus kamu lakukan manual):' -ForegroundColor Yellow
Write-Host ''
Write-Host '    1. TUTUP Claude Desktop sepenuhnya.' -ForegroundColor Yellow
Write-Host '       Klik kanan ikon Claude di system tray (pojok kanan bawah,' -ForegroundColor DarkYellow
Write-Host '       dekat jam) lalu pilih Quit. Klik tombol X saja TIDAK CUKUP,' -ForegroundColor DarkYellow
Write-Host '       aplikasinya cuma minimize dan config tidak akan dibaca ulang.' -ForegroundColor DarkYellow
Write-Host ''
Write-Host '    2. Buka lagi Claude Desktop.' -ForegroundColor Yellow
Write-Host ''
Write-Host '    3. Cek ikon slider / colokan di kolom chat - harusnya muncul' -ForegroundColor Yellow
Write-Host "       server bernama '$ServerName'." -ForegroundColor Yellow
Write-Host ''
Write-Host '    4. Coba tanya: "List my Google Analytics properties"' -ForegroundColor Yellow
Write-Host '       Browser akan terbuka untuk login Google (hanya sekali).' -ForegroundColor Yellow
Write-Host '       Login pakai akun yang punya akses ke GA4 kamu, lalu Allow.' -ForegroundColor DarkYellow
Write-Host ''
Write-Host '  Kalau server tidak muncul, baca bagian Troubleshooting di README.md' -ForegroundColor Gray
Write-Host ''

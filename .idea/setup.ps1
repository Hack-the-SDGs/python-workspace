#Requires -Version 5.1
<#
  Hack the SDGs 2026
  powershell -ExecutionPolicy Bypass -File .\camp-setup.ps1
#>

$ErrorActionPreference = 'Continue'  # 各步驟自行容錯，不整段中止

# ---------- 設定區 ----------
$TempDir    = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Hack-the-SDGs'
$SetupUrl   = 'https://raw.githubusercontent.com/Hack-the-SDGs/minethon/main/pc_setup/setup.ps1'
$RepoUrl    = 'https://github.com/Hack-the-SDGs/python-workspace'
$ProjectDir = 'D:\python-workspace'
$NotesUrl   = 'https://hackmd.io/@NTUST-CSIE-CAMP/r1OcUZX7Mx'

# ---------- 輔助函式 ----------
function Write-Step { param([string]$Msg) Write-Host "`n========== $Msg ==========" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "[OK] $Msg" -ForegroundColor Green }
function Write-Note { param([string]$Msg) Write-Host "[!]  $Msg" -ForegroundColor Yellow }

# 從登錄檔重新載入 PATH，讓「剛用 winget 裝好的 git / uv」在本 session 立即可用
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path','Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = @($machine, $user) -join ';'
}

function Install-WithWinget {
    param([string]$Id)
    Write-Step "安裝 $Id"
    winget install -e --id $Id --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -eq 0) { Write-Ok "$Id 安裝完成" }
    else { Write-Note "$Id winget 回傳碼 $LASTEXITCODE（多半是「已安裝」或使用者取消，可忽略）" }
}

# ---------- 前置檢查 ----------
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Note '找不到 winget。請先從 Microsoft Store 安裝「應用程式安裝程式 (App Installer)」再執行本腳本。'
    return
}

# ---------- Step 0：暫存目錄 ----------
Write-Step "建立暫存目錄：$TempDir"
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
Write-Ok $TempDir

# ---------- Step 1：初始化腳本（互動，需輸入密碼）----------
Write-Step '執行電腦初始化腳本 setup.ps1'
$setupLocal = Join-Path $TempDir 'setup.ps1'
try {
    Invoke-WebRequest -Uri $SetupUrl -OutFile $setupLocal -UseBasicParsing
    Unblock-File $setupLocal
    Write-Note '接下來會進入初始化腳本，過程中「需要你手動輸入密碼」，輸入完成後腳本才會繼續。'
    & $setupLocal
    Write-Ok '初始化腳本執行結束'
} catch {
    Write-Note "初始化腳本下載或執行失敗：$($_.Exception.Message)"
}

# ---------- Step 2：安裝軟體（安裝目錄用預設）----------
Install-WithWinget 'Mojang.MinecraftLauncher'
Install-WithWinget 'JetBrains.PyCharm.Community'
Install-WithWinget 'Git.Git'
Install-WithWinget 'astral-sh.uv'

# ---------- Step 3：更新本 session 的 PATH ----------
Write-Step '重新載入環境變數 PATH'
Update-SessionPath
Write-Ok 'PATH 已更新（git / uv 應可直接使用）'

# ---------- Step 4：開啟課堂筆記 ----------
Write-Step '開啟 HackMD 課堂筆記'
Start-Process $NotesUrl
Write-Ok $NotesUrl

# ---------- Step 5：取得專案 + uv sync ----------
Write-Step "取得課程專案至 $ProjectDir"
if (-not (Test-Path 'D:\')) {
    Write-Note '找不到 D:\ 磁碟，無法 clone 至 D:\python-workspace，請確認此機器有 D 槽。'
} elseif (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Note 'git 尚未就緒（可能需重開 PowerShell），略過 clone。'
} else {
    if (Test-Path (Join-Path $ProjectDir '.git')) {
        Write-Note "$ProjectDir 已存在，改為 git pull 更新"
        git -C $ProjectDir pull
    } elseif (Test-Path $ProjectDir) {
        Write-Note "$ProjectDir 已存在但不是 git 專案，略過 clone（請人工確認）"
    } else {
        git clone $RepoUrl $ProjectDir
    }

    if ((Test-Path $ProjectDir) -and (Get-Command uv -ErrorAction SilentlyContinue)) {
        Write-Step '執行 uv sync（安裝相依套件）'
        Push-Location $ProjectDir
        uv sync
        Pop-Location
        Write-Ok 'uv sync 完成'
    } else {
        Write-Note 'uv 尚未就緒或專案不存在，略過 uv sync。'
    }
}

# ---------- Step 6：以 PyCharm 開啟專案 ----------
Write-Step '以 PyCharm 開啟專案'
$pycharm = Get-ChildItem -Path @(
    "$env:ProgramFiles\JetBrains",
    "${env:ProgramFiles(x86)}\JetBrains",
    "$env:LOCALAPPDATA\Programs\JetBrains",
    "$env:LOCALAPPDATA\JetBrains\Toolbox\apps"
) -Recurse -Filter 'pycharm64.exe' -ErrorAction SilentlyContinue | Select-Object -First 1

if ($pycharm) {
    Start-Process -FilePath $pycharm.FullName -ArgumentList "`"$ProjectDir`""
    Write-Ok "已用 PyCharm 開啟 $ProjectDir"
} else {
    Write-Note '找不到 PyCharm 執行檔，請手動開啟 PyCharm 並打開 D:\python-workspace（剛裝完可能需重登或重開機才在預期路徑）。'
}

Write-Host "`n全部步驟結束。" -ForegroundColor Green

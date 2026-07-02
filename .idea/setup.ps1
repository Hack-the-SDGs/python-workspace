#Requires -Version 5.1
<#
  Hack the SDGs 2026
  powershell -ExecutionPolicy Bypass -File .\camp-setup.ps1
#>

$ErrorActionPreference = 'Continue'  # 各步驟自行容錯，不整段中止

# ---------- 設定區 ----------
$TempDir    = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Hack-the-SDGs'
$ShareDir   = Join-Path $env:PUBLIC 'Hack-the-SDGs'  # 跨帳戶共用：降權後的使用者工作也讀得到
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
    winget install -e --id $Id --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -eq 0) { Write-Ok "$Id 安裝完成" }
    else { Write-Note "$Id winget 回傳碼 $LASTEXITCODE（多半是「已安裝」或使用者取消，可忽略）" }
}

# 以「目前登入的桌面使用者」權限執行指定 .ps1（即使本腳本以系統管理員身分執行也會降權）。
# 目的：讓 uv sync 建立的 .venv / uv 快取落在該使用者帳戶，PyCharm 才讀得到；
# 若用系統管理員（或其他 Administrator 帳戶）執行 uv sync，IDE 會抓不到環境。
function Invoke-AsInteractiveUser {
    param([Parameter(Mandatory)][string]$File)
    $user = (Get-CimInstance Win32_ComputerSystem).UserName  # 目前互動桌面使用者
    if (-not $user) { Write-Note '抓不到互動使用者，改用目前權限直接執行'; & $File; return }

    $log  = Join-Path $ShareDir 'user-init.log'
    $task = 'HackSDGs-UserInit'
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"& '$File' *> '$log'`""
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $task

    # ponytail: naive 輪詢等它跑完；uv sync 遠比 2 秒久所以夠用，卡住的話上限 10 分鐘
    Start-Sleep -Seconds 2
    $waited = 0
    while ((Get-ScheduledTask -TaskName $task).State -eq 'Running' -and $waited -lt 600) {
        Start-Sleep -Seconds 3; $waited += 3
    }
    Unregister-ScheduledTask -TaskName $task -Confirm:$false
    if (Test-Path $log) { Get-Content $log | Write-Host }
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
    Write-Note '接下來會進入初始化腳本'
    & $setupLocal
    Write-Ok '初始化腳本執行結束'
} catch {
    Write-Note "初始化腳本下載或執行失敗：$($_.Exception.Message)"
}

# ---------- Step 2：安裝軟體（安裝目錄用預設）----------
Install-WithWinget 'Mojang.MinecraftLauncher'
Install-WithWinget 'JetBrains.PyCharm.Community'
Install-WithWinget 'Git.Git'
Install-WithWinget 'OpenJS.NodeJS.LTS'
Install-WithWinget 'astral-sh.uv'

# ---------- Step 3：更新本 session 的 PATH ----------
Write-Step '重新載入環境變數 PATH'
Update-SessionPath
Write-Ok 'PATH 已更新（git / uv 應可直接使用）'

# ---------- Step 4：產生「使用者權限初始化」腳本 ----------
# 開筆記、clone、uv sync、開 PyCharm 全部改用桌面使用者權限跑，
# 避免以系統管理員身分建立 .venv 導致 PyCharm 讀不到環境。
Write-Step '準備使用者權限初始化腳本'
New-Item -ItemType Directory -Path $ShareDir -Force | Out-Null
$userInit = Join-Path $ShareDir 'user-init.ps1'
# ponytail: 用單引號 here-string（不做內插），$ProjectDir 等變數在子腳本自己定義；設定值與上方常數重複但這是 set-once 常數，可接受
@"
`$ProjectDir = '$ProjectDir'
`$RepoUrl    = '$RepoUrl'
`$NotesUrl   = '$NotesUrl'
"@ + @'

Write-Host '開啟 HackMD 課堂筆記'
Start-Process $NotesUrl

if (-not (Test-Path 'D:\')) {
    Write-Host '[!] 找不到 D:\ 磁碟，略過 clone / uv sync'
} elseif (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host '[!] git 尚未就緒（可能需重開 PowerShell），略過 clone'
} else {
    if (Test-Path (Join-Path $ProjectDir '.git')) {
        Write-Host "$ProjectDir 已存在，改為 git pull 更新"
        git -C $ProjectDir pull
    } elseif (Test-Path $ProjectDir) {
        Write-Host "[!] $ProjectDir 已存在但不是 git 專案，略過 clone"
    } else {
        git clone $RepoUrl $ProjectDir
    }

    if ((Test-Path $ProjectDir) -and (Get-Command uv -ErrorAction SilentlyContinue)) {
        Write-Host '執行 uv sync（安裝相依套件）'
        Push-Location $ProjectDir
        uv sync
        Pop-Location
    } else {
        Write-Host '[!] uv 尚未就緒或專案不存在，略過 uv sync'
    }
}

$pycharm = Get-ChildItem -Path @(
    "$env:ProgramFiles\JetBrains",
    "${env:ProgramFiles(x86)}\JetBrains",
    "$env:LOCALAPPDATA\Programs\JetBrains",
    "$env:LOCALAPPDATA\JetBrains\Toolbox\apps"
) -Recurse -Filter 'pycharm64.exe' -ErrorAction SilentlyContinue | Select-Object -First 1

if ($pycharm) {
    Start-Process -FilePath $pycharm.FullName -ArgumentList "`"$ProjectDir`""
    Write-Host "已用 PyCharm 開啟 $ProjectDir"
} else {
    Write-Host '[!] 找不到 PyCharm，請手動開啟並打開 D:\python-workspace（剛裝完可能需重登才在預期路徑）'
}
'@ | Set-Content -Path $userInit -Encoding UTF8

# ---------- Step 5：以使用者權限執行初始化 ----------
Write-Step '以使用者權限執行 clone / uv sync / 開 PyCharm'
Invoke-AsInteractiveUser -File $userInit
Write-Ok '使用者權限初始化結束'

Write-Host "`n全部步驟結束。" -ForegroundColor Green

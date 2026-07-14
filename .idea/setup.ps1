#Requires -Version 5.1
<#
  Hack the SDGs 2026
  Run as administrator:
  powershell -ExecutionPolicy Bypass -File .\setup.ps1

  ASCII only. PowerShell 5.1 mis-decodes UTF-8 files without a BOM, so any
  non-ASCII literal in this file would come out garbled on a student machine.
#>

$ErrorActionPreference = 'Continue'  # each step handles its own failure; never abort the whole run
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------- Config ----------
$TempDir    = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Hack-the-SDGs'
$ShareDir   = Join-Path $env:PUBLIC 'Hack-the-SDGs'  # cross-account: readable by the de-elevated user task
$SetupUrl   = 'https://raw.githubusercontent.com/Hack-the-SDGs/minethon/main/pc_setup/setup.ps1'
$RepoUrl    = 'https://github.com/Hack-the-SDGs/python-workspace'
$ProjectDir = 'D:\python-workspace'
$NotesUrl   = 'https://hackmd.io/@NTUST-CSIE-CAMP/book'
$VmwareUrl  = 'https://drive.smashit.tw/public.php/dav/files/HMiX8wsbcPpk2KR/?accept=zip'
$VmwareExe  = Join-Path $TempDir 'VMware-Workstation-Full-26H1-25388281.exe'
$HmclUrl    = 'https://github.com/Hack-the-SDGs/HMCL/releases/download/v3.14.5/HMCL-3.14.5.exe'
$HmclExe    = Join-Path $TempDir 'HMCL-3.14.5.exe'

# ponytail: the shortcut name is Chinese by request; build it from code points to keep this file ASCII. 0x5B78 0x54E1 0x624B 0x518A = "student handbook"
$ManualUrlFile = Join-Path $TempDir ((-join [char[]](0x5B78, 0x54E1, 0x624B, 0x518A)) + '.url')

# ---------- Helpers ----------
function Write-Step { param([string]$Msg) Write-Host "`n========== $Msg ==========" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "[OK] $Msg" -ForegroundColor Green }
function Write-Note { param([string]$Msg) Write-Host "[!]  $Msg" -ForegroundColor Yellow }

# Always write files without a BOM: Windows fails to parse .json files that have one
function Set-TextNoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# Reload PATH from the registry so git / uv installed by winget work in this same session
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path','Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = @($machine, $user) -join ';'
}

# ponytail: WebClient, not Invoke-WebRequest: PS 5.1 buffers the whole response in memory, which is miserable for a 280 MB installer.
# Download to a .part file first so an interrupted run does not leave a truncated exe that looks complete next time.
function Get-File {
    param([string]$Url, [string]$Path)
    $name = Split-Path $Path -Leaf
    if (Test-Path $Path) { Write-Ok "$name already downloaded, skipping"; return $true }

    Write-Step "Downloading $name"
    $part = "$Path.part"
    try {
        (New-Object Net.WebClient).DownloadFile($Url, $part)
        Move-Item -Path $part -Destination $Path -Force
        Write-Ok $Path
        return $true
    } catch {
        Remove-Item $part -Force -ErrorAction SilentlyContinue
        Write-Note "Failed to download ${name}: $($_.Exception.Message)"
        return $false
    }
}

function Install-WithWinget {
    param([string]$Id)
    # Already installed -> skip quietly (winget list -e returns 0 on a hit), so re-runs do not reinstall
    winget list -e --id $Id --accept-source-agreements *> $null
    if ($LASTEXITCODE -eq 0) { Write-Ok "$Id already installed, skipping"; return }

    Write-Step "Installing $Id"
    winget install -e --id $Id --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -eq 0) { Write-Ok "$Id installed" }
    else { Write-Note "$Id winget exit code $LASTEXITCODE (usually a user cancel, safe to ignore)" }
}

# Run a .ps1 as the currently logged-in desktop user, even when this script is elevated.
# Why: uv sync must create .venv and the uv cache under that user's account, otherwise PyCharm
# cannot see the environment. Same for the .minecraft profile, which lives in the user's APPDATA.
function Invoke-AsInteractiveUser {
    param([Parameter(Mandatory)][string]$File)
    $user = (Get-CimInstance Win32_ComputerSystem).UserName  # current interactive desktop user
    if (-not $user) { Write-Note 'No interactive user found, running with the current privileges instead'; & $File; return }

    $log  = Join-Path $ShareDir 'user-init.log'
    $task = 'HackSDGs-UserInit'
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"& '$File' *> '$log'`""
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $task

    # ponytail: naive poll until it finishes; uv sync takes far longer than 2s so this is fine. 10 min ceiling in case it hangs
    Start-Sleep -Seconds 2
    $waited = 0
    while ((Get-ScheduledTask -TaskName $task).State -eq 'Running' -and $waited -lt 600) {
        Start-Sleep -Seconds 3; $waited += 3
    }
    Unregister-ScheduledTask -TaskName $task -Confirm:$false
    if (Test-Path $log) { Get-Content $log | Write-Host }
}

# ---------- Preflight ----------
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Note 'winget not found. Install "App Installer" from the Microsoft Store first, then re-run this script.'
    return
}

# ---------- Step 0: working directory ----------
Write-Step "Creating working directory: $TempDir"
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
Write-Ok $TempDir

# ---------- Step 1: machine init script (interactive, asks for a password) ----------
Write-Step 'Running machine init script setup.ps1'
$setupLocal = Join-Path $TempDir 'setup.ps1'
try {
    Invoke-WebRequest -Uri $SetupUrl -OutFile $setupLocal -UseBasicParsing
    Unblock-File $setupLocal
    Write-Note 'Entering the init script now'
    & $setupLocal
    Write-Ok 'Init script finished'
} catch {
    Write-Note "Init script download or run failed: $($_.Exception.Message)"
}

# ---------- Step 2: install software (default install locations) ----------
Install-WithWinget 'Mojang.MinecraftLauncher'
Install-WithWinget 'JetBrains.PyCharm.Community'
Install-WithWinget 'Git.Git'
Install-WithWinget 'OpenJS.NodeJS.LTS'
Install-WithWinget 'astral-sh.uv'

# ---------- Step 3: refresh PATH for this session ----------
Write-Step 'Reloading the PATH environment variable'
Update-SessionPath
Write-Ok 'PATH updated (git / uv should now be callable)'

# ---------- Step 4: downloads and the handbook shortcut ----------
$hasVmware = Get-File -Url $VmwareUrl -Path $VmwareExe
Get-File -Url $HmclUrl -Path $HmclExe | Out-Null

Write-Step 'Creating the student handbook shortcut'
Set-TextNoBom -Path $ManualUrlFile -Content "[InternetShortcut]`r`nURL=$NotesUrl`r`n"
Write-Ok $ManualUrlFile

# ---------- Step 5: user-privilege init script ----------
# Notes, clone, .minecraft profile, uv sync and PyCharm all run as the desktop user,
# so that .venv and %APPDATA%\.minecraft are not created under the administrator account.
Write-Step 'Preparing the user-privilege init script'
New-Item -ItemType Directory -Path $ShareDir -Force | Out-Null
$userInit = Join-Path $ShareDir 'user-init.ps1'
# ponytail: single-quoted here-string (no interpolation); the few settings it needs are re-declared in the header above it
$userInitContent = @"
`$ProjectDir = '$ProjectDir'
`$RepoUrl    = '$RepoUrl'
`$NotesUrl   = '$NotesUrl'
"@ + @'

Write-Host 'Opening the HackMD course notes'
Start-Process $NotesUrl

if (-not (Test-Path 'D:\')) {
    Write-Host '[!] D:\ drive not found, skipping clone / uv sync'
} elseif (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host '[!] git is not ready yet (PowerShell may need a restart), skipping clone'
} else {
    if (Test-Path (Join-Path $ProjectDir '.git')) {
        Write-Host "$ProjectDir already exists, running git pull instead"
        git -C $ProjectDir pull
    } elseif (Test-Path $ProjectDir) {
        Write-Host "[!] $ProjectDir exists but is not a git repository, skipping clone"
    } else {
        git clone $RepoUrl $ProjectDir
    }

    if ((Test-Path $ProjectDir) -and (Get-Command uv -ErrorAction SilentlyContinue)) {
        Write-Host 'Running uv sync (installing dependencies)'
        Push-Location $ProjectDir
        uv sync
        Pop-Location
    } else {
        Write-Host '[!] uv is not ready or the project is missing, skipping uv sync'
    }
}

# Minecraft profile (mods / shaderpacks / servers.dat / options.txt) ships inside the repo
$mcSource = Join-Path $ProjectDir '.idea\minecraft'
$mcTarget = Join-Path $env:APPDATA '.minecraft'
if (Test-Path $mcSource) {
    New-Item -ItemType Directory -Path $mcTarget -Force | Out-Null
    Copy-Item -Path (Join-Path $mcSource '*') -Destination $mcTarget -Recurse -Force
    Write-Host "Copied the Minecraft profile to $mcTarget"
} else {
    Write-Host "[!] $mcSource not found, skipping the Minecraft profile"
}

$pycharm = Get-ChildItem -Path @(
    "$env:ProgramFiles\JetBrains",
    "${env:ProgramFiles(x86)}\JetBrains",
    "$env:LOCALAPPDATA\Programs\JetBrains",
    "$env:LOCALAPPDATA\JetBrains\Toolbox\apps"
) -Recurse -Filter 'pycharm64.exe' -ErrorAction SilentlyContinue | Select-Object -First 1

if ($pycharm) {
    Start-Process -FilePath $pycharm.FullName -ArgumentList "`"$ProjectDir`""
    Write-Host "Opened $ProjectDir in PyCharm"
} else {
    Write-Host '[!] PyCharm not found, please open D:\python-workspace manually (a fresh install may need a re-login before it lands on the expected path)'
}
'@
Set-TextNoBom -Path $userInit -Content $userInitContent

# ---------- Step 6: run the init script as the desktop user ----------
Write-Step 'Running clone / uv sync / Minecraft profile / PyCharm as the desktop user'
Invoke-AsInteractiveUser -File $userInit
Write-Ok 'User-privilege init finished'

# ---------- Step 7: VMware Workstation installer (elevated, blocking GUI, so it goes last) ----------
if ($hasVmware) {
    Write-Step 'Launching the VMware Workstation installer as administrator'
    Write-Note 'Complete the installer wizard; this script waits until it exits.'
    try {
        Start-Process -FilePath $VmwareExe -Verb RunAs -Wait
        Write-Ok 'VMware Workstation installer finished'
    } catch {
        Write-Note "Failed to launch the VMware installer: $($_.Exception.Message)"
    }
} else {
    Write-Note "VMware installer missing, run it manually from $TempDir"
}

Write-Host "`nAll steps complete." -ForegroundColor Green

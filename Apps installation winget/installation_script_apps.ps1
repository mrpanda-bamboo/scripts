# ============================================================
#  Windows App Installer - Interactive winget bulk installer
#  Navigate: Up/Down   Toggle: Space   Next Section: Enter
# ============================================================

# ---------- Require Administrator privileges ----------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    Write-Host ""
    Write-Host "  This script requires Administrator privileges." -ForegroundColor Yellow
    Write-Host "  Requesting elevation..." -ForegroundColor Yellow
    Write-Host ""

    try {
        $scriptPath = $MyInvocation.MyCommand.Path
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        exit
    }
    catch {
        Write-Host "  ERROR: Failed to obtain Administrator privileges." -ForegroundColor Red
        Write-Host "  Please right-click the script and select 'Run as Administrator'." -ForegroundColor Red
        Write-Host ""
        Pause
        exit 1
    }
}

# ---------- App catalogue (grouped by category) ----------
$categories = [ordered]@{
    "Browsers and Security"        = @(
        "Brave.Brave",
        "TorProject.TorBrowser",
        "insecure.nmap",
        "WiresharkFoundation.Wireshark",
        "PortSwigger.BurpSuite.Community"
    )
    "Development Tools"            = @(
        "Microsoft.VisualStudioCode",
        "Docker.DockerDesktop",
        "Python.Python.3.0",
        "Git.Git",
        "Anthropic.ClaudeCode",
        "Google.Antigravity"
    )
    "Utilities"                    = @(
        "7zip.7zip",
        "Rufus.Rufus",
        "JAMSoftware.TreeSize.Free",
        "CharlesMilette.TranslucentTB",
        "FlipperDevicesInc.qFlipper"
    )
    "Networking and Admin"         = @(
        "PuTTY.PuTTY",
        "WinSCP.WinSCP",
        "Microsoft.Sysinternals.ProcessExplorer",
        "OpenVPNTechnologies.OpenVPN",
        "TeamViewer.TeamViewer",
        "Oracle.VirtualBox"
    )
    "Productivity"                 = @(
        "Notepad++.Notepad++",
        "Notion.Notion",
        "Obsidian.Obsidian",
        "Adobe.Acrobat.Reader.64-bit"
    )
    "Communication & Entertainment"                = @(
        "Discord.Discord",
        "Spotify.Spotify"
    )
    "Gaming"                       = @(
        "Valve.Steam",
        "EpicGames.EpicGamesLauncher",
        "Ubisoft.Connect",
        "ElectronicArts.EADesktop"
    )
}

# ---------- Collect selections across all categories ----------
$selectedApps = New-Object System.Collections.ArrayList

$catKeys = @($categories.Keys)
$totalSections = $catKeys.Count

for ($s = 0; $s -lt $totalSections; $s++) {
    $catName = $catKeys[$s]
    $apps = @($categories[$catName])
    $appCount = $apps.Count

    # Track selection state for this category
    $checked = New-Object bool[] $appCount
    $cursor = 0

    $sectionDone = $false
    while ($sectionDone -eq $false) {
        # --- Redraw ---
        Clear-Host
        [Console]::CursorVisible = $false

        $sectionNum = $s + 1
        Write-Host ""
        Write-Host "  =====================================================" -ForegroundColor DarkCyan
        Write-Host "   Windows App Installer    Section $sectionNum / $totalSections" -ForegroundColor DarkCyan
        Write-Host "   Up/Down = Navigate  |  Space = Toggle  |  Enter = Next" -ForegroundColor DarkCyan
        Write-Host "  =====================================================" -ForegroundColor DarkCyan
        Write-Host ""
        Write-Host "  --- $catName ---" -ForegroundColor Magenta
        Write-Host ""

        for ($i = 0; $i -lt $appCount; $i++) {
            if ($checked[$i]) {
                $box = "[X]"
            }
            else {
                $box = "[ ]"
            }

            if ($i -eq $cursor) {
                Write-Host "   > $box $($apps[$i])" -ForegroundColor Cyan
            }
            else {
                Write-Host "     $box $($apps[$i])"
            }
        }

        Write-Host ""
        Write-Host "  Press ENTER to continue to the next section." -ForegroundColor DarkGray

        # --- Input ---
        $keyInfo = [Console]::ReadKey($true)
        $keyName = $keyInfo.Key

        if ($keyName -eq "UpArrow") {
            if ($cursor -gt 0) {
                $cursor = $cursor - 1
            }
        }
        elseif ($keyName -eq "DownArrow") {
            if ($cursor -lt ($appCount - 1)) {
                $cursor = $cursor + 1
            }
        }
        elseif ($keyName -eq "Spacebar") {
            $checked[$cursor] = -not $checked[$cursor]
        }
        elseif ($keyName -eq "Enter") {
            # Save selected apps from this category
            for ($i = 0; $i -lt $appCount; $i++) {
                if ($checked[$i]) {
                    [void]$selectedApps.Add($apps[$i])
                }
            }
            $sectionDone = $true
        }
    }
}

[Console]::CursorVisible = $true
Clear-Host

# ---------- Summary ----------
if ($selectedApps.Count -eq 0) {
    Write-Host ""
    Write-Host "  No apps selected. Exiting." -ForegroundColor Yellow
    Pause
    exit
}

Write-Host ""
Write-Host "  =====================================================" -ForegroundColor Green
Write-Host "   $($selectedApps.Count) app(s) selected for installation:" -ForegroundColor Green
Write-Host "  =====================================================" -ForegroundColor Green
Write-Host ""
foreach ($app in $selectedApps) {
    Write-Host "    - $app" -ForegroundColor Gray
}
Write-Host ""
Write-Host "  Starting installations..." -ForegroundColor Cyan
Write-Host ""

# ---------- Install ----------
$success = 0
$failed = 0

foreach ($app in $selectedApps) {
    Write-Host "  Installing $app ..." -ForegroundColor Cyan
    winget install --id $app -e --silent --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  OK   - $app" -ForegroundColor Green
        $success = $success + 1
    }
    else {
        Write-Host "  FAIL - $app (exit code $LASTEXITCODE)" -ForegroundColor Red
        $failed = $failed + 1
    }
    Write-Host ""
}

Write-Host "  =====================================================" -ForegroundColor Green
Write-Host "   Done!  $success succeeded, $failed failed." -ForegroundColor Green
Write-Host "  =====================================================" -ForegroundColor Green
Pause
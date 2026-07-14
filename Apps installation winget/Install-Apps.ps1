# ============================================================================
#  Windows App Installer v2  -  winget installation wizard (WPF GUI)
#
#  * App catalog lives in apps.json next to this script (edit that file to
#    add/remove apps - you never need to touch this script).
#  * Detects already-installed apps / available updates / conflicting
#    variants (e.g. TeamViewer Host vs Full Client) and lets you decide
#    per app: Skip / Update / Reinstall / Replace variant.
#  * Handles winget quirks: MSI "another install in progress" (1618) with
#    wait+retry, "already up to date" counted as success, installers that
#    refuse to run elevated (noAdmin flag -> de-elevated install).
#
#  Usage:   powershell.exe -ExecutionPolicy Bypass -File Install-Apps.ps1
#  Test:    powershell.exe -ExecutionPolicy Bypass -File Install-Apps.ps1 -ValidateOnly
# ============================================================================

[CmdletBinding()]
param(
    # Loads the catalog, scans installed apps and validates the GUI without
    # showing the window or installing anything. For testing changes.
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
#  Elevation + STA (WPF needs an STA thread; installs need admin)
# ---------------------------------------------------------------------------
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $ValidateOnly) {
    $scriptPath = $PSCommandPath
    # NOTE: pass the arguments as ONE pre-quoted string. With an array,
    # Windows PowerShell 5.1 joins the elements WITHOUT quoting, so a script
    # path containing spaces breaks the relaunched process (-File gets only
    # the first path segment and the window closes immediately).
    $relaunchArgs = '-NoProfile -ExecutionPolicy Bypass -STA -File "' + $scriptPath + '"'
    if (-not $script:IsAdmin) {
        Write-Host ""
        Write-Host "  This installer needs Administrator privileges - requesting elevation..." -ForegroundColor Yellow
        try {
            Start-Process powershell.exe -Verb RunAs -ArgumentList $relaunchArgs
            exit
        }
        catch {
            Write-Host "  ERROR: Elevation was declined. Right-click the script and 'Run as Administrator'." -ForegroundColor Red
            Pause
            exit 1
        }
    }
    if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne "STA") {
        # already admin, but wrong apartment for WPF -> relaunch with -STA
        Start-Process powershell.exe -ArgumentList $relaunchArgs
        exit
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ---------------------------------------------------------------------------
#  Small helpers
# ---------------------------------------------------------------------------

# Icons built from char codes so the .ps1 stays pure ASCII
$script:IconPending = [string][char]0x25CB   # circle
$script:IconRun     = [string][char]0x25B6   # play
$script:IconOk      = [string][char]0x2714   # check
$script:IconFail    = [string][char]0x2716   # cross
$script:IconSkip    = [string][char]0x2192   # arrow
$script:Ellipsis    = [string][char]0x2026   # winget truncation char

$script:LogFile   = $null
$script:Installing = $false
$script:ScanDone   = $false
$script:AllowClose = $false
$script:Page       = 0
$script:LastTail   = ""

function Write-Log {
    param([string]$Message)
    if (-not $script:LogFile) { return }
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    try { [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n") } catch { }
}

function Initialize-Log {
    if ($script:LogFile) { return }
    $script:LogFile = Join-Path $PSScriptRoot ("install-log_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt")
    Write-Log "Windows App Installer v2 - run started (user: $env:USERNAME, admin: $script:IsAdmin)"
}

# Processes pending WPF events so the window stays responsive while we wait
# for external processes on the UI thread (a "DoEvents" for WPF).
function Invoke-UiPump {
    if (-not $script:ui) { return }
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $null = [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [System.Windows.Threading.DispatcherOperationCallback] { param($f) $f.Continue = $false; return $null },
        $frame)
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

# Reads a file that may still be open for writing by another process.
function Get-FileText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    try {
        $fs = New-Object System.IO.FileStream($Path,
            [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            return $sr.ReadToEnd()
        }
        finally { $fs.Dispose() }
    }
    catch { return "" }
}

# True while the Windows Installer service is busy with an MSI install
# (the cause of the classic 1618 "another installation is in progress").
function Test-MsiBusy {
    $mutex = $null
    try {
        if ([System.Threading.Mutex]::TryOpenExisting("Global\_MSIExecute", [ref]$mutex)) {
            $mutex.Dispose()
            return $true
        }
        return $false
    }
    catch [System.UnauthorizedAccessException] { return $true }
    catch { return $false }
}

function Wait-MsiFree {
    param([int]$TimeoutSec = 300)
    $start = Get-Date
    while (Test-MsiBusy) {
        if (((Get-Date) - $start).TotalSeconds -gt $TimeoutSec) { return $false }
        Set-CurrentAction "Waiting for another Windows Installer process to finish..."
        Invoke-UiPump
        Start-Sleep -Milliseconds 1500
    }
    return $true
}

# Pulls PATH changes made by installers into this process (for verifyCommand).
function Update-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user    = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = ($machine + ";" + $user)
}

function Set-CurrentAction {
    param([string]$Text)
    if ($script:ui -and $script:ui.lblCurrent) {
        $script:ui.lblCurrent.Text = $Text
        Invoke-UiPump
    }
    elseif ($ValidateOnly) { Write-Host "  $Text" }
}

# Strips winget progress-bar noise and shows the tail in the output pane.
function Update-OutputPane {
    param([string]$Text)
    if (-not ($script:ui -and $script:ui.txtOutput)) { return }
    if ($Text -eq $script:LastTail) { return }
    $script:LastTail = $Text
    $junk = "^[\s\-\\\|/" + [char]0x2588 + [char]0x2592 + [char]0x2591 + "]*$"
    $lines = $Text -split "[\r\n]+" | Where-Object { $_ -notmatch $junk }
    if ($lines.Count -gt 40) { $lines = $lines[-40..-1] }
    $script:ui.txtOutput.Text = ($lines -join "`r`n")
    $script:ui.txtOutput.ScrollToEnd()
}

# Runs an external process, pumping the UI while waiting; returns exit code + output.
function Invoke-ExternalProcess {
    param(
        [string]$FilePath,
        [string]$Arguments,
        [int]$TimeoutSec = 3600,
        [switch]$StreamOutput
    )
    $stamp   = [guid]::NewGuid().ToString("N")
    $outFile = Join-Path $env:TEMP "appwiz_$stamp.out"
    $errFile = Join-Path $env:TEMP "appwiz_$stamp.err"
    try {
        $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    }
    catch {
        return [pscustomobject]@{ ExitCode = -1; Output = "Could not start ${FilePath}: $($_.Exception.Message)" }
    }
    # Cache the process handle immediately. Without this, Windows PowerShell
    # 5.1 usually returns $null for .ExitCode after the process has exited.
    $null = $p.Handle
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $timedOut = $false
    while (-not $p.HasExited) {
        if ((Get-Date) -gt $deadline) {
            $timedOut = $true
            try { $p.Kill() } catch { }
            break
        }
        Invoke-UiPump
        if ($StreamOutput) { Update-OutputPane (Get-FileText $outFile) }
        Start-Sleep -Milliseconds 150
    }
    try { $p.WaitForExit() } catch { }
    Start-Sleep -Milliseconds 100
    $out = Get-FileText $outFile
    $err = Get-FileText $errFile
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    if ($StreamOutput) { Update-OutputPane $out }
    $code = -1
    try { $code = $p.ExitCode } catch { }
    if ($timedOut) { $out += "`r`n[TIMEOUT] Process was terminated after $TimeoutSec seconds." }
    $combined = $out
    if ($err.Trim()) { $combined = $combined + "`r`n" + $err }
    return [pscustomobject]@{ ExitCode = $code; Output = $combined }
}

# Runs winget in a NON-elevated user context (for installers like Spotify
# that refuse to run as administrator). Uses a one-shot scheduled task with
# RunLevel "Limited", which runs with the user's standard (non-admin) token.
# ("runas /trustlevel:0x20000" is NOT reliable for this on Windows 11 -
# winget still detected an administrator context.)
function Invoke-UserContextWinget {
    param([string]$ArgumentLine)
    $work = Join-Path $env:PUBLIC "AppInstallerWizard"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $outFile  = Join-Path $work "user_out.txt"
    $exitFile = Join-Path $work "user_exit.txt"
    $batFile  = Join-Path $work "user_install.cmd"
    Remove-Item $outFile, $exitFile, $batFile -Force -ErrorAction SilentlyContinue

    $bat = @(
        "@echo off",
        "winget $ArgumentLine > `"$outFile`" 2>&1",
        "echo %ERRORLEVEL%> `"$exitFile`""
    )
    Set-Content -Path $batFile -Value $bat -Encoding ASCII

    $taskName = "AppInstallerWizard_UserContext"
    try {
        $action    = New-ScheduledTaskAction -Execute "$env:windir\System32\cmd.exe" -Argument "/c `"$batFile`""
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
    }
    catch {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        return [pscustomobject]@{ ExitCode = -1; Output = "Could not start de-elevated task: $($_.Exception.Message)" }
    }

    $deadline = (Get-Date).AddMinutes(15)
    while (-not (Test-Path $exitFile) -and (Get-Date) -lt $deadline) {
        Invoke-UiPump
        Update-OutputPane (Get-FileText $outFile)
        Start-Sleep -Milliseconds 400
    }
    Start-Sleep -Milliseconds 300
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    $output = Get-FileText $outFile
    $code = $null
    if (Test-Path $exitFile) {
        $raw = (Get-FileText $exitFile).Trim()
        [int]$parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed)) { $code = $parsed }
    }
    else {
        $output += "`r`n[TIMEOUT] De-elevated install did not finish (or could not start)."
    }
    Remove-Item $outFile, $exitFile, $batFile -Force -ErrorAction SilentlyContinue
    Remove-Item $work -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ ExitCode = $code; Output = $output }
}

# ---------------------------------------------------------------------------
#  winget exit code translation
# ---------------------------------------------------------------------------
function Get-ExitInfo {
    param($Code, [string]$Output)

    # No exit code captured -> decide from the (possibly localized) output text
    if ($null -eq $Code -or "$Code" -eq "") {
        if ($Output -match "Successfully installed|Erfolgreich installiert|Successfully uninstalled|Erfolgreich deinstalliert") {
            return @{ Kind = "OK"; Text = "Installed successfully"; Retry = $false }
        }
        if ($Output -match "No available upgrade|No newer package|Kein verf|keine neueren") {
            return @{ Kind = "UPTODATE"; Text = "Already installed - no newer version available"; Retry = $false }
        }
        return @{ Kind = "FAIL"; Text = "No exit code captured and no success message in the winget output - see the log file"; Retry = $false }
    }
    $Code = [long]$Code

    # NOTE: 4294967295 instead of 0xFFFFFFFF - PowerShell 5.1 parses the hex
    # literal as Int32 -1, which makes the mask a no-op and crashes the
    # [uint32] conversion for negative winget exit codes.
    $hex = "0x{0:X8}" -f ($Code -band 4294967295)

    if ($Code -eq 0) {
        return @{ Kind = "OK"; Text = "Installed successfully"; Retry = $false }
    }
    elseif ($Code -eq -1978335189) {
        return @{ Kind = "UPTODATE"; Text = "Already installed - no newer version available"; Retry = $false }
    }
    elseif ($Code -eq -1978335212) {
        return @{ Kind = "FAIL"; Text = "No package found - check the winget ID in apps.json (IDs are case-sensitive)"; Retry = $false }
    }
    elseif ($Code -eq -1978334974 -or $Code -eq 1618) {
        return @{ Kind = "FAIL"; Text = "Another installation was already in progress (MSI error 1618)"; Retry = $true }
    }
    elseif ($Code -eq -1978335159 -or $Code -eq 1603) {
        return @{ Kind = "FAIL"; Text = "Installer failed (MSI error 1603). A different variant/edition already installed can block this - check its entry or uninstall it first"; Retry = $false }
    }
    elseif ($Code -eq -1978335146) {
        return @{ Kind = "FAIL"; Text = "This installer refuses to run as administrator. Set ""noAdmin"": true for this app in apps.json"; Retry = $false }
    }
    elseif ($Code -eq 3010 -or $Code -eq 1641) {
        return @{ Kind = "OK"; Text = "Installed - a restart is required to finish"; Retry = $false }
    }
    elseif ($Output -match "already in progress|andere Installation") {
        return @{ Kind = "FAIL"; Text = "Another installation was already in progress"; Retry = $true }
    }
    elseif ($Output -match "No available upgrade|No newer package|Kein verf|keine neueren") {
        return @{ Kind = "UPTODATE"; Text = "Already installed - no newer version available"; Retry = $false }
    }
    else {
        return @{ Kind = "FAIL"; Text = "Failed with exit code $Code ($hex) - see the log file / 'winget --logs'"; Retry = $false }
    }
}

# ---------------------------------------------------------------------------
#  Catalog (apps.json)
# ---------------------------------------------------------------------------
function Get-JsonProp {
    param($Object, [string]$Name, $Default)
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Import-Catalog {
    $path = Join-Path $PSScriptRoot "apps.json"
    if (-not (Test-Path $path)) {
        throw "apps.json not found next to the script ($path)."
    }
    $json = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $apps = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($cat in $json.categories) {
        foreach ($entry in $cat.apps) {
            $id = [string]$entry.id
            if (-not $id) { throw "apps.json: an app in category '$($cat.name)' has no ""id""." }
            if ($seen.ContainsKey($id.ToLower())) { throw "apps.json: duplicate app id '$id'." }
            $seen[$id.ToLower()] = $true
            $null = $apps.Add([pscustomobject]@{
                Name              = [string](Get-JsonProp $entry "name" $id)
                Id                = $id
                Category          = [string]$cat.name
                Source            = [string](Get-JsonProp $entry "source" "winget")
                NoAdmin           = [bool](Get-JsonProp $entry "noAdmin" $false)
                Conflicts         = @(Get-JsonProp $entry "conflicts" @())
                ExtraArgs         = [string](Get-JsonProp $entry "args" "")
                VerifyCommand     = [string](Get-JsonProp $entry "verifyCommand" "")
                # runtime state
                InstalledVersion  = $null
                UpdateAvailable   = $false
                ConflictInstalled = @()
                Status            = "NotInstalled"   # NotInstalled | Installed | UpdateAvailable | Conflict
                Decision          = "Install"        # Install | Update | Reinstall | Replace | Skip
                Result            = ""               # OK | UPTODATE | SKIP | FAIL
                ResultDetail      = ""
                # UI references
                CheckBox          = $null
                RowPanel          = $null
                StatusBlock       = $null
                CatUi             = $null
                ProgIcon          = $null
                ProgText          = $null
            })
        }
    }
    if ($apps.Count -eq 0) { throw "apps.json contains no apps." }
    return $apps
}

# ---------------------------------------------------------------------------
#  Installed-app scan (winget export + winget upgrade)
# ---------------------------------------------------------------------------
function Set-ScanStatus {
    param([string]$Text)
    if ($script:ui -and $script:ui.lblScan) {
        $script:ui.lblScan.Text = "Installed-app scan: $Text"
        Invoke-UiPump
    }
    if ($ValidateOnly) { Write-Host "  [scan] $Text" }
}

# Parses IDs out of a winget console table (locale-independent: uses the
# 'ID' / 'Version' header positions). Truncated IDs (ending in the ellipsis
# character) are collected as prefixes.
function Get-WingetTableIds {
    param([string]$Output)
    $exact    = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $prefixes = New-Object System.Collections.ArrayList
    $idCol = -1
    $verCol = -1
    foreach ($line in ($Output -split "[\r\n]+")) {
        if ($line -match "^\s*Name\s" -and $line -match "\bID\b" -and $line -match "\bVersion\b") {
            $idCol  = [regex]::Match($line, "\bID\b").Index
            $verCol = [regex]::Match($line, "\bVersion\b").Index
            continue
        }
        if ($idCol -lt 0) { continue }
        if ($line -match "^\s*-{4,}\s*$") { continue }
        if ($line.Length -le $idCol) { continue }
        if ($verCol -gt $idCol -and $line.Length -ge $verCol) {
            $id = $line.Substring($idCol, $verCol - $idCol).Trim()
        }
        else {
            $id = $line.Substring($idCol).Trim()
        }
        if (-not $id) { continue }
        if ($id -match "\s") { continue }
        $isStoreId = ($id -match "^[A-Z0-9]{10,14}$")
        if (-not ($id.Contains(".") -or $isStoreId)) { continue }
        if ($id.EndsWith($script:Ellipsis)) {
            $null = $prefixes.Add($id.TrimEnd([char]0x2026))
        }
        else {
            $null = $exact.Add($id)
        }
    }
    return @{ Exact = $exact; Prefixes = $prefixes }
}

function Invoke-InstalledScan {
    # --- 1) which catalog apps are installed (winget export -> clean JSON) ---
    Set-ScanStatus "reading installed packages (winget export)..."
    $exportFile = Join-Path $env:TEMP "appwiz_export.json"
    Remove-Item $exportFile -Force -ErrorAction SilentlyContinue
    $null = Invoke-ExternalProcess -FilePath $script:WingetPath `
        -Arguments "export -o `"$exportFile`" --include-versions --accept-source-agreements --disable-interactivity" `
        -TimeoutSec 300

    $installed = @{}
    if (Test-Path $exportFile) {
        try {
            $export = Get-Content -Path $exportFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($src in $export.Sources) {
                foreach ($pkg in $src.Packages) {
                    # winget writes "> 1.2.3" when the installed version is newer
                    # than anything in the source - strip that marker
                    $ver = ([string](Get-JsonProp $pkg "Version" "")) -replace "^\s*[<>]\s*", ""
                    $installed[([string]$pkg.PackageIdentifier).ToLower()] = $ver
                }
            }
        }
        catch { }
        Remove-Item $exportFile -Force -ErrorAction SilentlyContinue
    }

    # --- 2) which of them have updates available (winget upgrade) ---
    Set-ScanStatus "checking for available updates (winget upgrade)..."
    $upg = Invoke-ExternalProcess -FilePath $script:WingetPath `
        -Arguments "upgrade --accept-source-agreements --disable-interactivity" -TimeoutSec 300
    $upgIds = Get-WingetTableIds -Output $upg.Output

    # --- 3) apply to the catalog ---
    foreach ($app in $script:Apps) {
        $key = $app.Id.ToLower()
        if ($installed.ContainsKey($key)) {
            $app.InstalledVersion = $installed[$key]
            $hasUpdate = $upgIds.Exact.Contains($app.Id)
            if (-not $hasUpdate) {
                foreach ($pfx in $upgIds.Prefixes) {
                    if ($app.Id.StartsWith($pfx, [System.StringComparison]::OrdinalIgnoreCase)) { $hasUpdate = $true; break }
                }
            }
            if ($hasUpdate) { $app.Status = "UpdateAvailable"; $app.UpdateAvailable = $true }
            else            { $app.Status = "Installed" }
        }
        else {
            $found = @()
            foreach ($c in $app.Conflicts) {
                if ($installed.ContainsKey(([string]$c).ToLower())) { $found += [string]$c }
            }
            if ($found.Count -gt 0) {
                $app.Status = "Conflict"
                $app.ConflictInstalled = $found
            }
            else { $app.Status = "NotInstalled" }
        }
    }
    $script:ScanDone = $true
    $installedCount = @($script:Apps | Where-Object { $_.Status -ne "NotInstalled" }).Count
    Set-ScanStatus "done - $installedCount of $($script:Apps.Count) catalog apps are already on this PC."
}

function Get-StatusDisplay {
    param($App)
    if ($App.Status -eq "UpdateAvailable") {
        $v = $App.InstalledVersion; if (-not $v) { $v = "?" }
        return @{ Text = "installed v$v - update available"; Color = "#B54708" }
    }
    elseif ($App.Status -eq "Installed") {
        $v = $App.InstalledVersion; if (-not $v) { $v = "?" }
        return @{ Text = "installed v$v - up to date"; Color = "#067647" }
    }
    elseif ($App.Status -eq "Conflict") {
        return @{ Text = ("variant installed: " + ($App.ConflictInstalled -join ", ")); Color = "#B42318" }
    }
    else {
        return @{ Text = "not installed"; Color = "#98A2B3" }
    }
}

# ---------------------------------------------------------------------------
#  Install engine
# ---------------------------------------------------------------------------
function Get-WingetArgLine {
    param($App, [string]$Verb, [string]$Extra)
    $line = "$Verb --id `"$($App.Id)`" -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"
    if ($Extra) { $line += " $Extra" }
    if ($App.Source) { $line += " --source $($App.Source)" }
    if ($App.ExtraArgs) { $line += " " + $App.ExtraArgs }
    return $line
}

function Set-AppProgress {
    param($App, [string]$Text)
    if ($App.ProgText) {
        $App.ProgText.Text = $Text
        Invoke-UiPump
    }
}

function Install-OneApp {
    param($App)

    if ($App.Decision -eq "Skip") {
        $App.Result = "SKIP"
        $App.ResultDetail = "Skipped (your choice on the review page)"
        Write-Log "SKIP  $($App.Id)"
        return
    }

    Write-Log "----- $($App.Name) [$($App.Id)] action=$($App.Decision) noAdmin=$($App.NoAdmin) -----"

    # Replace variant: uninstall the conflicting package(s) first
    if ($App.Decision -eq "Replace" -and $App.ConflictInstalled.Count -gt 0) {
        foreach ($cid in @($App.ConflictInstalled)) {
            Set-AppProgress $App "removing variant $cid ..."
            Set-CurrentAction "Uninstalling conflicting variant $cid ..."
            $null = Wait-MsiFree
            $r = Invoke-ExternalProcess -FilePath $script:WingetPath `
                -Arguments "uninstall --id `"$cid`" -e --silent --accept-source-agreements --disable-interactivity" `
                -TimeoutSec 900 -StreamOutput
            Write-Log "uninstall $cid -> exit $($r.ExitCode)`r`n$($r.Output)"
            $uninstallInfo = Get-ExitInfo -Code $r.ExitCode -Output $r.Output
            if ($uninstallInfo.Kind -eq "FAIL") {
                $App.Result = "FAIL"
                $App.ResultDetail = "Could not uninstall variant $cid (exit $($r.ExitCode)) - install aborted"
                return
            }
            $App.ConflictInstalled = @($App.ConflictInstalled | Where-Object { $_ -ne $cid })
        }
    }

    $verb = "install"
    $extra = ""
    if ($App.Decision -eq "Update")    { $verb = "upgrade" }
    if ($App.Decision -eq "Reinstall") { $extra = "--force" }
    $argLine = Get-WingetArgLine -App $App -Verb $verb -Extra $extra

    $attempt = 0
    $maxAttempts = 3
    $result = $null
    $info = $null
    while ($true) {
        $attempt++
        $null = Wait-MsiFree
        Set-CurrentAction "Installing $($App.Name) (attempt $attempt)..."
        Set-AppProgress $App "installing..."
        if ($App.NoAdmin) {
            Set-AppProgress $App "installing (user context - a console window may appear)..."
            $result = Invoke-UserContextWinget -ArgumentLine $argLine
        }
        else {
            $result = Invoke-ExternalProcess -FilePath $script:WingetPath -Arguments $argLine -StreamOutput
        }
        Write-Log "winget $argLine`r`nexit $($result.ExitCode)`r`n$($result.Output)"
        $info = Get-ExitInfo -Code $result.ExitCode -Output $result.Output
        if ($info.Retry -and $attempt -lt $maxAttempts) {
            Set-AppProgress $App "MSI busy - waiting, then retry $($attempt + 1)/$maxAttempts ..."
            Start-Sleep -Seconds 5
            continue
        }
        break
    }

    $App.Result = $info.Kind
    $App.ResultDetail = $info.Text

    # optional: verify a CLI command landed on PATH (e.g. 'claude')
    if (($App.Result -eq "OK" -or $App.Result -eq "UPTODATE") -and $App.VerifyCommand) {
        Update-ProcessPath
        $cmd = Get-Command $App.VerifyCommand -ErrorAction SilentlyContinue
        if ($cmd) {
            $App.ResultDetail += " | '$($App.VerifyCommand)' command is available"
        }
        else {
            $App.ResultDetail += " | '$($App.VerifyCommand)' not visible yet - open a NEW terminal after this wizard"
        }
    }
}

function Start-InstallRun {
    param([object[]]$RunList)

    $script:Installing = $true
    $script:ui.btnNext.IsEnabled = $false
    $script:ui.btnBack.IsEnabled = $false
    $script:ui.btnCancel.IsEnabled = $false
    Initialize-Log
    $script:ui.lblFooterInfo.Text = "Log: $script:LogFile"

    # build the per-app progress rows
    $script:ui.spProgress.Children.Clear()
    foreach ($app in $RunList) {
        $app.Result = ""
        $app.ResultDetail = ""
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = "0,3,0,3"
        $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = "26"
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = "*"
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = "Auto"
        $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)

        $icon = New-Object System.Windows.Controls.TextBlock
        $icon.Text = $script:IconPending
        $icon.Foreground = "#98A2B3"
        [System.Windows.Controls.Grid]::SetColumn($icon, 0)

        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = "$($app.Name)  ($($app.Id))"
        [System.Windows.Controls.Grid]::SetColumn($name, 1)

        $state = New-Object System.Windows.Controls.TextBlock
        $state.Text = "waiting"
        $state.Foreground = "#98A2B3"
        [System.Windows.Controls.Grid]::SetColumn($state, 2)

        $g.Children.Add($icon) | Out-Null
        $g.Children.Add($name) | Out-Null
        $g.Children.Add($state) | Out-Null
        $app.ProgIcon = $icon
        $app.ProgText = $state
        $script:ui.spProgress.Children.Add($g) | Out-Null
    }
    $script:ui.pbOverall.Value = 0
    $script:ui.pbOverall.Maximum = [Math]::Max(1, $RunList.Count)
    Invoke-UiPump

    $done = 0
    foreach ($app in $RunList) {
        $app.ProgIcon.Text = $script:IconRun
        $app.ProgIcon.Foreground = "#0F6CBD"
        Set-CurrentAction "Processing $($app.Name)..."
        Invoke-UiPump

        try {
            Install-OneApp -App $app
        }
        catch {
            # a single app must never take down the whole wizard
            $app.Result = "FAIL"
            $app.ResultDetail = "Unexpected error: $($_.Exception.Message)"
            Write-Log "ERROR during $($app.Id): $($_.Exception.Message)"
        }

        if ($app.Result -eq "OK") {
            $app.ProgIcon.Text = $script:IconOk;   $app.ProgIcon.Foreground = "#067647"
            $app.ProgText.Text = "OK";             $app.ProgText.Foreground = "#067647"
        }
        elseif ($app.Result -eq "UPTODATE") {
            $app.ProgIcon.Text = $script:IconOk;   $app.ProgIcon.Foreground = "#067647"
            $app.ProgText.Text = "up to date";     $app.ProgText.Foreground = "#067647"
        }
        elseif ($app.Result -eq "SKIP") {
            $app.ProgIcon.Text = $script:IconSkip; $app.ProgIcon.Foreground = "#98A2B3"
            $app.ProgText.Text = "skipped";        $app.ProgText.Foreground = "#98A2B3"
        }
        else {
            $app.ProgIcon.Text = $script:IconFail; $app.ProgIcon.Foreground = "#B42318"
            $app.ProgText.Text = "FAILED";         $app.ProgText.Foreground = "#B42318"
        }
        $done++
        $script:ui.pbOverall.Value = $done
        Invoke-UiPump
    }

    Set-CurrentAction "Finished. Click 'Continue' to see the summary."
    Write-Log "Run finished."
    $script:Installing = $false
    $script:ui.btnNext.IsEnabled = $true
    $script:ui.btnCancel.IsEnabled = $true
}

# ---------------------------------------------------------------------------
#  GUI - XAML
# ---------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows App Installer" Height="700" Width="1000" MinHeight="560" MinWidth="820"
        WindowStartupLocation="CenterScreen" Background="#F3F4F8"
        FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style x:Key="NavButton" TargetType="Button">
      <Setter Property="Padding" Value="20,7"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="MinWidth" Value="100"/>
    </Style>
    <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource NavButton}">
      <Setter Property="Background" Value="#0F6CBD"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="#0F6CBD"/>
    </Style>
  </Window.Resources>
  <DockPanel>
    <Border DockPanel.Dock="Left" Width="205" Background="#1B2A41">
      <StackPanel Margin="20,26,14,14">
        <TextBlock Text="App Installer" Foreground="White" FontSize="20" FontWeight="Bold"/>
        <TextBlock Text="winget wizard" Foreground="#8FA3BF" FontSize="12" Margin="0,2,0,30"/>
        <TextBlock x:Name="step0" Text="1   Welcome"     Foreground="White"   FontWeight="Bold" Margin="0,8"/>
        <TextBlock x:Name="step1" Text="2   Select apps" Foreground="#8FA3BF" Margin="0,8"/>
        <TextBlock x:Name="step2" Text="3   Review"      Foreground="#8FA3BF" Margin="0,8"/>
        <TextBlock x:Name="step3" Text="4   Install"     Foreground="#8FA3BF" Margin="0,8"/>
        <TextBlock x:Name="step4" Text="5   Finish"      Foreground="#8FA3BF" Margin="0,8"/>
      </StackPanel>
    </Border>
    <Border DockPanel.Dock="Bottom" Background="#FFFFFF" BorderBrush="#DDE1E8" BorderThickness="0,1,0,0">
      <DockPanel Margin="20,12,20,12">
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <Button x:Name="btnBack"   Content="&lt; Back" Style="{StaticResource NavButton}" IsEnabled="False"/>
          <Button x:Name="btnNext"   Content="Next &gt;" Style="{StaticResource AccentButton}" IsEnabled="False"/>
          <Button x:Name="btnCancel" Content="Cancel"    Style="{StaticResource NavButton}"/>
        </StackPanel>
        <TextBlock x:Name="lblFooterInfo" Text="" VerticalAlignment="Center" Foreground="#667085"/>
      </DockPanel>
    </Border>
    <Grid Margin="26,22,26,16">

      <StackPanel x:Name="pnlWelcome">
        <TextBlock Text="Welcome" FontSize="25" FontWeight="SemiBold"/>
        <TextBlock Margin="0,10,0,0" TextWrapping="Wrap" Foreground="#344054"
                   Text="This wizard installs your standard applications with winget. It first scans this PC so you can see per app whether it is already installed, has an update available, or a conflicting variant is present."/>
        <Border Background="White" BorderBrush="#DDE1E8" BorderThickness="1" CornerRadius="6" Padding="16" Margin="0,20,0,0">
          <StackPanel>
            <TextBlock x:Name="lblWinget"  Text="winget: checking..."/>
            <TextBlock x:Name="lblAdmin"   Text="Administrator: checking..." Margin="0,7,0,0"/>
            <TextBlock x:Name="lblCatalog" Text="Catalog: loading..."        Margin="0,7,0,0"/>
            <TextBlock x:Name="lblScan"    Text="Installed-app scan: starting..." Margin="0,7,0,0" Foreground="#B54708"/>
          </StackPanel>
        </Border>
        <TextBlock Margin="0,16,0,0" Foreground="#667085" TextWrapping="Wrap"
                   Text="Tip: to add or change apps, edit apps.json next to this script - one small entry per app, no code changes needed."/>
      </StackPanel>

      <DockPanel x:Name="pnlSelect" Visibility="Collapsed">
        <TextBlock DockPanel.Dock="Top" Text="Select apps" FontSize="25" FontWeight="SemiBold"/>
        <Grid DockPanel.Dock="Top" Margin="0,12,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Text="Filter:" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <TextBox x:Name="txtSearch" Grid.Column="1" Padding="6,4"/>
          <TextBlock x:Name="lblSelCount" Grid.Column="2" Text="0 selected" VerticalAlignment="Center" Margin="14,0,0,0" Foreground="#0F6CBD" FontWeight="SemiBold"/>
        </Grid>
        <ScrollViewer Margin="0,12,0,0" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="spCatalog"/>
        </ScrollViewer>
      </DockPanel>

      <DockPanel x:Name="pnlReview" Visibility="Collapsed">
        <TextBlock DockPanel.Dock="Top" Text="Review" FontSize="25" FontWeight="SemiBold"/>
        <TextBlock DockPanel.Dock="Top" x:Name="lblReviewHint" Margin="0,8,0,0" TextWrapping="Wrap" Foreground="#344054"/>
        <ScrollViewer Margin="0,14,0,0" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="spReview"/>
        </ScrollViewer>
      </DockPanel>

      <DockPanel x:Name="pnlProgress" Visibility="Collapsed">
        <TextBlock DockPanel.Dock="Top" Text="Installing" FontSize="25" FontWeight="SemiBold"/>
        <TextBlock DockPanel.Dock="Top" x:Name="lblCurrent" Margin="0,8,0,0" Foreground="#344054"/>
        <ProgressBar DockPanel.Dock="Top" x:Name="pbOverall" Height="10" Margin="0,10,0,0"/>
        <TextBox DockPanel.Dock="Bottom" x:Name="txtOutput" Height="150" IsReadOnly="True"
                 FontFamily="Consolas" FontSize="11" Background="#0D1117" Foreground="#7EE787"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                 TextWrapping="NoWrap" Margin="0,12,0,0" BorderBrush="#30363D"/>
        <ScrollViewer Margin="0,12,0,0" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="spProgress"/>
        </ScrollViewer>
      </DockPanel>

      <DockPanel x:Name="pnlSummary" Visibility="Collapsed">
        <TextBlock DockPanel.Dock="Top" Text="Finished" FontSize="25" FontWeight="SemiBold"/>
        <TextBlock DockPanel.Dock="Top" x:Name="lblSummaryCounts" Margin="0,8,0,0" FontWeight="SemiBold"/>
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,12,0,0">
          <Button x:Name="btnRetry" Content="Retry failed" Padding="16,6" Visibility="Collapsed"/>
          <Button x:Name="btnOpenLog" Content="Open log" Padding="16,6" Margin="10,0,0,0"/>
        </StackPanel>
        <ScrollViewer Margin="0,12,0,0" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="spSummary"/>
        </ScrollViewer>
      </DockPanel>

    </Grid>
  </DockPanel>
</Window>
'@

# ---------------------------------------------------------------------------
#  GUI - build pages
# ---------------------------------------------------------------------------
function Update-SelCount {
    $n = @($script:Apps | Where-Object { $_.CheckBox -and $_.CheckBox.IsChecked -eq $true }).Count
    $script:ui.lblSelCount.Text = "$n selected"
}

function Update-CategoryCheckState {
    param([string]$Category)
    $catUi = $script:CategoryUi[$Category]
    if (-not $catUi) { return }
    $apps = @($script:Apps | Where-Object { $_.Category -eq $Category })
    $checkedCount = @($apps | Where-Object { $_.CheckBox.IsChecked -eq $true }).Count
    if ($checkedCount -eq 0)            { $catUi.HeaderCheck.IsChecked = $false }
    elseif ($checkedCount -eq $apps.Count) { $catUi.HeaderCheck.IsChecked = $true }
    else                                { $catUi.HeaderCheck.IsChecked = $null }
}

function Build-SelectionPage {
    $script:ui.spCatalog.Children.Clear()
    $script:CategoryUi = @{}
    $categories = @($script:Apps | Select-Object -ExpandProperty Category -Unique)

    foreach ($catName in $categories) {
        $border = New-Object System.Windows.Controls.Border
        $border.Background = "White"
        $border.BorderBrush = "#DDE1E8"
        $border.BorderThickness = "1"
        $border.CornerRadius = "6"
        $border.Padding = "12,8,12,10"
        $border.Margin = "0,0,6,10"

        $stack = New-Object System.Windows.Controls.StackPanel

        $headerCb = New-Object System.Windows.Controls.CheckBox
        $headerCb.IsThreeState = $false
        $headerCb.FontWeight = "SemiBold"
        $headerCb.Foreground = "#7A2E8D"
        $headerCb.Content = $catName
        $headerCb.Margin = "0,0,0,6"
        $headerCb.Tag = $catName
        $headerCb.Add_Click({
            param($sender, $e)
            $cat = [string]$sender.Tag
            $val = ($sender.IsChecked -eq $true)
            foreach ($a in @($script:Apps | Where-Object { $_.Category -eq $cat })) {
                if ($a.RowPanel.Visibility -eq [System.Windows.Visibility]::Visible) {
                    $a.CheckBox.IsChecked = $val
                }
            }
            Update-SelCount
        })
        $stack.Children.Add($headerCb) | Out-Null

        foreach ($app in @($script:Apps | Where-Object { $_.Category -eq $catName })) {
            $g = New-Object System.Windows.Controls.Grid
            $g.Margin = "16,2,0,2"
            $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = "*"
            $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = "Auto"
            $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1)

            $left = New-Object System.Windows.Controls.StackPanel
            $left.Orientation = "Horizontal"

            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $app.Name
            $cb.VerticalAlignment = "Center"
            $cb.Tag = $app
            $cb.Add_Click({
                param($sender, $e)
                Update-SelCount
                Update-CategoryCheckState -Category $sender.Tag.Category
            })
            $left.Children.Add($cb) | Out-Null

            $idBlock = New-Object System.Windows.Controls.TextBlock
            $idBlock.Text = "   $($app.Id)"
            $idBlock.Foreground = "#98A2B3"
            $idBlock.FontSize = 11
            $idBlock.VerticalAlignment = "Center"
            $left.Children.Add($idBlock) | Out-Null
            [System.Windows.Controls.Grid]::SetColumn($left, 0)

            $disp = Get-StatusDisplay -App $app
            $status = New-Object System.Windows.Controls.TextBlock
            $status.Text = $disp.Text
            $status.Foreground = $disp.Color
            $status.VerticalAlignment = "Center"
            [System.Windows.Controls.Grid]::SetColumn($status, 1)

            $g.Children.Add($left) | Out-Null
            $g.Children.Add($status) | Out-Null

            $app.CheckBox = $cb
            $app.RowPanel = $g
            $app.StatusBlock = $status
            $app.CatUi = $border
            $stack.Children.Add($g) | Out-Null
        }

        $border.Child = $stack
        $script:ui.spCatalog.Children.Add($border) | Out-Null
        $script:CategoryUi[$catName] = @{ Border = $border; HeaderCheck = $headerCb }
    }
    Update-SelCount
}

function Update-SearchFilter {
    $term = $script:ui.txtSearch.Text.Trim()
    foreach ($app in $script:Apps) {
        if (-not $app.RowPanel) { continue }
        $match = $true
        if ($term) {
            $match = ($app.Name -like "*$term*") -or ($app.Id -like "*$term*")
        }
        if ($match) { $app.RowPanel.Visibility = [System.Windows.Visibility]::Visible }
        else        { $app.RowPanel.Visibility = [System.Windows.Visibility]::Collapsed }
    }
    foreach ($catName in $script:CategoryUi.Keys) {
        $any = @($script:Apps | Where-Object {
            $_.Category -eq $catName -and $_.RowPanel.Visibility -eq [System.Windows.Visibility]::Visible }).Count
        if ($any -gt 0) { $script:CategoryUi[$catName].Border.Visibility = [System.Windows.Visibility]::Visible }
        else            { $script:CategoryUi[$catName].Border.Visibility = [System.Windows.Visibility]::Collapsed }
    }
}

function Get-SelectedApps {
    return @($script:Apps | Where-Object { $_.CheckBox -and $_.CheckBox.IsChecked -eq $true })
}

function Add-ComboOption {
    param($Combo, [string]$Label, [string]$Action, [bool]$Selected)
    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = $Label
    $item.Tag = $Action
    $null = $Combo.Items.Add($item)
    if ($Selected) { $Combo.SelectedItem = $item }
}

function Build-ReviewPage {
    $script:ui.spReview.Children.Clear()
    $sel = Get-SelectedApps
    $needDecision = @($sel | Where-Object { $_.Status -ne "NotInstalled" }).Count
    $script:ui.lblReviewHint.Text = "$($sel.Count) app(s) will be processed. " +
        "$needDecision of them already exist on this PC in some form - choose per app what to do, then click Install."

    foreach ($app in $sel) {
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = "0,4,6,4"
        $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = "*"
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = "Auto"
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = "250"
        $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)

        $left = New-Object System.Windows.Controls.StackPanel
        $left.Orientation = "Horizontal"
        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = $app.Name
        $name.FontWeight = "SemiBold"
        $name.VerticalAlignment = "Center"
        $left.Children.Add($name) | Out-Null
        $idb = New-Object System.Windows.Controls.TextBlock
        $idb.Text = "   $($app.Id)"
        $idb.Foreground = "#98A2B3"
        $idb.FontSize = 11
        $idb.VerticalAlignment = "Center"
        $left.Children.Add($idb) | Out-Null
        [System.Windows.Controls.Grid]::SetColumn($left, 0)

        $disp = Get-StatusDisplay -App $app
        $status = New-Object System.Windows.Controls.TextBlock
        $status.Text = $disp.Text
        $status.Foreground = $disp.Color
        $status.VerticalAlignment = "Center"
        $status.Margin = "0,0,14,0"
        [System.Windows.Controls.Grid]::SetColumn($status, 1)

        $g.Children.Add($left) | Out-Null
        $g.Children.Add($status) | Out-Null

        if ($app.Status -eq "NotInstalled") {
            $app.Decision = "Install"
            $action = New-Object System.Windows.Controls.TextBlock
            $action.Text = "Install (new)"
            $action.Foreground = "#0F6CBD"
            $action.VerticalAlignment = "Center"
            [System.Windows.Controls.Grid]::SetColumn($action, 2)
            $g.Children.Add($action) | Out-Null
        }
        else {
            $combo = New-Object System.Windows.Controls.ComboBox
            $combo.Tag = $app
            if ($app.Status -eq "Installed") {
                $app.Decision = "Skip"
                Add-ComboOption $combo "Skip (already installed)" "Skip" $true
                Add-ComboOption $combo "Reinstall (force)" "Reinstall" $false
            }
            elseif ($app.Status -eq "UpdateAvailable") {
                $app.Decision = "Update"
                Add-ComboOption $combo "Update to latest version" "Update" $true
                Add-ComboOption $combo "Reinstall (force)" "Reinstall" $false
                Add-ComboOption $combo "Skip" "Skip" $false
            }
            else {
                # Conflict - a different variant of this app is installed
                $app.Decision = "Replace"
                Add-ComboOption $combo ("Replace " + ($app.ConflictInstalled -join ", ")) "Replace" $true
                Add-ComboOption $combo "Install anyway (may fail)" "Install" $false
                Add-ComboOption $combo "Skip" "Skip" $false
            }
            $combo.Add_SelectionChanged({
                param($sender, $e)
                $a = $sender.Tag
                if ($sender.SelectedItem) { $a.Decision = [string]$sender.SelectedItem.Tag }
            })
            [System.Windows.Controls.Grid]::SetColumn($combo, 2)
            $g.Children.Add($combo) | Out-Null
        }
        $script:ui.spReview.Children.Add($g) | Out-Null
    }
}

function Build-SummaryPage {
    $script:ui.spSummary.Children.Clear()
    $ran = @($script:Apps | Where-Object { $_.Result })
    $ok       = @($ran | Where-Object { $_.Result -eq "OK" }).Count
    $upToDate = @($ran | Where-Object { $_.Result -eq "UPTODATE" }).Count
    $skipped  = @($ran | Where-Object { $_.Result -eq "SKIP" }).Count
    $failed   = @($ran | Where-Object { $_.Result -eq "FAIL" })

    $script:ui.lblSummaryCounts.Text =
        "$ok installed  |  $upToDate already up to date  |  $skipped skipped  |  $($failed.Count) failed"

    foreach ($app in $ran) {
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = "0,4,6,4"
        $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = "26"
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = "230"
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = "*"
        $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)

        $icon = New-Object System.Windows.Controls.TextBlock
        if ($app.Result -eq "FAIL") { $icon.Text = $script:IconFail; $icon.Foreground = "#B42318" }
        elseif ($app.Result -eq "SKIP") { $icon.Text = $script:IconSkip; $icon.Foreground = "#98A2B3" }
        else { $icon.Text = $script:IconOk; $icon.Foreground = "#067647" }
        [System.Windows.Controls.Grid]::SetColumn($icon, 0)

        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = $app.Name
        $name.FontWeight = "SemiBold"
        [System.Windows.Controls.Grid]::SetColumn($name, 1)

        $detail = New-Object System.Windows.Controls.TextBlock
        $detail.Text = $app.ResultDetail
        $detail.TextWrapping = "Wrap"
        $detail.Foreground = "#344054"
        [System.Windows.Controls.Grid]::SetColumn($detail, 2)

        $g.Children.Add($icon) | Out-Null
        $g.Children.Add($name) | Out-Null
        $g.Children.Add($detail) | Out-Null
        $script:ui.spSummary.Children.Add($g) | Out-Null
    }

    if ($failed.Count -gt 0) { $script:ui.btnRetry.Visibility = [System.Windows.Visibility]::Visible }
    else                     { $script:ui.btnRetry.Visibility = [System.Windows.Visibility]::Collapsed }
    if ($script:LogFile) { $script:ui.lblFooterInfo.Text = "Log: $script:LogFile" }
}

# ---------------------------------------------------------------------------
#  GUI - wizard navigation
# ---------------------------------------------------------------------------
function Show-Page {
    param([int]$N)
    $script:Page = $N
    $panels = @($script:ui.pnlWelcome, $script:ui.pnlSelect, $script:ui.pnlReview, $script:ui.pnlProgress, $script:ui.pnlSummary)
    for ($i = 0; $i -lt $panels.Count; $i++) {
        if ($i -eq $N) { $panels[$i].Visibility = [System.Windows.Visibility]::Visible }
        else           { $panels[$i].Visibility = [System.Windows.Visibility]::Collapsed }
    }
    $steps = @($script:ui.step0, $script:ui.step1, $script:ui.step2, $script:ui.step3, $script:ui.step4)
    for ($i = 0; $i -lt $steps.Count; $i++) {
        if ($i -eq $N) { $steps[$i].Foreground = "White";   $steps[$i].FontWeight = "Bold" }
        else           { $steps[$i].Foreground = "#8FA3BF"; $steps[$i].FontWeight = "Normal" }
    }
    $script:ui.btnBack.IsEnabled = ($N -eq 1 -or $N -eq 2)
    if ($N -eq 0)     { $script:ui.btnNext.Content = "Next >";     $script:ui.btnNext.IsEnabled = ($script:ScanDone -and $null -ne $script:WingetPath) }
    elseif ($N -eq 1) { $script:ui.btnNext.Content = "Next >";     $script:ui.btnNext.IsEnabled = $true }
    elseif ($N -eq 2) { $script:ui.btnNext.Content = "Install";    $script:ui.btnNext.IsEnabled = $true }
    elseif ($N -eq 3) { $script:ui.btnNext.Content = "Continue >"; $script:ui.btnNext.IsEnabled = (-not $script:Installing) }
    else              { $script:ui.btnNext.Content = "Finish";     $script:ui.btnNext.IsEnabled = $true }
}

# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------
try {
    $script:Apps = Import-Catalog

    $wingetCmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $wingetCmd) { $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue }
    if ($wingetCmd) { $script:WingetPath = $wingetCmd.Source } else { $script:WingetPath = $null }

    # --- build window ---
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $script:ui = @{ win = $window }
    $names = @(
        "step0","step1","step2","step3","step4",
        "btnBack","btnNext","btnCancel","lblFooterInfo",
        "pnlWelcome","pnlSelect","pnlReview","pnlProgress","pnlSummary",
        "lblWinget","lblAdmin","lblCatalog","lblScan",
        "txtSearch","lblSelCount","spCatalog",
        "lblReviewHint","spReview",
        "lblCurrent","pbOverall","spProgress","txtOutput",
        "lblSummaryCounts","spSummary","btnRetry","btnOpenLog"
    )
    foreach ($n in $names) { $script:ui[$n] = $window.FindName($n) }

    # --- welcome page infos ---
    $catCount = @($script:Apps | Select-Object -ExpandProperty Category -Unique).Count
    $script:ui.lblCatalog.Text = "Catalog: $($script:Apps.Count) apps in $catCount categories (apps.json)"
    if ($script:IsAdmin) {
        $script:ui.lblAdmin.Text = "Administrator: yes"
        $script:ui.lblAdmin.Foreground = "#067647"
    }
    else {
        $script:ui.lblAdmin.Text = "Administrator: NO (validate mode)"
        $script:ui.lblAdmin.Foreground = "#B54708"
    }
    if ($script:WingetPath) {
        $wingetVersion = ""
        try { $wingetVersion = (& $script:WingetPath --version) 2>$null } catch { }
        $script:ui.lblWinget.Text = "winget: found ($wingetVersion)"
        $script:ui.lblWinget.Foreground = "#067647"
    }
    else {
        $script:ui.lblWinget.Text = "winget: NOT FOUND - install 'App Installer' from the Microsoft Store first"
        $script:ui.lblWinget.Foreground = "#B42318"
        $script:ui.lblScan.Text = "Installed-app scan: skipped (winget missing)"
    }

    # --- events ---
    $script:ui.txtSearch.Add_TextChanged({ Update-SearchFilter })

    $script:ui.btnNext.Add_Click({
        if ($script:Page -eq 0) { Show-Page 1 }
        elseif ($script:Page -eq 1) {
            $sel = Get-SelectedApps
            if ($sel.Count -eq 0) {
                [System.Windows.MessageBox]::Show("Please select at least one app.", "App Installer",
                    [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
                return
            }
            Build-ReviewPage
            Show-Page 2
        }
        elseif ($script:Page -eq 2) {
            Show-Page 3
            Start-InstallRun -RunList (Get-SelectedApps)
        }
        elseif ($script:Page -eq 3) {
            Build-SummaryPage
            Show-Page 4
        }
        else {
            $script:AllowClose = $true
            $script:ui.win.Close()
        }
    })

    $script:ui.btnBack.Add_Click({
        if ($script:Page -eq 1) { Show-Page 0 }
        elseif ($script:Page -eq 2) { Show-Page 1 }
    })

    $script:ui.btnCancel.Add_Click({ $script:ui.win.Close() })

    $script:ui.btnRetry.Add_Click({
        $failed = @($script:Apps | Where-Object { $_.Result -eq "FAIL" })
        if ($failed.Count -eq 0) { return }
        Show-Page 3
        Start-InstallRun -RunList $failed
    })

    $script:ui.btnOpenLog.Add_Click({
        if ($script:LogFile -and (Test-Path $script:LogFile)) { Start-Process notepad.exe -ArgumentList "`"$script:LogFile`"" }
        else {
            [System.Windows.MessageBox]::Show("No log file yet.", "App Installer",
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        }
    })

    $window.Add_Closing({
        param($sender, $e)
        if ($script:Installing -and -not $script:AllowClose) {
            $res = [System.Windows.MessageBox]::Show(
                "An installation is currently running. Really exit?", "App Installer",
                [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
            if ($res -ne [System.Windows.MessageBoxResult]::Yes) { $e.Cancel = $true }
        }
    })

    $window.Add_ContentRendered({
        if (-not $script:ScanDone -and $script:WingetPath) {
            try {
                Invoke-InstalledScan
            }
            catch {
                $script:ScanDone = $true
                Set-ScanStatus "failed ($($_.Exception.Message)) - statuses unavailable, you can still install."
            }
            Build-SelectionPage
            if ($script:Page -eq 0) { $script:ui.btnNext.IsEnabled = $true }
        }
    })

    if ($ValidateOnly) {
        # Headless self-test: scan + build all pages, print results, no window.
        Write-Host ""
        Write-Host "=== VALIDATE MODE ===" -ForegroundColor Cyan
        Write-Host "Catalog: $($script:Apps.Count) apps in $catCount categories" -ForegroundColor Cyan
        if (-not $script:WingetPath) { throw "winget not found" }
        Invoke-InstalledScan
        Build-SelectionPage
        foreach ($app in $script:Apps) {
            $disp = Get-StatusDisplay -App $app
            Write-Host ("  {0,-42} {1,-40} {2}" -f $app.Id, $app.Name, $disp.Text)
        }
        # exercise review/summary builders with everything selected
        foreach ($app in $script:Apps) { $app.CheckBox.IsChecked = $true }
        Build-ReviewPage
        Build-SummaryPage
        Write-Host ""
        Write-Host "VALIDATION PASSED (catalog + scan + all GUI pages built without errors)" -ForegroundColor Green
        exit 0
    }

    # hide the (elevated) console window behind the GUI
    try {
        Add-Type -Namespace Native -Name ConsoleUtil -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
        [Native.ConsoleUtil]::ShowWindow([Native.ConsoleUtil]::GetConsoleWindow(), 0) | Out-Null
    }
    catch { }

    Show-Page 0
    $null = $window.ShowDialog()
}
catch {
    $msg = "Fatal error: $($_.Exception.Message)`r`n`r`n$($_.ScriptStackTrace)"
    Write-Log $msg
    if ($ValidateOnly) {
        Write-Host $msg -ForegroundColor Red
        exit 1
    }
    try {
        [System.Windows.MessageBox]::Show($msg, "App Installer - Error",
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
    catch { Write-Host $msg -ForegroundColor Red; Pause }
    exit 1
}

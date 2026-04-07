$categories = [ordered]@{
    "Browsers & Security" = @("Brave.Brave", "TorProject.TorBrowser", "insecure.nmap")
    "Development Tools"   = @("Microsoft.VisualStudioCode", "Docker.DockerDesktop", "Python.Python.3.0", "Git.Git")
    "Utilities"           = @("7zip.7zip", "Rufus.Rufus", "JAMSoftware.TreeSize.Free", "CharlesMilette.TranslucentTB")
    "Networking & Admin"  = @("PuTTY.PuTTY", "WinSCP.WinSCP", "Microsoft.Sysinternals.ProcessExplorer")
    "Productivity"        = @("Notepad++.Notepad++", "Notion.Notion", "Obsidian.Obsidian", "Adobe.Acrobat.Reader.64-bit")
    "Communication & Entertainment" = @("Discord.Discord", "Spotify.Spotify")
    "Gaming"              = @("Valve.Steam", "EpicGames.EpicGamesLauncher", "Ubisoft.Connect", "ElectronicArts.EADesktop")
}

$installList = New-Object System.Collections.Generic.List[string]

foreach ($category in $categories.Keys) {
    Write-Host "`n--- $category ---" -ForegroundColor Magenta
    foreach ($app in $categories[$category]) {
        $choices = [System.Management.Automation.Host.ChoiceDescription[]] @(
            (New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "Install $app"),
            (New-Object System.Management.Automation.Host.ChoiceDescription "&No", "Skip $app")
        )
        $decision = $host.ui.PromptForChoice("Selection", "Do you want to install " + $app + "?", $choices, 1)
        
        if ($decision -eq 0) {
            $installList.Add($app)
            Write-Host "Added $app to queue." -ForegroundColor Gray
        }
    }
}

Write-Host "`nStarting installations..." -ForegroundColor Cyan

foreach ($app in $installList) {
    Write-Host "Installing $app..." -ForegroundColor Cyan
    winget install --id $app -e --silent --accept-source-agreements --accept-package-agreements
}

Write-Host "`nAll processes complete." -ForegroundColor Green
Pause
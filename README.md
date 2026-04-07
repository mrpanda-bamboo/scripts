# scripts

A small collection of Windows utility scripts for app installation and startup inspection.

## Included Scripts

### `installation_script_apps.ps1`
- Interactive PowerShell script that prompts for common applications by category.
- Uses `winget` to install selected apps silently.
- App categories included:
  - Browsers & Security
  - Development Tools
  - Utilities
  - Networking & Admin
  - Productivity
  - Communication & Entertainment
  - Gaming
- Each prompt asks whether to install the current app, then installs selected items with:
  - `winget install --id <AppId> -e --silent --accept-source-agreements --accept-package-agreements`

### `show_all_autostart_apps.bat`
- Batch script that lists startup entries and autostart applications.
- Displays:
  - User startup folder (`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup`)
  - System startup folder (`%PROGRAMDATA%\Microsoft\Windows\Start Menu\Programs\Startup`)
  - Registry `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
  - Registry `HKLM\Software\Microsoft\Windows\CurrentVersion\Run`
  - Registry `HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run`

## Requirements
- Windows
- `winget` available in PATH for `installation_script_apps.ps1`
- PowerShell for running the `.ps1` script

## Usage
1. Open PowerShell in this folder.
2. Run the installer script:
   ```powershell
   .\installation_script_apps.ps1
   ```
3. Run the autostart report script using Command Prompt or by double-clicking:
   ```cmd
   show_all_autostart_apps.bat
   ```

## Notes
- The installer script is designed to be interactive and add selected apps to a queue before installing.
- The autostart script provides a quick overview of startup locations and registry run keys.

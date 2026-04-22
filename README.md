# scripts

A small collection of Windows utility scripts for app installation and startup inspection.

## Included Scripts

### [`Apps installation winget/`](Apps%20installation%20winget/)
- Interactive PowerShell installer that bulk-installs apps via `winget`.
- **Auto-elevation** — automatically requests Administrator privileges via UAC on launch.
- **Section-based TUI** — browse one category at a time using keyboard controls:
  - `↑` / `↓` — Navigate apps
  - `Space` — Toggle an app on or off
  - `Enter` — Confirm and move to the next section
- Categories: Browsers & Security, Development Tools, Utilities, Networking & Admin, Productivity, Communication & Entertainment, Gaming.
- Installs all selected apps silently at the end with a success/fail summary.
- See the [sub-folder README](Apps%20installation%20winget/README.md) for the full app list and details.

### `show_all_autostart_apps.bat`
- Batch script that lists startup entries and autostart applications.
- Displays:
  - User startup folder (`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup`)
  - System startup folder (`%PROGRAMDATA%\Microsoft\Windows\Start Menu\Programs\Startup`)
  - Registry `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
  - Registry `HKLM\Software\Microsoft\Windows\CurrentVersion\Run`
  - Registry `HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run`

## Requirements
- Windows 10 / 11
- `winget` available in PATH (verify with `winget --version`)
- PowerShell 5.1+ for the `.ps1` script

## Usage
1. Open PowerShell in this folder.
2. Run the app installer:
   ```powershell
   .\Apps` installation` winget\installation_script_apps.ps1
   ```
3. Run the autostart report by double-clicking or via Command Prompt:
   ```cmd
   show_all_autostart_apps.bat
   ```

## Notes
- The installer automatically elevates to Administrator — no need to right-click "Run as Administrator".
- The installer uses a section-by-section interactive menu — no more yes/no prompts for each app.
- The autostart script provides a quick overview of all startup locations and registry run keys.

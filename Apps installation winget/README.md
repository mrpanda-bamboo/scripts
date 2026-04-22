# 🚀 Windows App Installer (winget)

A PowerShell script that bulk-installs Windows applications via [winget](https://learn.microsoft.com/en-us/windows/package-manager/winget/) using an interactive, keyboard-driven selection menu.

## Features

- **Auto-elevation** — The script automatically requests Administrator privileges via UAC when launched.
- **Interactive TUI** — Navigate with arrow keys, toggle apps with `Space`, confirm with `Enter`.
- **Section-based browsing** — Apps are grouped by category; press `Enter` to advance to the next section.
- **Silent install** — Every selected app installs silently in the background with auto-accepted agreements.
- **Queue summary** — Review exactly what will be installed before the process starts.

## Prerequisites

| Requirement | Notes |
|---|---|
| **Windows 10 / 11** | winget is pre-installed on recent builds. |
| **winget** | Verify by running `winget --version` in a terminal. If missing, install *App Installer* from the Microsoft Store. |
| **PowerShell 5.1+** | Ships with Windows. PowerShell 7 works too. |

## Quick Start

1. **Clone or download** this repository.
2. Press **Win + R** to open the Run dialog.
3. Type the following command (replace the path with your actual path to the script):
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File "C:\path\to\installation_script_apps.ps1"
   ```
4. Press **Ctrl + Shift + Enter** to run it as Administrator.
5. A **UAC prompt** will appear — accept it to grant Administrator privileges.
6. Use the interactive menu to pick your apps:
   - `↑` / `↓` — Move the highlight up or down.
   - `Space` — Toggle the highlighted app on or off.
   - `Enter` — Confirm your selection and move to the next category.
7. After the last category, the script shows a summary and installs everything automatically.

> **Note:** If you decline the UAC prompt, the script will display an error and exit.
> You can also right-click the script and select *Run as Administrator* manually.

> **Tip:** If execution policies block the script, run
> `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` first.

## Included Applications

### 🌐 Browsers & Security
| App | winget ID |
|---|---|
| Brave Browser | `Brave.Brave` |
| Tor Browser | `TorProject.TorBrowser` |
| Nmap | `insecure.nmap` |
| Wireshark | `WiresharkFoundation.Wireshark` |
| Burp Suite Community | `PortSwigger.BurpSuite.Community` |

### 🛠️ Development Tools
| App | winget ID |
|---|---|
| Visual Studio Code | `Microsoft.VisualStudioCode` |
| Docker Desktop | `Docker.DockerDesktop` |
| Python 3 | `Python.Python.3.0` |
| Git | `Git.Git` |
| Claude Code (Anthropic) | `Anthropic.ClaudeCode` |
| Antigravity (Google) | `Google.Antigravity` |

### ⚙️ Utilities
| App | winget ID |
|---|---|
| 7-Zip | `7zip.7zip` |
| Rufus | `Rufus.Rufus` |
| TreeSize Free | `JAMSoftware.TreeSize.Free` |
| TranslucentTB | `CharlesMilette.TranslucentTB` |
| qFlipper | `FlipperDevicesInc.qFlipper` |

### 🔗 Networking & Admin
| App | winget ID |
|---|---|
| PuTTY | `PuTTY.PuTTY` |
| WinSCP | `WinSCP.WinSCP` |
| Process Explorer | `Microsoft.Sysinternals.ProcessExplorer` |
| OpenVPN | `OpenVPNTechnologies.OpenVPN` |
| TeamViewer | `TeamViewer.TeamViewer` |
| VirtualBox | `Oracle.VirtualBox` |

### 📝 Productivity
| App | winget ID |
|---|---|
| Notepad++ | `Notepad++.Notepad++` |
| Notion | `Notion.Notion` |
| Obsidian | `Obsidian.Obsidian` |
| Adobe Acrobat Reader (64-bit) | `Adobe.Acrobat.Reader.64-bit` |

### 💬 Communication & Entertainment
| App | winget ID |
|---|---|
| Discord | `Discord.Discord` |
| Spotify | `Spotify.Spotify` |

### 🎮 Gaming
| App | winget ID |
|---|---|
| Steam | `Valve.Steam` |
| Epic Games Launcher | `EpicGames.EpicGamesLauncher` |
| Ubisoft Connect | `Ubisoft.Connect` |
| EA Desktop | `ElectronicArts.EADesktop` |

## winget Cheat Sheet

```powershell
# Search for a package
winget search <name>

# Install a package by exact ID
winget install --id <winget.ID> -e

# List installed packages
winget list

# Upgrade all installed packages
winget upgrade --all
```

## License

This project is provided as-is for personal use. Feel free to modify and redistribute.
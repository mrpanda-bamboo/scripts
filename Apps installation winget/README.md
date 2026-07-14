# 🚀 Windows App Installer (winget wizard)

A PowerShell **installation wizard with a real GUI** that bulk-installs Windows applications via [winget](https://learn.microsoft.com/en-us/windows/package-manager/winget/). Pick your apps from a catalog, see what is already installed, decide per app what to do, and watch the installs run with live output.

No accounts, keys or private data anywhere — the repo only contains public winget package IDs.

![wizard pages: Welcome → Select apps → Review → Install → Finish]

## Features

- **Wizard GUI (WPF)** — Welcome → Select apps → Review → Install → Finish. Built into PowerShell/Windows, no extra downloads.
- **Installed-app detection** — before you select anything, every app shows its status:
  - `not installed`
  - `installed vX – up to date`
  - `installed vX – update available`
  - `⚠ variant installed: …` (e.g. TeamViewer **Host** blocking the **Full Client**)
- **Per-app decisions** — for anything already on the PC choose: **Skip / Update / Reinstall (force) / Replace variant** (uninstalls the conflicting variant first, then installs your pick).
- **Robust install engine**
  - "Already installed, no update available" counts as **success**, not failure.
  - MSI error **1618** ("another installation is in progress"): waits for the Windows Installer to become free and retries automatically (up to 3×).
  - Installers that refuse admin (e.g. **Spotify**): marked `noAdmin` in the catalog and installed through a **de-elevated** user-context process.
  - Exit codes are translated into plain-language reasons in the summary.
- **Retry failed** — one click on the summary page re-runs only the failed apps.
- **Log file** — every run writes `install-log_<timestamp>.txt` next to the script.
- **Easy to extend** — the whole catalog lives in [`apps.json`](apps.json). Adding an app = one JSON entry, no code changes.

## Prerequisites

| Requirement | Notes |
|---|---|
| **Windows 10 / 11** | winget is pre-installed on recent builds. |
| **winget** | Verify with `winget --version`. If missing, install *App Installer* from the Microsoft Store. |
| **PowerShell 5.1+** | Ships with Windows. |

## Quick Start

1. **Clone or download** this repository (keep `Install-Apps.ps1` and `apps.json` together).
2. Press **Win + R** and run (adjust the path):
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File "C:\path\to\Install-Apps.ps1"
   ```
3. Accept the **UAC prompt** (the script elevates itself; admin is needed for machine-wide installs).
4. Follow the wizard:
   - **Welcome** — waits a few seconds while the PC is scanned for installed apps.
   - **Select apps** — tick what you want; use the filter box or the category checkboxes.
   - **Review** — apps that already exist show a dropdown: Skip / Update / Reinstall / Replace variant.
   - **Install** — live progress per app plus winget output.
   - **Finish** — summary with readable failure reasons, *Retry failed* and *Open log*.

> **Note:** apps flagged `noAdmin` (Spotify) are installed in user context — a console window may appear briefly. That is expected.

## Adding / changing apps (`apps.json`)

Adding an app is one entry in `apps.json`:

```json
{ "name": "PuTTY", "id": "PuTTY.PuTTY" }
```

Find the ID with `winget search <name>`. Optional fields:

| Field | Purpose | Example |
|---|---|---|
| `source` | Package source, default `winget` | `"source": "msstore"` |
| `noAdmin` | Installer refuses to run elevated → install de-elevated | Spotify |
| `conflicts` | IDs of variants that block this app; the wizard detects them and offers **Replace** | TeamViewer Host vs Full Client |
| `args` | Extra winget arguments for this app | `"args": "--scope machine"` |
| `verifyCommand` | After install, check this command is on PATH | `"verifyCommand": "claude"` |

Full example:

```json
{
  "name": "TeamViewer (Full Client)",
  "id": "TeamViewer.TeamViewer",
  "conflicts": [ "TeamViewer.TeamViewer.Host" ]
}
```

New categories are created by adding a new block to the `categories` array.

### Testing your changes

After editing `apps.json` you can self-test without installing anything:

```powershell
powershell.exe -ExecutionPolicy Bypass -File Install-Apps.ps1 -ValidateOnly
```

This validates the catalog, runs the installed-app scan, builds every GUI page headlessly and prints the detected status of each app.

## Included applications

### 🌐 Browsers & Security
| App | winget ID |
|---|---|
| Brave Browser | `Brave.Brave` |
| Tor Browser | `TorProject.TorBrowser` |
| 1Password | `AgileBits.1Password` |
| Nmap | `Insecure.Nmap` |
| Wireshark | `WiresharkFoundation.Wireshark` |
| Burp Suite Community | `PortSwigger.BurpSuite.Community` |

### 🤖 AI Tools
| App | winget ID |
|---|---|
| Claude (Desktop) | `Anthropic.Claude` |
| Claude Code (CLI) | `Anthropic.ClaudeCode` — verifies the `claude` command after install |
| Antigravity (Google) | `Google.Antigravity` |

### 🛠️ Development Tools
| App | winget ID |
|---|---|
| Visual Studio Code | `Microsoft.VisualStudioCode` |
| Docker Desktop | `Docker.DockerDesktop` |
| Python 3.13 | `Python.Python.3.13` |
| Git | `Git.Git` |

### ⚙️ Utilities
| App | winget ID |
|---|---|
| 7-Zip | `7zip.7zip` |
| Rufus | `Rufus.Rufus` |
| TreeSize Free | `JAMSoftware.TreeSize.Free` |
| TranslucentTB | `CharlesMilette.TranslucentTB` |
| qFlipper | `FlipperDevicesInc.qFlipper` |
| Mouse Jiggler | `ArkaneSystems.MouseJiggler` |
| OP Auto Clicker | `OPAutoClicker.OPAutoClicker` |

### 🔗 Networking & Admin
| App | winget ID |
|---|---|
| PuTTY | `PuTTY.PuTTY` |
| WinSCP | `WinSCP.WinSCP` |
| Process Explorer | `Microsoft.Sysinternals.ProcessExplorer` |
| OpenVPN | `OpenVPNTechnologies.OpenVPN` |
| TeamViewer (Full Client) | `TeamViewer.TeamViewer` — detects installed **Host** variant |
| VirtualBox | `Oracle.VirtualBox` |

### 📝 Productivity
| App | winget ID |
|---|---|
| Notepad++ | `Notepad++.Notepad++` |
| Notion | `Notion.Notion` |
| Obsidian | `Obsidian.Obsidian` |
| Adobe Acrobat Reader (64-bit) | `Adobe.Acrobat.Reader.64-bit` |
| Microsoft 365 Apps | `Microsoft.Office` |

### 💬 Communication & Entertainment
| App | winget ID |
|---|---|
| Discord | `Discord.Discord` |
| Spotify | `Spotify.Spotify` — installed de-elevated (`noAdmin`) |

### 🎮 Gaming
| App | winget ID |
|---|---|
| Steam | `Valve.Steam` |
| Epic Games Launcher | `EpicGames.EpicGamesLauncher` |
| Ubisoft Connect | `Ubisoft.Connect` |
| EA Desktop | `ElectronicArts.EADesktop` |

## Troubleshooting

| Symptom | Meaning / fix |
|---|---|
| `Already installed - no newer version available` | Not an error — the app is current. |
| `No package found - check the winget ID` | The ID in `apps.json` is wrong. IDs are **case-sensitive** (e.g. `Insecure.Nmap`, not `insecure.nmap`). |
| `MSI error 1618` | Another installer was running. The wizard retries automatically; if it still fails, wait and use *Retry failed*. |
| `MSI error 1603` | Generic installer failure — often a conflicting variant/edition is installed. Add it to `conflicts` in `apps.json` or uninstall it manually. |
| `Installer refuses to run as administrator` | Set `"noAdmin": true` for that app in `apps.json`. |
| Command (e.g. `claude`) not found after install | Open a **new** terminal — PATH changes only apply to new shells. |

## License

This project is provided as-is for personal use. Feel free to modify and redistribute.

---

*Legacy version: the previous console-only script (`installation_script_apps.ps1`) has been replaced by `Install-Apps.ps1` + `apps.json`.*

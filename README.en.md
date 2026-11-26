<div id="top">

<!-- HEADER -->
<div align="center">

# `❯ GoLive-Bostil`

<em>Brings Discord Go Live back in regions where it gates the video off — by running one file.</em>

<!-- BADGES -->
<img src="https://img.shields.io/badge/PowerShell-5391FE.svg?style=flat&logo=PowerShell&logoColor=white" alt="PowerShell">
<img src="https://img.shields.io/badge/GNU%20Bash-4EAA25.svg?style=flat&logo=GNU-Bash&logoColor=white" alt="GNU Bash">
<img src="https://img.shields.io/badge/Python-3776AB.svg?style=flat&logo=Python&logoColor=white" alt="Python">
<img src="https://img.shields.io/badge/JSON-000000.svg?style=flat&logo=JSON&logoColor=white" alt="JSON">
<br>
<img src="https://img.shields.io/badge/Platforms-Windows%20%7C%20Linux-informational?style=flat" alt="Platforms: Windows | Linux">
<img src="https://img.shields.io/badge/License-no%20warranty-lightgrey?style=flat" alt="No warranty">

</div>
<br>

> **Don't know how to set up a VPN or use a proxy? Run one file and you're done.**

A single-command tool — **PowerShell on Windows, bash on Linux** — that brings Discord **Go Live**
(screen streaming) back in regions where Discord gates it off at the voice SFU. In Brazil the block
shows up as **Error 2012** (`video-stream-receiver-ready-timeout`): audio and the thumbnail work, the
video just never starts. No VPN, no tunnel.

> **Scope / ethics.** Security-research project, on my **own account and machines**. Running it
> violates Discord's Terms of Service and can get an account actioned. Use it only on accounts and
> machines you own, at your own risk — not to evade enforcement against others or to run a service.

**BOTH USERS (the streamer and the watcher) MUST run the script for it to work.** The patch is purely
client-sided — whoever isn't running it stays regionally blocked by the stock app.

---

## Table of Contents

- [Overview](#overview)
- [Project Structure](#project-structure)
- [Getting Started (Windows)](#getting-started-windows)
- [Usage](#usage)
- [Linux](#linux)
- [How it works](#how-it-works)
- [License / disclaimer](#license--disclaimer)

---

## Overview

The Go Live region gate trusts an address the **client** supplies (the Voice Gateway `op 1`
`d.data.address`) instead of the address the server actually **observes** on the wire. Rewrite that
field to a non-Brazil IP and the gate opens, while the media keeps flowing over the real UDP path.
This tool does it in one command: it patches the encoder, injects the forge and the play shim, and
hands control back to you.

Both sides (streamer and watcher) must run it — one-sided leaves the gate shut. The shims are
session-scoped (a Discord reload clears them); the encoder patch is on-disk. Re-running skips the
already-applied patch and re-injects the shims.

**Why this works, the validation, packet captures and maintenance:** see
[`EXPLAINER.en.md`](EXPLAINER.en.md). **Formal vulnerability write-up:** [`DISCLOSURE.md`](DISCLOSURE.md).

---

## Project Structure

```sh
└── golive-bostil/
    ├── GoLive-Bostil.ps1   # Windows — PowerShell orchestrator (patch + forge + play shim)
    ├── GoLive-Bostil.cmd   # Windows — double-click shortcut that calls the .ps1
    ├── golive-bostil.sh    # Linux   — bash orchestrator (same modes and flow)
    ├── golive_patch.py     # Linux   — ELF encoder patcher (discord_voice.node)
    ├── signatures.json     # encoder-patch signatures, per Discord build
    ├── README.md           # Portuguese version
    ├── README.en.md        # this file (English)
    ├── EXPLAINER.md         # how/why it works (PT-BR)
    ├── EXPLAINER.en.md      # how/why it works (English)
    └── DISCLOSURE.md        # formal vulnerability write-up (CWE, repro, fix)
```

---

## Getting Started (Windows)

> **On Linux?** The steps below are for Windows. Jump to the [Linux](#linux) section.

1. Download the repo (**Code → Download ZIP**, or `git clone`) and unzip it.
2. **Double-click `GoLive-Bostil.cmd`.** Or open PowerShell in the folder and run the command below.
   The first run might install Python on its own — let it, it's silent and asks nothing.
3. The script patches the encoder, opens Discord with the forge already live, and stops. **Leave
   Discord open.**
4. In Discord, join the **same voice channel** as the other person.
5. Hit **Screen / Go Live**, pick a screen or window, start. Click the **other person's live tile**
   to watch.
6. Discord restarted on you? Run it again (double-click the `.cmd`).

Prefer PowerShell over the `.cmd`:

```powershell
powershell -ExecutionPolicy Bypass -File .\GoLive-Bostil.ps1
```

> **Both sides have to run it** — the streamer and the watcher. No VPN, no tunnel. To undo the
> encoder patch later, use `-Mode Revert`.

---

## Usage

Stream and watch (the default — patch + forge + play shim):

```powershell
powershell -ExecutionPolicy Bypass -File .\GoLive-Bostil.ps1
```

Pick a different forged IP (any non-Brazil IPv4):

```powershell
powershell -ExecutionPolicy Bypass -File .\GoLive-Bostil.ps1 -ForgeIp 8.8.8.8
```

Undo the on-disk encoder patch (restores the stock module from backup, or rebuilds it from the state
file):

```powershell
powershell -ExecutionPolicy Bypass -File .\GoLive-Bostil.ps1 -Mode Revert
```

Health-check the patch after a Discord update (read-only, touches nothing):

```powershell
powershell -ExecutionPolicy Bypass -File .\GoLive-Bostil.ps1 -Mode Probe
```

### Two people streaming to each other

Both run the default command (same `-ForgeIp` or different, both work). Then, by hand in Discord:
both join the **same voice channel**, each hits **Screen / Go Live** and starts, each clicks the
**other person's live tile** to watch. If Discord restarts, re-run the command — it skips the
already-applied encoder patch and re-injects the shims.

### Parameters (Windows)

| Parameter     | Default           | Meaning                                              |
|---------------|-------------------|------------------------------------------------------|
| `-Mode`       | `Forge`           | `Forge` / `Watch` (identical today), `Revert`, or `Probe` |
| `-ForgeIp`    | `149.22.81.205`   | Non-Brazil IPv4 written into op 1 `d.data.address`   |
| `-DebugPort`  | `9222`            | Discord remote-debugging port                        |

Logs: `%LOCALAPPDATA%\GoLiveBostil\install.log`.

### Requirements (Windows)

- Windows, with Discord desktop installed under `%LOCALAPPDATA%`.
- PowerShell. Nothing to install by hand — the script pulls in Python 3 (per-user, silent) if it's
  missing, only to run the binary-patch locator.
- Both the streamer and the viewer run it (both ends forge).

---

## Linux

The Linux port is a bash script, `golive-bostil.sh`, same four modes and same flow as the Windows
version (it drives Discord's remote-debugging port over CDP and patches the same `discord_voice.node`,
only as an ELF binary instead of a PE DLL).

```bash
bash golive-bostil.sh                 # Forge (default): patch + forge + play shim
bash golive-bostil.sh --forge-ip 8.8.8.8
bash golive-bostil.sh --mode Revert   # undo the on-disk encoder patch
bash golive-bostil.sh --mode Probe    # read-only health check
```

### Parameters (Linux)

| Flag            | Default           | Meaning                                              |
|-----------------|-------------------|------------------------------------------------------|
| `--mode`        | `Forge`           | `Forge` / `Watch` (identical today), `Revert`, `Probe` |
| `--forge-ip`    | `149.22.81.205`   | Non-Brazil IPv4 written into op 1 `d.data.address`   |
| `--debug-port`  | `9222`            | Discord remote-debugging port                        |
| `--timeout`     | `45`              | Seconds to wait for the Discord DevTools target      |
| `--no-pause`    | —                 | Skip the final prompt (or set env `GOLIVE_NOPAUSE`)  |

Logs: `$XDG_DATA_HOME/GoLiveBostil/install.log` (i.e. `~/.local/share/GoLiveBostil/install.log`).

### Requirements (Linux)

- Linux with Discord desktop — native (deb/tar/AUR), **Flatpak** (`com.discordapp.Discord`), or
  **Snap**. The script auto-detects all three (stable, PTB, Canary).
- `python3` (standard library only — the CDP WebSocket client and the binary-patch locator are
  inline). Unlike Windows, it is **not** auto-installed: if missing, install it
  (`sudo apt install python3` / `sudo dnf install python3` / `sudo pacman -S python`).
- Both the streamer and the viewer run it (both ends forge).

### Encoder-patch signatures on Linux

The forge shim and the play shim are OS-independent and work as-is. The **encoder patch** relies on
byte signatures, and the Linux `discord_voice.node` is a different ELF binary from the Windows PE
with its own byte layout — so Linux needs its own entries. `signatures.json` ships a **verified entry
for the native build `app-1.0.171`** (2 `lea` sites; keyframe constant loaded via `mov rax`), tested
on-device: the patch applies and reverts byte-perfect. For that build the script patches the encoder
normally.

For a Linux build **without** an entry, the script logs a warning and **skips the encoder patch**
(the region gate still opens via the forge shim; some receivers may fail to decode H265 video). To
add one, run `--mode Probe`, re-derive the codec-table anchor, the `lea` sites, and the keyframe
constants for your build, and append the entry to `signatures.json` keyed by the `app-<version>`
directory name — same schema, same file for both OSes. See [`EXPLAINER.en.md`](EXPLAINER.en.md) for
the derivation.

---

## How it works

One command, three jobs, then it hands control back to you.

1. **Encoder patch** (`discord_voice.node`, on disk). Forces the Go Live encoder to **H264** (H265
   trips up many receivers) with a short keyframe interval so a mid-join viewer gets a frame fast.
   Reversible: writes a `.stockbak` backup and a `.patch-state.json`. Runs while Discord is stopped.
2. **Forge shim** (renderer, via CDP). Discord launches with `--remote-debugging-port`; a script is
   injected before the app bundle loads and rewrites the Voice Gateway `op 1` `d.data.address` to
   your chosen non-BR IP. That's the part that opens the region gate.
3. **Play shim** (renderer). Forces `.play()` on the big remote `<video>` (Discord sometimes leaves
   it paused, so zero frames decode even with video arriving).

The two shims are session-scoped (a Discord reload clears them); the encoder patch is on-disk.
Re-running skips the patch when it's already applied (SHA match) and re-injects the shims.

---

## License / disclaimer

No warranty. This project is provided **for security research and educational purposes only**, as part
of a responsible-disclosure effort carried out on the author's own account and machines.

**Use at your own risk.** Running this tool violates Discord's Terms of Service and may lead to
suspension or termination of your account. You are solely responsible for how you use it and for
complying with Discord's Terms of Service and all laws that apply to you.

The software is provided "as is", without warranty of any kind. To the maximum extent permitted by
law, the author accepts **no liability** for any damage, loss, account action, or legal consequence
arising from the use, misuse, or distribution of this software **by you or by any third party**. By
downloading, running, or distributing it, you accept these terms and assume full responsibility for
your own actions.

This project is not affiliated with, authorized by, or endorsed by Discord Inc.

---

🇧🇷 Versão em português: [`README.md`](README.md).

<sub>README structure generated with <a href="https://github.com/eli64s/readme-ai">readme-ai</a>; content written by hand.</sub>

<div align="right"><a href="#top">⬆ back to top</a></div>

</div>

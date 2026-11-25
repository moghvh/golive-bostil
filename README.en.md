# GoLive-Bostil

**Don't know how to set up a VPN or use a proxy? Run one file and you're done.**

A single-command PowerShell tool that brings Discord **Go Live** (screen streaming) back in regions
where Discord gates it off at the voice SFU. In Brazil that block shows up as **Error 2012**
(`video-stream-receiver-ready-timeout`): audio and the thumbnail work, the video just never starts.
No VPN, no tunnel.

> **Scope / ethics.** Security-research project, on my **own account and machines**. Running it
> violates Discord's Terms of Service and can get an account actioned. Use it only on accounts and
> machines you own, at your own risk — not to evade enforcement against others or to run a service.

---

## 🚀 Quick start

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

### Parameters

| Parameter     | Default           | Meaning                                              |
|---------------|-------------------|------------------------------------------------------|
| `-Mode`       | `Forge`           | `Forge` / `Watch` (identical today), `Revert`, or `Probe` |
| `-ForgeIp`    | `149.22.81.205`   | Non-Brazil IPv4 written into op 1 `d.data.address`   |
| `-DebugPort`  | `9222`            | Discord remote-debugging port                        |

Logs: `%LOCALAPPDATA%\GoLiveBostil\install.log`.

### Requirements

- Windows, with Discord desktop installed under `%LOCALAPPDATA%`.
- PowerShell. Nothing to install by hand — the script pulls in Python 3 (per-user, silent) if it's
  missing, only to run the binary-patch locator.
- Both the streamer and the viewer run it (both ends forge).

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

**Why this works, the validation, packet captures and maintenance:** see
[`EXPLAINER.en.md`](EXPLAINER.en.md). **Formal vulnerability write-up:** [`DISCLOSURE.md`](DISCLOSURE.md).

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

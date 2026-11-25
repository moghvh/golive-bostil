# GoLive-Bostil — how it works and why

The research and engineering notes behind the tool. For install and usage, see
[`README.en.md`](README.en.md). For the formal vulnerability write-up (CWE, protocol repro,
remediation), see [`DISCLOSURE.md`](DISCLOSURE.md).

---

## The bug, in one sentence

**Discord's Go Live region gate trusts an address the client hands it instead of the one it actually
sees on the wire.**

When a client sets up its voice/video transport, it sends a Voice Gateway **op 1 (Select Protocol)**
message over the WebSocket. That message carries `d.data.address`: the client's own
externally-visible IP, found through Discord's UDP IP-discovery. The SFU looks at the **region of
that signaled address** to decide whether Go Live video is allowed. The media, though, rides the
**observed UDP 5-tuple** — the real source address and port of the packets the SFU receives — not the
signaled field.

So the signaled address is authoritative for the geo-gate but cosmetic for delivery. Rewrite it to a
non-restricted IP and two things happen:

- the gate opens (the stream's `receiver_count` goes `0 → 1`, the encoder kicks in), and
- media still flows over the real UDP path, so the viewer actually receives and decodes the video.

This is textbook **improper-trust-of-client-controlled-data**. The server should gate on what it
observes (the 5-tuple it already sees), never on a value the client gets to set.

---

## What the validation showed

Both endpoints on a real Brazilian IP, no tunnel, rewriting only `d.data.address`:

| Forge applied            | Target IP        | Result                                  |
|--------------------------|------------------|-----------------------------------------|
| Publisher only           | non-BR           | **FAIL** (encoder never starts)         |
| Viewer only              | non-BR           | **FAIL**                                |
| Both, to a **BR** IP     | BR               | **FAIL** (gate reads the signaled region)|
| Both, to a non-BR IP     | `149.22.81.205`  | **PASS** (~30 fps, 1280×704 decoded)    |
| Both, to a non-BR IP     | `8.8.8.8`        | **PASS**                                |
| Both, different IP each  | non-BR           | **PASS**                                |

Takeaways: both ends have to forge; any non-Brazil IPv4 does the job (it doesn't need to be routable
or yours — it's only read for its region); and the voice channel region can stay as-is.

### Confirmed by packet capture (2026-11-23)

Re-ran it end-to-end with **tcpdump** on both ends, each on a real Brazilian IP (a residential-BR
publisher and a Mullvad-BR viewer, so two different BR IPs), with **no non-BR tunnel** anywhere:

- **Viewer-only forge** (publisher signals its real BR address): the viewer sees 2397 packets, every
  one **< 500 B** — audio and RTCP, zero video. The SFU just won't relay the video. That's Error 2012.
- **Both ends forge** (`op 1` → a non-BR IP): the viewer gets **1436 packets ≥ 900 B** (video, up to
  1243 B) and Discord decodes **4826 frames at 30 fps** (450×720), no `receiver-ready-timeout` in sight.

So the relay gate reads the **signaled `op 1` address**, not the real UDP source. Forging both ends is
enough, on a real BR IP, no VPN. An earlier note claimed a server-side "second gate" keyed on the real
source IP and said you needed a non-BR egress. That was wrong — it came from runs where the publisher
hadn't been forged.

---

## Maintenance & future-proofing

It's built to ride out *some* Discord updates, but a few parts are tied to the build. Worst first:

1. **Encoder patch signatures are build-specific.** The H264/H265 codec-table anchor and the
   keyframe-interval byte signatures came off build **1.0.9269**. Discord updates constantly, and a
   recompiled `discord_voice.node` can move or change those byte patterns. The script now **warns
   loudly** when the installed build differs, and logs **ERRO** if the locator doesn't fully apply, so
   a broken patch shows itself instead of failing quietly. Per breaking update you re-derive the
   signatures — find the `H264\0H265` codec table, the four `lea` sites that reference the H265
   display-delta, and the keyframe-interval constants `3000/100000 → 60/2000` — then add the new
   build's values. They live in `signatures.json` (plus an embedded default), so it's a data edit; run
   `-Mode Probe` to see which one drifted.

2. **CDP injection needs `--remote-debugging-port` to be honored.** If Discord kills remote debugging
   in production builds, the whole forge/play injection path dies with it. This is the single biggest
   existential risk, and there's no in-tool workaround.

3. **The forge shim leans on the op 1 payload shape** (`o.d.data.address`, plaintext JSON over the
   voice WebSocket). Change the Select Protocol schema, move IP-discovery, or stop sending the address
   as client-signaled JSON, and the shim needs an update. The protocol's been stable so far. Keep an
   eye on it.

4. **Discord might just fix the flaw** — gate on the observed 5-tuple instead of the signaled field.
   Then forging stops working, full stop, which is the whole point of disclosing it.

5. **Play shim** rides a generic `video` tag plus a size heuristic, so it shrugs off DOM and class
   churn. Lowest-risk piece of the lot.

6. **Launcher behavior.** The script starts the top-level `Discord.exe` with the debug flag and counts
   on it forwarding that flag to the Electron app. If Discord reworks the launcher, revisit this.

### Hardening already in place

- ✅ **Signatures externalized:** an embedded default in the script plus a per-build `signatures.json`,
  so a new build is a data edit, not a code change. To add a build: run `-Mode Probe`, see what
  drifted, add the entry.
- ✅ **`-Mode Probe`:** read-only health check — Discord build, node path, patch state, whether the
  locator finds its sites (per-signature table), and whether the debug port answers. Run it after
  every Discord update.
- ✅ **Python installer verified by Authenticode signature** (Python Software Foundation) before it
  runs; aborts if the signature doesn't check out.

Still on the list:

- Locate the keyframe patch by the **interval constants' values** rather than full fixed byte runs, to
  survive minor recompiles.

---

## Responsible disclosure

The finding underneath this — *the Go Live region gate trusts a client-supplied address rather than
the observed UDP source* — is a real, reportable access-control bug. The right venue is Discord's
security program (HackerOne or `security@discord.com`), privately, with a protocol-level repro and the
fix: derive geo from the server-observed 5-tuple, never from the client field. Publishing a packaged,
working bypass does the opposite — it hands out an evasion tool and undercuts a good-faith report. Keep
the tool private; send the finding to the vendor. Full write-up in [`DISCLOSURE.md`](DISCLOSURE.md).

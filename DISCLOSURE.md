# Security disclosure — Discord Go Live region gate relies on a client-supplied address

**Status:** private draft for submission to Discord (HackerOne / `security@discord.com`).
**Reporter:** account owner, testing on own account and machines.
**Weakness:** CWE-807 — *Reliance on Untrusted Inputs in a Security Decision*
(also CWE-290 — *Authentication/Authorization Bypass by Spoofing*).

---

## Summary

Discord enforces a regional restriction on **Go Live** (screen streaming) video at the voice
media server (SFU). The decision of whether to enable the outbound video stream is made using the
**IP address the client reports in the Voice Gateway `op 1` (Select Protocol) message
(`d.data.address`)** — a value the client controls — instead of the address the server actually
observes for the client's media on the wire.

Because that field is only *signalled* by the client and is **not** the address used to route the
media (media flows over the observed UDP 5-tuple), a client can set `d.data.address` to an IP in a
non-restricted region and the SFU will authorize Go Live video, while the stream still delivers
normally over the real network path.

This lets a client in a restricted region stream and receive Go Live video that the regional policy
is meant to block, **without any VPN, proxy, or change to the actual network route.**

## Affected component

- Voice Gateway signalling — `op 1` **Select Protocol**, field `d.data.address`.
- Go Live / SFU region-gating logic that reads that field to authorize the video stream.

## Impact

- **Regional streaming policy bypass.** A user in a region where Go Live video is withheld can
  enable it by signalling a non-restricted IP. Both the publisher and any viewer that signal a
  non-restricted address obtain a working video stream.
- No user data is exposed and no account is compromised by this flaw itself; the issue is an
  **access-control decision made on client-controlled input**, which undermines any
  region-based policy (regulatory, licensing, or abuse-related) enforced at this layer.

## Root cause

The region check trusts a value the client can freely set. The server already observes the client's
true source address for the media transport (the UDP 5-tuple it receives packets on, used for
delivery), but the **policy decision is bound to the signalled `d.data.address` rather than to that
observed source**. Signalled and observed addresses are allowed to diverge, and only the signalled
one is checked.

## Steps to reproduce (protocol level)

> This demonstrates the trust flaw only. It does not require a VPN, and the gate clears regardless
> of local media-codec handling (codec/decoder behaviour on the client is a separate, local matter
> and is not needed to show the server-side bypass).

1. From a client in a region where Go Live video is restricted, begin a Go Live stream in a voice
   channel. Observe the stream fail to activate (viewer receives
   `video-stream-receiver-ready-timeout`; server-side the stream's receiver/active count stays 0).
2. On the client, intercept the outbound Voice Gateway `op 1` (Select Protocol) message and change
   `d.data.address` from the client's real (restricted-region) IP to any IPv4 in a non-restricted
   region. Forward the modified message. (Any client-side interception of the voice WebSocket
   suffices; the field is plaintext JSON.)
3. Have the viewing client do the same for its own `op 1` message.
4. **Observed result:** the SFU authorizes the stream — the stream's receiver/active count
   transitions from 0 to 1, the encoder activates, and the viewer receives and renders the video —
   while both clients' media continues to route over their real (restricted-region) network path.

### Observations from testing (own account, own machines)

- Real network path unchanged (both endpoints on their genuine restricted-region ISP address,
  confirmed before and after).
- Only `d.data.address` altered.
- Server stream state moved from "receiver count 0 / encoder inactive" to
  "receiver count 1 / encoder active"; viewer decoded a continuous video stream.
- Signalling a **restricted-region** IP in the field did **not** clear the gate, confirming the
  decision is keyed on the *region of the signalled field*, not on the observed source.

## Remediation

Make the region decision on the **server-observed** media source, not on a client-supplied field:

- Bind the Go Live region check to the UDP 5-tuple / source address the SFU actually receives media
  on (the same information used for delivery), or to another server-authoritative signal.
- Do not use `op 1` `d.data.address` (or any client-signalled address) as the input to an
  access-control decision. If it must be retained for transport setup, treat it as untrusted and
  reconcile it against the observed source; reject or re-gate when they diverge across regions.

## Disclosure posture

Reported privately to Discord; no public release of a working bypass. This document describes the
flaw at the protocol level and omits packaging details so it demonstrates the vulnerability without
serving as a ready-to-use evasion tool.

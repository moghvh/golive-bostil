#!/usr/bin/env bash
# =============================================================================
# GoLive-Bostil (Linux port of GoLive-Bostil.ps1)
#
# Go Live forge: monkeypatches Discord's Voice Gateway op1 d.data.address to a
# non-BR IP so the SFU geo-gate clears. Also patches the encoder to H264, and
# injects a play shim so the remote <video> is not left paused. One command,
# both roles. No external dependencies beyond python3 (stdlib only) — the CDP
# client and the WebSocket are implemented inline.
#
# BOTH sides must forge (publisher AND viewer) — one-sided leaves the gate shut.
# The two shims are session-scoped (a Discord reload clears them); the encoder
# patch is on-disk. Re-run after a Discord restart: it skips the encoder patch
# when already applied (sha match) and re-injects the shims.
#
# Usage:
#   bash golive-bostil.sh --mode Forge
#   bash golive-bostil.sh --forge-ip 8.8.8.8
#   bash golive-bostil.sh --mode Revert
#   bash golive-bostil.sh --mode Probe
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------- config / args

MODE='Forge'
DEBUGPORT=9222
TIMEOUT=45
FORGE_IP='149.22.81.205'   # forged ip, any non-Brazil IPv4
NOPAUSE=''

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHER="$SCRIPT_DIR/golive_patch.py"

DATADIR="${XDG_DATA_HOME:-$HOME/.local/share}/GoLiveBostil"
LOGFILE="$DATADIR/install.log"
mkdir -p "$DATADIR"

usage() {
    cat <<'USAGE'
GoLive-Bostil (Linux). Forge Discord Go Live region gate.

  --mode Forge|Watch|Revert|Probe   (default Forge; Watch == Forge)
  --debug-port N                     (default 9222)
  --timeout N                        (default 45)
  --forge-ip IPV4                    (default 149.22.81.205; any non-BR IPv4)
  --no-pause                         (skip the final prompt; or env GOLIVE_NOPAUSE)

Both the streamer and the watcher must run this. Session-scoped: re-run after a
Discord restart. Logs: $XDG_DATA_HOME/GoLiveBostil/install.log
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mode)        MODE="${2:-}"; shift 2 ;;
        --mode=*)      MODE="${1#*=}"; shift ;;
        --debug-port)  DEBUGPORT="${2:-}"; shift 2 ;;
        --debug-port=*) DEBUGPORT="${1#*=}"; shift ;;
        --timeout)     TIMEOUT="${2:-}"; shift 2 ;;
        --timeout=*)   TIMEOUT="${1#*=}"; shift ;;
        --forge-ip)    FORGE_IP="${2:-}"; shift 2 ;;
        --forge-ip=*)  FORGE_IP="${1#*=}"; shift ;;
        --no-pause)    NOPAUSE=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) printf 'Unknown arg: %s\n' "$1" >&2; usage; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- logging

log() {
    local level="$1"; shift; local msg="$*"
    local ts line color='' reset=''
    ts="$(date '+%Y-%m-%d %H:%M:%S.%3N')"
    line="$ts [$level] $msg"
    printf '%s\n' "$line" >>"$LOGFILE" 2>/dev/null || true
    if [ -t 1 ]; then
        reset=$'\033[0m'
        case "$level" in
            OK)   color=$'\033[32m' ;;
            WARN) color=$'\033[33m' ;;
            ERRO) color=$'\033[31m' ;;
        esac
    fi
    printf '%s%s%s\n' "$color" "$line" "$reset" >&2
}

pause_exit() {
    if [ -z "$NOPAUSE" ] && [ -z "${GOLIVE_NOPAUSE:-}" ]; then
        read -r -p 'Enter to exit' _ || true
    fi
}

# ---------------------------------------------------------------- validation

case "$MODE" in
    Forge|Watch|Revert|Probe) ;;
    *) log ERRO "Invalid --mode '$MODE'. Use Forge | Watch | Revert | Probe."; exit 2 ;;
esac

IPRE='^((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])$'
if [ "$MODE" != 'Revert' ] && ! [[ "$FORGE_IP" =~ $IPRE ]]; then
    log ERRO "ForgeIp invalid: '$FORGE_IP'. Use a non-Brazil IPv4 (e.g. 149.22.81.205)."
    exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
    log ERRO "python3 is required. Install it: sudo apt install python3  /  sudo dnf install python3  /  sudo pacman -S python"
    exit 1
fi

# ---------------------------------------------------------------- shims (verbatim)

JS_FORGE="$(cat <<'JSF'
(()=>{try{
  if(window.__wsforge)return 'ALREADY forge='+String(window.__forgeIP);
  window.__wsforge=true; window.__wslog=[];
  window.__forgeIP='__FORGE_IP__';
  const S=WebSocket.prototype.send;
  WebSocket.prototype.send=function(d){
    try{
      if(typeof d==='string' && d.length<6000 && d.indexOf('"op"')>=0 && d.indexOf('address')>=0){
        let o=null; try{o=JSON.parse(d)}catch(e){}
        if(o && (o.op===1) && o.d && o.d.data && o.d.data.address){
          window.__wslog.push('OP1 addr='+o.d.data.address+' port='+o.d.data.port+' mode='+o.d.data.mode);
          if(window.__forgeIP){
            o.d.data.address=window.__forgeIP;
            window.__wslog.push('FORGED->'+window.__forgeIP);
            return S.call(this, JSON.stringify(o));
          }
        }
      }
    }catch(e){ window.__wslog.push('ERR:'+String(e).slice(0,60)); }
    return S.apply(this, arguments);
  };
  window.goliveForgeStatus=()=>({forgeIP:window.__forgeIP, log:window.__wslog});
  return 'OK:ws-forge-hooked forge='+String(window.__forgeIP);
}catch(e){return 'ERR:'+String(e);}})()
JSF
)"

JS_RX="$(cat <<'JSR'
(()=>{try{
  if(window.__goliveRx)return 'ALREADY';
  window.__goliveRx=true;
  let applied=[]; let errs=[]; let played=0; let paused=0;
  const MINW=480;
  function isStreamVideo(v){return v&&v.videoWidth>=MINW&&v.paused;}
  function playBig(){
    let n=0;
    try{
      for(const v of document.querySelectorAll('video')){
        try{
          if(!isStreamVideo(v))continue;
          v.muted=true; v.playsInline=true; v.autoplay=true;
          v.play().then(()=>{applied.push('played '+v.videoWidth+'x'+v.videoHeight); played++; n++;})
            .catch(e=>errs.push('play:'+String(e).slice(0,40)));
        }catch(e){}
      }
    }catch(e){errs.push('scan:'+String(e).slice(0,40));}
    paused=Array.from(document.querySelectorAll('video')).filter(isStreamVideo).length;
    return n;
  }
  playBig(); applied.push('initial:'+played);
  try{
    const mo=new MutationObserver(()=>{playBig();});
    mo.observe(document.body||document.documentElement,{childList:true,subtree:true});
    applied.push('observer');
  }catch(e){errs.push('observer:'+String(e).slice(0,40));}
  try{
    document.addEventListener('loadedmetadata',e=>{if(e.target&&e.target.tagName==='VIDEO'){setTimeout(()=>playBig(),100);}},true);
    window.addEventListener('resize',()=>{setTimeout(()=>playBig(),200);});
    applied.push('listeners');
  }catch(e){errs.push('listeners:'+String(e).slice(0,40));}
  const iv=setInterval(()=>{playBig();},1500);
  setTimeout(()=>clearInterval(iv),60000);
  try{window.goliveRxStatus=()=>({applied,errs,played,paused,videoEls:document.querySelectorAll('video').length});}catch(e){}
  return 'OK:golive-rx-play:'+played+(errs.length?':ERR='+errs.join(';'):'');
}catch(e){return 'ERR:'+String(e);}})()
JSR
)"

# ---------------------------------------------------------------- signatures (embedded default)

DEFAULT_SIGS_JSON="$(cat <<'SIGS'
{
  "1.0.9269": {
    "codec_table": "483236340048323635",
    "h265_disp_delta": 5,
    "lea_site_count": 4,
    "keyframe_sigs": [
      { "orig": "48b9b80b0000a0860100", "patched": "48b93c000000d0070000", "deltas": [2, 6] },
      { "orig": "b80b0000a08601000000000001000000", "patched": "3c000000d00700000000000001000000", "deltas": [0, 4] }
    ]
  }
}
SIGS
)"

# Merge embedded defaults with sibling signatures.json (sibling wins per build
# key) and print the compact entry object for $VER, or nothing if absent.
sig_entry_for() {
    local ver="$1"
    GOLIVE_DEFAULT_SIGS="$DEFAULT_SIGS_JSON" \
    GOLIVE_SIB="$SCRIPT_DIR/signatures.json" \
    GOLIVE_VER="$ver" \
    python3 -c '
import os, json, sys
sig = {}
try:
    sig.update(json.loads(os.environ.get("GOLIVE_DEFAULT_SIGS", "{}")))
except Exception:
    pass
sib = os.environ.get("GOLIVE_SIB", "")
if sib and os.path.exists(sib):
    try:
        with open(sib) as f:
            sig.update(json.load(f))
    except Exception:
        pass
entry = sig.get(os.environ.get("GOLIVE_VER", ""))
if entry is not None:
    sys.stdout.write(json.dumps(entry, separators=(",", ":")))
'
}

# ---------------------------------------------------------------- CDP client (inline python, stdlib only)

CDP_PY="$(cat <<'PY'
import os, sys, json, socket, base64, struct, time
import urllib.request

OP = os.environ.get('GOLIVE_OP', '')
PORT = int(os.environ.get('GOLIVE_PORT', '9222'))


def get_target():
    timeout = float(os.environ.get('GOLIVE_TIMEOUT', '45'))
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen('http://127.0.0.1:%d/json/list' % PORT, timeout=3) as r:
                lst = json.loads(r.read().decode('utf-8', 'replace'))
            for it in lst:
                if it.get('type') == 'page' and 'discord.com' in (it.get('url') or ''):
                    return it
        except Exception:
            pass
        time.sleep(0.8)
    return None


class WS:
    def __init__(self, wsurl):
        if not wsurl.startswith('ws://'):
            raise ValueError('bad ws url')
        rest = wsurl[5:]
        slash = rest.find('/')
        hostport = rest[:slash] if slash >= 0 else rest
        path = rest[slash:] if slash >= 0 else '/'
        if ':' in hostport:
            host, port = hostport.split(':', 1)
            port = int(port)
        else:
            host, port = hostport, 80
        self.sock = socket.create_connection((host, port), timeout=15)
        self.sock.settimeout(20)
        key = base64.b64encode(os.urandom(16)).decode()
        req = ('GET ' + path + ' HTTP/1.1\r\n'
               'Host: ' + host + ':' + str(port) + '\r\n'
               'Upgrade: websocket\r\n'
               'Connection: Upgrade\r\n'
               'Sec-WebSocket-Key: ' + key + '\r\n'
               'Sec-WebSocket-Version: 13\r\n\r\n')
        self.sock.sendall(req.encode())
        buf = b''
        while b'\r\n\r\n' not in buf:
            ch = self.sock.recv(4096)
            if not ch:
                raise IOError('handshake closed')
            buf += ch
        head, _, rest2 = buf.partition(b'\r\n\r\n')
        if b'101' not in head.split(b'\r\n', 1)[0]:
            raise IOError('handshake failed: ' + head.split(b'\r\n', 1)[0].decode('latin1'))
        self._rbuf = rest2

    def send_text(self, s):
        data = s.encode('utf-8')
        n = len(data)
        mask = os.urandom(4)
        hdr = bytearray([0x81])
        if n < 126:
            hdr.append(0x80 | n)
        elif n < 65536:
            hdr.append(0x80 | 126); hdr += struct.pack('>H', n)
        else:
            hdr.append(0x80 | 127); hdr += struct.pack('>Q', n)
        hdr += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(bytes(hdr) + masked)

    def _exact(self, n):
        while len(self._rbuf) < n:
            ch = self.sock.recv(65536)
            if not ch:
                raise IOError('ws closed')
            self._rbuf += ch
        out = self._rbuf[:n]
        self._rbuf = self._rbuf[n:]
        return out

    def recv_msg(self):
        payload = b''
        while True:
            b0, b1 = self._exact(2)
            fin = b0 & 0x80
            op = b0 & 0x0f
            masked = b1 & 0x80
            ln = b1 & 0x7f
            if ln == 126:
                ln = struct.unpack('>H', self._exact(2))[0]
            elif ln == 127:
                ln = struct.unpack('>Q', self._exact(8))[0]
            mk = self._exact(4) if masked else None
            data = self._exact(ln)
            if mk:
                data = bytes(b ^ mk[i % 4] for i, b in enumerate(data))
            if op == 0x8:
                raise IOError('closed by server')
            if op in (0x0, 0x1, 0x2):
                payload += data
                if fin:
                    return payload.decode('utf-8', 'replace')

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


def rpc(ws, cid, method, params, wait=15):
    ws.send_text(json.dumps({'id': cid, 'method': method, 'params': params}))
    deadline = time.time() + wait
    while time.time() < deadline:
        try:
            msg = ws.recv_msg()
        except socket.timeout:
            break
        try:
            m = json.loads(msg)
        except Exception:
            continue
        if m.get('id') == cid:
            if m.get('error'):
                raise IOError(method + ': ' + json.dumps(m['error']))
            return m
    raise IOError('timeout ' + method)


if OP == 'target':
    t = get_target()
    if t:
        sys.stdout.write((t.get('webSocketDebuggerUrl') or '') + '\t' + (t.get('url') or ''))
    sys.exit(0)

if OP == 'inject':
    ws = WS(os.environ['GOLIVE_WSURL'])
    try:
        rep = []
        rpc(ws, 1, 'Page.enable', {}); rep.append('Page.enable:ok')
        rpc(ws, 2, 'Page.addScriptToEvaluateOnNewDocument', {'source': os.environ['GOLIVE_SHIM']}); rep.append('addScript:ok')
        rpc(ws, 3, 'Page.navigate', {'url': os.environ['GOLIVE_PAGEURL']}); rep.append('navigate:ok')
        sys.stdout.write(' | '.join(rep))
    finally:
        ws.close()
    sys.exit(0)

if OP == 'confirm':
    ws = WS(os.environ['GOLIVE_WSURL'])
    try:
        m = rpc(ws, 1, 'Runtime.evaluate',
                {'expression': os.environ['GOLIVE_EXPR'], 'returnByValue': True, 'awaitPromise': True},
                wait=20)
        val = ((m.get('result') or {}).get('result') or {}).get('value')
        sys.stdout.write('' if val is None else str(val))
    finally:
        ws.close()
    sys.exit(0)
PY
)"

cdp() {
    # cdp <op>  (reads GOLIVE_* from the calling env); echoes python stdout
    GOLIVE_OP="$1" python3 -c "$CDP_PY"
}

# ---------------------------------------------------------------- discord discovery

DISCORD_LAUNCH=()
DISCORD_PROCPAT=''
NODE_PATH=''
VER=''

_try_flavor() {
    # $1 cmd  $2 configname  $3 flatpakid  $4 snapname  $5 procpat  $6 extrabins(colon-list)
    local cmd="$1" cfgname="$2" fpid="$3" snapname="$4" procpat="$5" extrabins="$6"
    local launch=() cfgdir=''

    if command -v "$cmd" >/dev/null 2>&1; then
        launch=("$cmd"); cfgdir="$HOME/.config/$cfgname"
    else
        local b found_bin='' oldifs="$IFS"
        IFS=:
        for b in $extrabins; do
            if [ -n "$b" ] && [ -x "$b" ]; then found_bin="$b"; break; fi
        done
        IFS="$oldifs"
        if [ -n "$found_bin" ]; then
            launch=("$found_bin"); cfgdir="$HOME/.config/$cfgname"
        elif command -v flatpak >/dev/null 2>&1 && flatpak info "$fpid" >/dev/null 2>&1; then
            launch=(flatpak run "$fpid"); cfgdir="$HOME/.var/app/$fpid/config/$cfgname"
        elif [ -d "$HOME/snap/$snapname" ]; then
            launch=(snap run "$snapname"); cfgdir="$HOME/snap/$snapname/current/.config/$cfgname"
        else
            return 1
        fi
    fi

    DISCORD_LAUNCH=("${launch[@]}")
    DISCORD_PROCPAT="$procpat"
    NODE_PATH=''; VER=''

    if [ -n "$cfgdir" ] && [ -d "$cfgdir" ]; then
        local best='' bestt=0 line t f
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            t="${line%% *}"; f="${line#* }"
            t="${t%.*}"
            if [ -n "$t" ] && [ "$t" -gt "$bestt" ] 2>/dev/null; then bestt="$t"; best="$f"; fi
        done < <(find "$cfgdir" -maxdepth 6 -type f \
                    -path '*/modules/discord_voice-1/discord_voice/discord_voice.node' \
                    -printf '%T@ %p\n' 2>/dev/null)
        if [ -n "$best" ]; then
            NODE_PATH="$best"
            local rel="${best#"$cfgdir"/}"
            VER="${rel%%/*}"
        fi
    fi
    return 0
}

discover_discord() {
    DISCORD_LAUNCH=(); DISCORD_PROCPAT=''; NODE_PATH=''; VER=''
    _try_flavor "discord" "discord" "com.discordapp.Discord" "discord" "Discord" \
        "/usr/bin/discord:/opt/Discord/Discord:/opt/discord/Discord:/usr/share/discord/Discord:$HOME/.local/share/Discord/Discord" \
        && return 0
    _try_flavor "discord-ptb" "discordptb" "com.discordapp.DiscordPTB" "discord-ptb" "DiscordPTB" \
        "/usr/bin/discord-ptb:/opt/DiscordPTB/DiscordPTB:/usr/share/discord-ptb/DiscordPTB:$HOME/.local/share/DiscordPTB/DiscordPTB" \
        && return 0
    _try_flavor "discord-canary" "discordcanary" "com.discordapp.DiscordCanary" "discord-canary" "DiscordCanary" \
        "/usr/bin/discord-canary:/opt/DiscordCanary/DiscordCanary:/usr/share/discord-canary/DiscordCanary:$HOME/.local/share/DiscordCanary/DiscordCanary" \
        && return 0
    return 1
}

# ---------------------------------------------------------------- process management

is_running() { pgrep -f "$DISCORD_PROCPAT" >/dev/null 2>&1; }

stop_discord() {
    pkill -TERM -f "$DISCORD_PROCPAT" 2>/dev/null || true
    sleep 3
    pkill -KILL -f "$DISCORD_PROCPAT" 2>/dev/null || true
    sleep 1
}

start_discord_with_debug() {
    log INFO "Starting Discord with --remote-debugging-port=$DEBUGPORT ..."
    nohup "${DISCORD_LAUNCH[@]}" --remote-debugging-port="$DEBUGPORT" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    sleep 8
}

port_open() {
    GOLIVE_PORT="$DEBUGPORT" python3 - <<'PY' 2>/dev/null
import os, socket, sys
s = socket.socket()
s.settimeout(1)
try:
    s.connect(('127.0.0.1', int(os.environ['GOLIVE_PORT'])))
    s.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
}

# ---------------------------------------------------------------- encoder patch (via golive_patch.py)

run_patch() {
    # run_patch <patch|probe|revert> [sigs-json]
    local mode="$1" sigs="${2:-}"
    if [ -n "$sigs" ]; then
        python3 "$PATCHER" --node "$NODE_PATH" --mode "$mode" --sigs-json "$sigs"
    else
        python3 "$PATCHER" --node "$NODE_PATH" --mode "$mode"
    fi
}

is_patched_state() { printf '%s' "$1" | grep -Eq '"state"[[:space:]]*:[[:space:]]*"patched"'; }

# ---------------------------------------------------------------- main

log INFO "GoLive-Bostil (Linux) mode=$MODE forgeIp=$FORGE_IP port=$DEBUGPORT"

if ! discover_discord; then
    log ERRO 'Discord desktop not found (native / flatpak / snap). Install Discord first.'
    exit 1
fi
log INFO "Discord launch: ${DISCORD_LAUNCH[*]}"
log INFO "node: ${NODE_PATH:-<none>}   build: ${VER:-<unknown>}"

SIG_ENTRY=''
if [ -n "$VER" ]; then
    SIG_ENTRY="$(sig_entry_for "$VER" || true)"
fi

# ---- Revert: stop discord, restore stock node, drop patch state, exit.
if [ "$MODE" = 'Revert' ]; then
    if [ -z "$NODE_PATH" ]; then
        log ERRO 'discord_voice.node not found; nothing to revert.'
        pause_exit; exit 1
    fi
    if is_running; then log INFO 'Stopping Discord before revert...'; stop_discord; fi
    if [ -f "$PATCHER" ]; then
        res="$(run_patch revert 2>&1 || true)"
        log OK "Revert: $res"
    else
        log ERRO "golive_patch.py not found next to script ($PATCHER); cannot revert."
    fi
    log OK 'Revert done. Start Discord normally.'
    pause_exit; exit 0
fi

# ---- Probe: read-only health check (run after each Discord update).
if [ "$MODE" = 'Probe' ]; then
    log INFO "Probe: Discord build=${VER:-<unknown>}"
    log INFO "node: ${NODE_PATH:-<none>}"
    if [ -n "$SIG_ENTRY" ]; then log INFO "signature entry for ${VER:-<unknown>}: true"
    else log INFO "signature entry for ${VER:-<unknown>}: false"; fi
    if port_open; then log INFO "debug port $DEBUGPORT reachable: true"
    else log INFO "debug port $DEBUGPORT reachable: false"; fi
    if [ -n "$NODE_PATH" ] && [ -f "$NODE_PATH" ] && [ -n "$SIG_ENTRY" ] && [ -f "$PATCHER" ]; then
        rep="$(run_patch probe "$SIG_ENTRY" 2>&1 || true)"
        log INFO "locate: $rep"
    elif [ -z "$SIG_ENTRY" ]; then
        log WARN "No encoder signature for build ${VER:-<unknown>}. Add one to signatures.json (re-derive on a new build)."
    elif [ ! -f "$PATCHER" ]; then
        log WARN "golive_patch.py not found next to script; cannot probe encoder patch."
    else
        log WARN 'discord_voice.node not found.'
    fi
    pause_exit; exit 0
fi

# ---- Forge / Watch (identical today).

if [ -z "$SIG_ENTRY" ]; then
    log WARN "No encoder signatures for build ${VER:-<unknown>}. Encoder patch skipped; stream VIDEO may fail. Run --mode Probe, then add a signatures.json entry."
fi

# Encoder patch. Discord must be STOPPED: a running Discord has the old module
# loaded (patch wouldn't take effect until restart). Skip if already patched.
if [ -n "$SIG_ENTRY" ] && [ -n "$NODE_PATH" ] && [ -f "$NODE_PATH" ] && [ -f "$PATCHER" ]; then
    pr="$(run_patch probe "$SIG_ENTRY" 2>/dev/null || true)"
    if is_patched_state "$pr"; then
        log INFO 'Encoder already patched (state match). Skipping.'
    else
        if is_running; then log INFO 'Stopping Discord to patch + reload encoder...'; stop_discord; fi
        res="$(run_patch patch "$SIG_ENTRY" 2>&1 || true)"
        log INFO "Encoder patch: $res"
        pr2="$(run_patch probe "$SIG_ENTRY" 2>/dev/null || true)"
        if ! is_patched_state "$pr2"; then
            log ERRO 'Encoder patch did NOT fully apply (build mismatch or locked file). Stream VIDEO may fail. Run --mode Probe.'
        fi
    fi
elif [ -z "$NODE_PATH" ] || [ ! -f "${NODE_PATH:-/nonexistent}" ]; then
    log WARN 'discord_voice.node not found: encoder patch skipped.'
elif [ ! -f "$PATCHER" ]; then
    log WARN "golive_patch.py not found next to script; encoder patch skipped."
fi

# Ensure Discord is running WITH the debug port (loads the patched module).
if ! port_open; then
    if is_running; then
        log INFO 'Discord running without debug port. Restarting...'
        stop_discord
    fi
    start_discord_with_debug
    log INFO 'Discord started with debug port.'
fi

# Wait for the Discord page target.
log INFO "Waiting for Discord DevTools target on port $DEBUGPORT (up to ${TIMEOUT}s)..."
TINFO="$(GOLIVE_PORT="$DEBUGPORT" GOLIVE_TIMEOUT="$TIMEOUT" cdp target 2>/dev/null || true)"
WSURL="${TINFO%%$'\t'*}"
PAGEURL="${TINFO#*$'\t'}"
if [ -z "$WSURL" ]; then
    log ERRO "Discord did not expose port $DEBUGPORT in ${TIMEOUT}s."
    pause_exit; exit 1
fi
log INFO "Target: $PAGEURL"

# Build shim = forge(with ip) + "\n;" + rx, then inject and navigate.
FORGE_WITH_IP="${JS_FORGE//__FORGE_IP__/$FORGE_IP}"
SHIM="$FORGE_WITH_IP"$'\n;'"$JS_RX"

REPS="$(GOLIVE_PORT="$DEBUGPORT" GOLIVE_WSURL="$WSURL" GOLIVE_SHIM="$SHIM" GOLIVE_PAGEURL="$PAGEURL" cdp inject 2>&1 || true)"
log INFO "CDP: $REPS"

# Confirm the forge shim is live (poll up to 30s).
CONFIRM_EXPR='(()=>{try{return JSON.stringify({forge:window.goliveForgeStatus?window.goliveForgeStatus():null});}catch(e){return JSON.stringify({err:String(e)});}})()'
ST=''
DEADLINE=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    sleep 1.5
    ST="$(GOLIVE_PORT="$DEBUGPORT" GOLIVE_WSURL="$WSURL" GOLIVE_EXPR="$CONFIRM_EXPR" cdp confirm 2>/dev/null || true)"
    case "$ST" in *'"forge"'*) break ;; esac
done
case "$ST" in
    *'"forge"'*) ;;
    *) log ERRO 'Forge not confirmed. Shim did not run.'; pause_exit; exit 1 ;;
esac

log OK "Forge ready (IP $FORGE_IP): $ST"
log OK 'Done. Join the voice channel manually, then stream (Go Live) or watch as needed.'
pause_exit
exit 0

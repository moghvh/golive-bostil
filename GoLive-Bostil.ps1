<#
.SYNOPSIS
    Go Live forge: monkeypatches Discord's voice gateway op1 d.data.address to a
    non-BR IP so the SFU geo-gate clears. Also patches encoder to H264, joins
    voice, and starts Go Live / watches stream. One command, both roles.
    No external dependencies — everything is inline.

.DESCRIPTION
    The Go Live region gate reads the client-signaled op1 d.data.address from the
    Voice Gateway WebSocket. Rewriting that field to a non-Brazil IP defeats the
    block without breaking delivery (media routes over the observed UDP 5-tuple).

    Both sides need the forge: publisher-only and viewer-only both leave the gate
    shut. One command, both roles. Session-scoped: re-apply after Discord restart.

.PARAMETER Mode
    Forge   - install forge, patch encoder, join voice, start Go Live (default)
    Watch   - install forge, patch encoder, join voice, watch stream (viewer)

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\GoLive-Bostil.ps1 -Mode Forge
#>

[CmdletBinding()]
param(
    [ValidateSet('Forge', 'Watch', 'Revert', 'Probe')]
    [string]$Mode = 'Forge',

    [int]$DebugPort = 9222,
    [int]$TimeoutSec = 45,
    [string]$ForgeIp = '149.22.81.205', #ip forjado, pode ser qualquer ip não brasileiro.
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

if ($Mode -ne 'Revert' -and $ForgeIp -notmatch '^((25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(25[0-5]|2[0-4]\d|1?\d?\d)$') {
    throw "ForgeIp invalid: '$ForgeIp'. Use a non-Brazil IPv4 (e.g. 149.22.81.205)."
}

$Root = Join-Path $env:LOCALAPPDATA 'GoLiveBostil'
$LogFile = Join-Path $Root 'install.log'
New-Item -ItemType Directory -Path $Root -Force | Out-Null

# ---------------------------------------------------------------- helpers

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    switch ($Level) {
        'OK'   { Write-Host $line -ForegroundColor Green }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'ERRO' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
}

function Get-DiscordInstall {
    foreach ($c in @(
        @{ Name = 'Discord';       Dir = (Join-Path $env:LOCALAPPDATA 'Discord') },
        @{ Name = 'DiscordPTB';    Dir = (Join-Path $env:LOCALAPPDATA 'DiscordPTB') },
        @{ Name = 'DiscordCanary'; Dir = (Join-Path $env:LOCALAPPDATA 'DiscordCanary') }
    )) {
        $exe = Join-Path $c.Dir 'Discord.exe'
        if (Test-Path $exe) { return [pscustomobject]@{ Process = $c.Name; Exe = $exe } }
    }
    return $null
}

function Get-DiscordProcessList {
    param([string]$ProcessName)
    return @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
}

function Test-PortOpen {
    param([int]$Port = 9222)
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(1000)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch { return $false }
    finally { if ($client) { try { $client.Close() } catch { } } }
}

function Get-DiscordPageTarget {
    param([int]$Port = 9222, [int]$TimeoutSec = 45)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $list = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 3
            $page = $list | Where-Object { $_.type -eq 'page' -and $_.url -like '*discord.com*' } | Select-Object -First 1
            if ($page) { return $page }
        } catch { }
        Start-Sleep -Milliseconds 800
    }
    return $null
}

function Stop-Discord {
    param([string]$ProcessName)
    $procs = Get-DiscordProcessList -ProcessName $ProcessName
    if (-not $procs) { return }
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

function Start-Discord {
    param([string]$Exe, [switch]$WithDebugPort, [int]$Port = 9222)
    if ($WithDebugPort) {
        Start-Process -FilePath $Exe -ArgumentList "--remote-debugging-port=$Port"
    } else {
        Start-Process -FilePath $Exe
    }
    Start-Sleep -Seconds 8
}

function Test-NodePatched {
    param([string]$NodePath)
    $sp = "$NodePath.patch-state.json"
    if (-not (Test-Path $sp)) { return $false }
    try { $st = Get-Content -Path $sp -Raw | ConvertFrom-Json } catch { return $false }
    if (-not $st.patched_sha256) { return $false }
    $cur = (Get-FileHash -Path $NodePath -Algorithm SHA256).Hash.ToLower()
    return ($st.patched_sha256 -eq $cur)
}

function Invoke-Revert {
    param([string]$NodePath)
    $bak = "$NodePath.stockbak"
    $sp  = "$NodePath.patch-state.json"
    if (Test-Path $bak) {
        Copy-Item -Path $bak -Destination $NodePath -Force
        Remove-Item -Path $sp -ErrorAction SilentlyContinue
        Write-Log 'OK' 'Restored stock discord_voice.node from .stockbak backup.'
        return
    }
    # No full backup: reconstruct stock bytes from the per-site originals in the state file.
    if (Test-Path $sp) {
        try {
            $st = Get-Content -Path $sp -Raw | ConvertFrom-Json
            $bytes = [System.IO.File]::ReadAllBytes($NodePath)
            $n = 0
            foreach ($s in $st.sites) {
                $off = [int]$s.offset
                $hex = [string]$s.original
                for ($i = 0; $i -lt $hex.Length; $i += 2) {
                    $bytes[$off + ($i / 2)] = [Convert]::ToByte($hex.Substring($i, 2), 16)
                }
                $n++
            }
            [System.IO.File]::WriteAllBytes($NodePath, $bytes)
            Remove-Item -Path $sp -ErrorAction SilentlyContinue
            Write-Log 'OK' "Reverted $n patch sites from state file (no backup needed)."
            return
        } catch {
            Write-Log 'ERRO' "State-based revert failed: $($_.Exception.Message)"
            return
        }
    }
    Write-Log 'WARN' 'No .stockbak and no patch-state.json. Nothing to revert (or already stock); reinstall Discord if unsure.'
}

function Invoke-CdpEvaluate {
    param([string]$WebSocketUrl, [string]$Expression, [int]$TimeoutSec = 20)
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ct = [System.Threading.CancellationToken]::None
    try {
        if (-not $ws.ConnectAsync([Uri]$WebSocketUrl, $ct).Wait(15000)) { throw 'timeout connecting to Discord DevTools' }
        $payload = @{ id = 1; method = 'Runtime.evaluate'; params = @{ expression = $Expression; returnByValue = $true; awaitPromise = $true } } | ConvertTo-Json -Compress -Depth 5
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        if (-not $ws.SendAsync([System.ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait(10000)) { throw 'timeout sending to Discord' }
        $buf = New-Object byte[] 131072
        $sb = [System.Text.StringBuilder]::new()
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            $res = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buf), $ct).Result
            [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count))
            if ($res.EndOfMessage) { break }
        }
        $reply = $sb.ToString() | ConvertFrom-Json
        if ($reply.error) { throw "CDP: $($reply.error.message)" }
        return [string]$reply.result.result.value
    } finally { try { $ws.Dispose() } catch { } }
}

function Send-CdpShimAndNavigate {
    param([string]$WebSocketUrl, [string]$Source, [string]$Url, [int]$TimeoutSec = 15)
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ct = [System.Threading.CancellationToken]::None
    $replies = @()
    try {
        if (-not $ws.ConnectAsync([Uri]$WebSocketUrl, $ct).Wait(10000)) { throw 'timeout connecting to CDP' }
        $cmds = @(
            @{ method = 'Page.enable'; params = @{} }
            @{ method = 'Page.addScriptToEvaluateOnNewDocument'; params = @{ source = $Source } }
            @{ method = 'Page.navigate'; params = @{ url = $Url } }
        )
        $buf = New-Object byte[] 131072
        $id = 0
        foreach ($cmd in $cmds) {
            $id++
            $payload = @{ id = $id; method = $cmd.method; params = $cmd.params } | ConvertTo-Json -Compress -Depth 6
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
            if (-not $ws.SendAsync([System.ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait(5000)) { throw "timeout sending $($cmd.method)" }
            $deadline = (Get-Date).AddSeconds($TimeoutSec)
            while ((Get-Date) -lt $deadline) {
                $res = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buf), $ct).Result
                if ($res.Count -le 0) { continue }
                $txt = [System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count)
                try { $msg = $txt | ConvertFrom-Json } catch { continue }
                if ($msg.id -eq $id) {
                    if ($msg.error) { throw "CDP $($cmd.method): $($msg.error.message)" }
                    $replies += "$($cmd.method):ok"
                    break
                }
            }
        }
        return $replies
    } finally { try { $ws.Dispose() } catch { } }
}

# ---------------------------------------------------------------- shims

$JsForgeShim = @'
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
'@

$JsRxShim = @'
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
'@

# ---------------------------------------------------------------- encoder signatures

# Patch signatures keyed by Discord build. Embedded defaults below; a sibling
# signatures.json (same folder as this script) overrides / extends them, so a new
# Discord build is a data edit, not a code change. Re-derive via -Mode Probe.
$DefaultSignaturesJson = @'
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
'@

function Get-Signatures {
    $sig = @{}
    try {
        ($DefaultSignaturesJson | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $sig[$_.Name] = $_.Value }
    } catch { Write-Log 'WARN' 'Embedded signatures unparseable.' }
    $ext = Join-Path $PSScriptRoot 'signatures.json'
    if (Test-Path $ext) {
        try {
            (Get-Content -Path $ext -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $sig[$_.Name] = $_.Value }
            Write-Log 'INFO' 'Loaded signatures.json (overrides embedded defaults).'
        } catch { Write-Log 'WARN' 'signatures.json present but unreadable; using embedded defaults.' }
    }
    return $sig
}

# ---------------------------------------------------------------- encoder patch (inline)

function Invoke-EncoderPatch {
    param([string]$NodePath, [string]$SigsJson, [switch]$ProbeOnly)

    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python -or $python.Source -like '*WindowsApps*') {
        Write-Log 'INFO' 'Python not found or is the Microsoft Store alias. Installing Python 3...'
        $installer = Join-Path $env:TEMP 'python-installer.exe'
        Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/3.12.3/python-3.12.3-amd64.exe' -OutFile $installer -UseBasicParsing
        $sigChk = Get-AuthenticodeSignature -FilePath $installer
        $subject = [string]$sigChk.SignerCertificate.Subject
        if ($sigChk.Status -ne 'Valid' -or $subject -notmatch 'Python Software Foundation') {
            Remove-Item $installer -ErrorAction SilentlyContinue
            Write-Log 'ERRO' "Python installer signature not trusted (status=$($sigChk.Status)). Aborting install."
            return 'error=untrusted_installer'
        }
        Write-Log 'INFO' 'Installer signature OK (Python Software Foundation). Installing Python 3.12.3 (silent, per-user)...'
        Start-Process -FilePath $installer -ArgumentList '/quiet', 'InstallAllUsers=0', 'PrependPath=1', 'Include_pip=0', 'Include_tcltk=0', 'Include_test=0', 'Include_dev=0', 'Include_launcher=0' -Wait
        Remove-Item $installer -ErrorAction SilentlyContinue
        # Refresh PATH in this session
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
        $python = Get-Command python -ErrorAction SilentlyContinue
        if (-not $python) {
            Write-Log 'ERRO' 'Python install failed. Encoder patch skipped.'
            return
        }
        Write-Log 'OK' 'Python installed successfully.'
    }

    $pyCode = @"
import struct, hashlib, json, sys
from pathlib import Path

_SIG = json.loads(r'''__SIGS_JSON__''')
MODE = '__MODE__'
CODEC_TABLE = bytes.fromhex(_SIG['codec_table'])
H265_DISP_DELTA = _SIG['h265_disp_delta']
LEA_COUNT = _SIG.get('lea_site_count', 4)
KEYFRAME_SIGS = [(bytes.fromhex(k['orig']), bytes.fromhex(k['patched']), tuple(k['deltas'])) for k in _SIG['keyframe_sigs']]

def pe_sections(data):
    if data[:2] != b'MZ': raise ValueError('not a PE file')
    e = struct.unpack_from('<I', data, 0x3C)[0]
    if data[e:e+4] != b'PE\0\0': raise ValueError('not a PE file')
    nsec = struct.unpack_from('<H', data, e+6)[0]
    opt_size = struct.unpack_from('<H', data, e+20)[0]
    opt = e + 24
    magic = struct.unpack_from('<H', data, opt)[0]
    base = struct.unpack_from('<Q', data, opt+24)[0] if magic == 0x20B else struct.unpack_from('<I', data, opt+28)[0]
    out = []
    sec = opt + opt_size
    for i in range(nsec):
        off = sec + i * 40
        vs, va, rs, rp = struct.unpack_from('<IIII', data, off+8)
        out.append((base+va, vs, rp, rs))
    return out

def va_of(secs, off):
    for va, vs, rp, rs in secs:
        if rp <= off < rp + max(vs, rs): return va + (off - rp)
    raise ValueError(f'offset 0x{off:X} outside PE sections')

def locate(data):
    report = {'codec_table': False, 'lea_found': 0, 'lea_expected': LEA_COUNT, 'keyframe': []}
    try:
        secs = pe_sections(data)
    except ValueError as e:
        report['error'] = str(e); return None, report
    sites = []
    at = data.find(CODEC_TABLE)
    if at < 0: return None, report
    report['codec_table'] = True
    h265_va = va_of(secs, at) + H265_DISP_DELTA
    found = 0
    pos = data.find(b'\x48\x8D')
    while pos >= 0:
        i = pos
        pos = data.find(b'\x48\x8D', i+1)
        if i+7 > len(data): break
        if data[i+2] & 0xC7 != 0x05: continue
        disp = struct.unpack_from('<i', data, i+3)[0]
        if va_of(secs, i+7) + disp != h265_va: continue
        sites.append((i+3, data[i+3:i+7], struct.pack('<i', disp - H265_DISP_DELTA)))
        found += 1
    report['lea_found'] = found
    for orig, patched, deltas in KEYFRAME_SIGS:
        p = data.find(orig)
        report['keyframe'].append({'sig': orig.hex(), 'found': p >= 0})
        if p < 0: continue
        for d in deltas: sites.append((p+d, orig[d:d+4], patched[d:d+4]))
    ok = (report['codec_table'] and found == LEA_COUNT
          and all(k['found'] for k in report['keyframe']))
    return (sites if ok else None), report

node = Path(r'__NODE_PATH__')
state_path = Path(str(node) + '.patch-state.json')
data = bytearray(node.read_bytes())

state_match = False
try:
    state = json.loads(state_path.read_text())
    state_match = (state.get('patched_sha256') == hashlib.sha256(bytes(data)).hexdigest())
except: pass

sites, report = locate(bytes(data))

if MODE == 'probe':
    st = 'patched' if state_match else ('present_mismatch' if state_path.exists() else 'stock')
    print('PROBE ' + json.dumps({'state': st, 'locatable': sites is not None, **report}))
    sys.exit(0)

if state_match:
    print('PATCH_STATUS already_applied')
    sys.exit(0)
if sites is None:
    print('PATCH_STATUS error=locate_failed ' + json.dumps(report))
    sys.exit(0)

bak = Path(str(node) + '.stockbak')
if not bak.exists():
    bak.write_bytes(bytes(data))

applied = 0
for off, orig, patched in sites:
    cur = bytes(data[off:off+4])
    if cur == patched:
        applied += 1
    elif cur == orig:
        data[off:off+4] = patched
        applied += 1

if applied == len(sites):
    node.write_bytes(bytes(data))
    state_path.write_text(json.dumps({'patched_sha256': hashlib.sha256(bytes(data)).hexdigest(), 'sites': [{'offset': o, 'original': orig.hex(), 'patched': p.hex()} for o, orig, p in sites]}))
    print(f'PATCH_STATUS applied={applied} total={len(sites)}')
else:
    print(f'PATCH_STATUS applied={applied} total={len(sites)} partial')
"@

    $mode = if ($ProbeOnly) { 'probe' } else { 'patch' }
    $pyCode = $pyCode.Replace('__NODE_PATH__', $NodePath.Replace('\', '\\')).Replace('__SIGS_JSON__', $SigsJson).Replace('__MODE__', $mode)
    $tmpFile = Join-Path $env:TEMP 'golive_patch.py'
    $pyCode | Out-File -FilePath $tmpFile -Encoding UTF8
    $result = & python $tmpFile 2>&1
    Remove-Item $tmpFile -ErrorAction SilentlyContinue
    return ($result -join ' ')
}

# ---------------------------------------------------------------- main

$install = Get-DiscordInstall
if (-not $install) { throw 'Discord desktop not found in %LOCALAPPDATA%.' }

# Resolve discord_voice.node
$dir = Split-Path $install.Exe -Parent
$nodePath = $null
foreach ($c in @(
    (Join-Path $dir 'modules\discord_voice-1\discord_voice\discord_voice.node')
    (Join-Path $dir 'app-*\modules\discord_voice-1\discord_voice\discord_voice.node')
)) {
    $hit = @(Get-ChildItem -Path $c -ErrorAction SilentlyContinue)
    if ($hit) { $nodePath = ($hit | Sort-Object LastWriteTime -Descending)[0].FullName; break }
}

# Resolve encoder signatures for the installed build (embedded defaults + optional signatures.json).
$sigs = Get-Signatures
$ver = if ($nodePath -and $nodePath -match 'app-([0-9][0-9.]*)') { $Matches[1] } else { $null }
$sigEntry = if ($ver -and $sigs.ContainsKey($ver)) { $sigs[$ver] } else { $null }

# Revert mode: stop Discord, restore stock node, drop patch state, exit.
if ($Mode -eq 'Revert') {
    if (-not $nodePath) { throw 'discord_voice.node not found; nothing to revert.' }
    Stop-Discord -ProcessName $install.Process
    Invoke-Revert -NodePath $nodePath
    Write-Log 'OK' 'Revert done. Start Discord normally.'
    if (-not $NoPause -and -not $env:GOLIVE_NOPAUSE) { Read-Host 'Enter to exit' | Out-Null }
    exit 0
}

# Probe mode: read-only health check (run after each Discord update).
if ($Mode -eq 'Probe') {
    Write-Log 'INFO' "Probe: Discord build=$ver"
    Write-Log 'INFO' "node: $nodePath"
    Write-Log 'INFO' "signatures entry for ${ver}: $([bool]$sigEntry)"
    Write-Log 'INFO' "debug port ${DebugPort} reachable: $(Test-PortOpen -Port $DebugPort)"
    if ($nodePath -and (Test-Path $nodePath) -and $sigEntry) {
        $rep = Invoke-EncoderPatch -NodePath $nodePath -SigsJson ($sigEntry | ConvertTo-Json -Depth 6 -Compress) -ProbeOnly
        Write-Log 'INFO' "locate: $rep"
    } elseif (-not $sigEntry) {
        Write-Log 'WARN' "No encoder signature for build $ver. Add one to signatures.json (or the embedded default)."
    } else {
        Write-Log 'WARN' 'discord_voice.node not found.'
    }
    if (-not $NoPause -and -not $env:GOLIVE_NOPAUSE) { Read-Host 'Enter to exit' | Out-Null }
    exit 0
}

# No signatures for this build: the patch cannot be located safely.
if (-not $sigEntry) {
    Write-Log 'WARN' "No encoder signatures for build $ver (embedded or signatures.json). Encoder patch skipped; stream VIDEO may fail. Run -Mode Probe, then add a signatures.json entry."
}

# Encoder patch. Must run while Discord is STOPPED: the .node is otherwise file-locked,
# and a running Discord has already loaded the old module (patch wouldn't take effect
# until a restart). Skip entirely if already patched (sha matches state).
if ($nodePath -and (Test-Path $nodePath) -and $sigEntry) {
    if (Test-NodePatched -NodePath $nodePath) {
        Write-Log 'INFO' 'Encoder already patched (sha match). Skipping.'
    } else {
        $running = Get-DiscordProcessList -ProcessName $install.Process
        if ($running) { Write-Log 'INFO' 'Stopping Discord to patch + reload encoder...'; Stop-Discord -ProcessName $install.Process }
        $rep = Invoke-EncoderPatch -NodePath $nodePath -SigsJson ($sigEntry | ConvertTo-Json -Depth 6 -Compress)
        Write-Log 'INFO' "Encoder patch: $rep"
        if (-not (Test-NodePatched -NodePath $nodePath)) {
            Write-Log 'ERRO' 'Encoder patch did NOT fully apply (build mismatch or locked file). Stream VIDEO may fail. Run -Mode Probe.'
        }
    }
} elseif (-not $nodePath -or -not (Test-Path $nodePath)) {
    Write-Log 'WARN' 'discord_voice.node not found: encoder patch skipped.'
}

# Ensure Discord is running WITH the debug port. If we just patched, Discord is stopped
# here, so this start loads the patched module.
if (-not (Test-PortOpen -Port $DebugPort)) {
    $procs = Get-DiscordProcessList -ProcessName $install.Process
    if ($procs) {
        Write-Log 'INFO' 'Discord running without debug port. Restarting...'
        Stop-Discord -ProcessName $install.Process
    }
    Start-Discord -Exe $install.Exe -WithDebugPort -Port $DebugPort
    Write-Log 'INFO' 'Discord started with debug port.'
}

# Wait for Discord to be ready
$target = Get-DiscordPageTarget -Port $DebugPort -TimeoutSec 30
if (-not $target) { throw "Discord did not expose port $DebugPort in 30s." }

Write-Log 'INFO' "Target: $($target.url)"

# Inject forge + play shim
$shim = $JsForgeShim.Replace('__FORGE_IP__', $ForgeIp) + "`n;" + $JsRxShim
$replies = Send-CdpShimAndNavigate -WebSocketUrl $target.webSocketDebuggerUrl -Source $shim -Url $target.url
Write-Log 'INFO' "CDP: $($replies -join ' | ')"

# Wait for forge to be ready
$js = "(()=>{try{return JSON.stringify({forge:window.goliveForgeStatus?window.goliveForgeStatus():null});}catch(e){return JSON.stringify({err:String(e)});}})()"
$st = ''
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 1500
    try { $st = Invoke-CdpEvaluate -WebSocketUrl $target.webSocketDebuggerUrl -Expression $js -TimeoutSec 10 } catch { $st = '' }
    if ($st -match '"forge"') { break }
}
if ($st -notmatch '"forge"') { throw 'Forge not confirmed. Shim did not run.' }

Write-Log 'OK' "Forge ready (IP $ForgeIp): $st"
Write-Log 'OK' 'Done. Join voice channel manually, then stream or watch as needed.'

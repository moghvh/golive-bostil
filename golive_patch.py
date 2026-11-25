#!/usr/bin/env python3
"""
GoLive-Bostil encoder patcher (Linux / ELF64 port).

Patches Discord's `discord_voice.node` so the Go Live encoder is forced to H264
(instead of H265) with a shorter keyframe interval. On Linux `discord_voice.node`
is an ELF x86-64 shared object; on Windows it is a PE DLL. The only thing that
differs between the two is the file-offset <-> virtual-address mapping (PE
sections vs ELF PT_LOAD program headers). The codec-table anchor scan, the
RIP-relative `lea` site scan, and the keyframe byte find/replace are identical.

Signature JSON schema (one build entry) is identical to the Windows version:
    {
      "codec_table": "<hex>",
      "h265_disp_delta": <int>,
      "lea_site_count": <int>,
      "keyframe_sigs": [ { "orig": "<hex>", "patched": "<hex>", "deltas": [..] }, .. ]
    }

The script ALWAYS exits 0 and prints exactly one parseable status line on stdout,
so the bash orchestrator can parse the text (mirroring the Windows behavior where
python always exited 0 and PowerShell parsed the output).
"""

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path


# ---------------------------------------------------------------- ELF parsing

def elf_segments(data):
    """Parse ELF64 LE program headers; return loadable segments as
    (p_vaddr, p_filesz, p_offset) tuples (PT_LOAD only)."""
    if data[:4] != b'\x7fELF' or data[4] != 2 or data[5] != 1:
        raise ValueError('not an ELF64 LE file')
    e_phoff = struct.unpack_from('<Q', data, 0x20)[0]
    e_phentsize = struct.unpack_from('<H', data, 0x36)[0]
    e_phnum = struct.unpack_from('<H', data, 0x38)[0]
    out = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from('<I', data, off)[0]
        if p_type != 1:  # PT_LOAD
            continue
        p_offset = struct.unpack_from('<Q', data, off + 8)[0]
        p_vaddr = struct.unpack_from('<Q', data, off + 16)[0]
        p_filesz = struct.unpack_from('<Q', data, off + 32)[0]
        out.append((p_vaddr, p_filesz, p_offset))
    return out


def va_of(segs, off):
    """Map a file offset to its virtual address using PT_LOAD segments."""
    for p_vaddr, p_filesz, p_offset in segs:
        if p_offset <= off < p_offset + p_filesz:
            return p_vaddr + (off - p_offset)
    raise ValueError(f'offset 0x{off:X} outside ELF loadable segments')


# ---------------------------------------------------------------- locate sites

def locate(data, sig):
    codec_table = bytes.fromhex(sig['codec_table'])
    h265_disp_delta = sig['h265_disp_delta']
    lea_count = sig.get('lea_site_count', 4)
    keyframe_sigs = [
        (bytes.fromhex(k['orig']), bytes.fromhex(k['patched']), tuple(k['deltas']))
        for k in sig['keyframe_sigs']
    ]

    report = {'codec_table': False, 'lea_found': 0, 'lea_expected': lea_count, 'keyframe': []}
    try:
        segs = elf_segments(data)
    except ValueError as e:
        report['error'] = str(e)
        return None, report

    sites = []
    at = data.find(codec_table)
    if at < 0:
        return None, report
    report['codec_table'] = True
    h265_va = va_of(segs, at) + h265_disp_delta

    found = 0
    pos = data.find(b'\x48\x8D')                   # lea r64, [rip+disp32]
    while pos >= 0:
        i = pos
        pos = data.find(b'\x48\x8D', i + 1)
        if i + 7 > len(data):
            break
        if data[i + 2] & 0xC7 != 0x05:             # modrm mod=00 rm=101 -> RIP-relative
            continue
        disp = struct.unpack_from('<i', data, i + 3)[0]
        try:
            target = va_of(segs, i + 7) + disp
        except ValueError:
            continue
        if target != h265_va:
            continue
        sites.append((i + 3, bytes(data[i + 3:i + 7]), struct.pack('<i', disp - h265_disp_delta)))
        found += 1
    report['lea_found'] = found

    for orig, patched, deltas in keyframe_sigs:
        p = data.find(orig)
        report['keyframe'].append({'sig': orig.hex(), 'found': p >= 0})
        if p < 0:
            continue
        for d in deltas:
            sites.append((p + d, orig[d:d + 4], patched[d:d + 4]))

    ok = (report['codec_table'] and found == lea_count
          and all(k['found'] for k in report['keyframe']))
    return (sites if ok else None), report


# ---------------------------------------------------------------- modes

def do_probe(node, sig):
    data = bytearray(node.read_bytes())
    state_path = Path(str(node) + '.patch-state.json')
    state_match = False
    try:
        state = json.loads(state_path.read_text())
        state_match = (state.get('patched_sha256') == hashlib.sha256(bytes(data)).hexdigest())
    except Exception:
        pass
    sites, report = locate(bytes(data), sig)
    st = 'patched' if state_match else ('present_mismatch' if state_path.exists() else 'stock')
    print('PROBE ' + json.dumps({'state': st, 'locatable': sites is not None, **report}))


def do_patch(node, sig):
    data = bytearray(node.read_bytes())
    state_path = Path(str(node) + '.patch-state.json')

    state_match = False
    try:
        state = json.loads(state_path.read_text())
        state_match = (state.get('patched_sha256') == hashlib.sha256(bytes(data)).hexdigest())
    except Exception:
        pass

    if state_match:
        print('PATCH_STATUS already_applied')
        return

    sites, report = locate(bytes(data), sig)
    if sites is None:
        print('PATCH_STATUS error=locate_failed ' + json.dumps(report))
        return

    bak = Path(str(node) + '.stockbak')
    if not bak.exists():
        bak.write_bytes(bytes(data))

    applied = 0
    for off, orig, patched in sites:
        cur = bytes(data[off:off + 4])
        if cur == patched:
            applied += 1
        elif cur == orig:
            data[off:off + 4] = patched
            applied += 1

    if applied == len(sites):
        node.write_bytes(bytes(data))
        state_path.write_text(json.dumps({
            'patched_sha256': hashlib.sha256(bytes(data)).hexdigest(),
            'sites': [{'offset': o, 'original': orig.hex(), 'patched': p.hex()} for o, orig, p in sites],
        }))
        print(f'PATCH_STATUS applied={applied} total={len(sites)}')
    else:
        print(f'PATCH_STATUS applied={applied} total={len(sites)} partial')


def do_revert(node):
    state_path = Path(str(node) + '.patch-state.json')
    bak = Path(str(node) + '.stockbak')
    try:
        if bak.exists():
            node.write_bytes(bak.read_bytes())
            try:
                state_path.unlink()
            except FileNotFoundError:
                pass
            print('REVERT_STATUS restored_backup')
            return
        if state_path.exists():
            state = json.loads(state_path.read_text())
            data = bytearray(node.read_bytes())
            n = 0
            for s in state.get('sites', []):
                off = int(s['offset'])
                hexb = str(s['original'])
                b = bytes.fromhex(hexb)
                data[off:off + len(b)] = b
                n += 1
            node.write_bytes(bytes(data))
            try:
                state_path.unlink()
            except FileNotFoundError:
                pass
            print(f'REVERT_STATUS reverted_sites={n}')
            return
        print('REVERT_STATUS nothing')
    except Exception as e:
        print('REVERT_STATUS error=' + str(e)[:60].replace('\n', ' '))


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description='GoLive-Bostil ELF encoder patcher')
    ap.add_argument('--node', required=True, help='path to discord_voice.node')
    ap.add_argument('--mode', required=True, choices=['patch', 'probe', 'revert'])
    ap.add_argument('--sigs-json', default=None, help='one build signature object (compact JSON)')
    args = ap.parse_args()

    node = Path(args.node)
    try:
        if args.mode == 'revert':
            do_revert(node)
            return

        if not args.sigs_json:
            print('PATCH_STATUS error=missing_sigs' if args.mode == 'patch'
                  else 'PROBE ' + json.dumps({'state': 'unknown', 'locatable': False, 'error': 'missing_sigs'}))
            return
        sig = json.loads(args.sigs_json)

        if args.mode == 'probe':
            do_probe(node, sig)
        else:
            do_patch(node, sig)
    except Exception as e:
        short = str(e)[:80].replace('\n', ' ')
        if args.mode == 'probe':
            print('PROBE ' + json.dumps({'state': 'unknown', 'locatable': False, 'error': short}))
        elif args.mode == 'revert':
            print('REVERT_STATUS error=' + short[:60])
        else:
            print('PATCH_STATUS error=' + short[:60])


if __name__ == '__main__':
    main()
    sys.exit(0)

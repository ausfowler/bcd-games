#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
# Includes work from BCD by thebcd69.
"""MCD's pre-flight: the host checks of build-ipa.yml, in minutes, without building anything.

The IPA build runs about 650 steps over an hour, and on MCD's repository 414 of them may fail
without failing the build (BCD's public export lacks its private docs and history), so a green
run can hide a broken check. This runs every `python3 tests/host/<check>.py ...` command that
build-ipa.yml runs (read from the workflow, so it follows every BCD merge), plus MCD's own
tests/host/check-mcd-*.py, and compares the failures with tests/mcd-known-failures.txt:

  - a failure not in that list fails the pre-flight (exit 1);
  - a listed check that now passes is reported, so the list can shrink;
  - without the list (the first runs), nothing fails: the failures are printed in the list's
    format for the owner to review and commit.

    tools/mcd-preflight.py --shard 0 --of 3 --out results-0.json    run one share of the checks
    tools/mcd-preflight.py --summary results-*.json                 every share's results, compared
    tools/mcd-preflight.py --list                                   the commands it would run
"""
from pathlib import Path
import argparse
import json
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github' / 'workflows' / 'build-ipa.yml'
KNOWN = ROOT / 'tests' / 'mcd-known-failures.txt'
COMMAND = re.compile(r'^\s+(?:run: |- run: )?(python3 tests/host/[A-Za-z0-9_.\-]+\.py(?: [^\n|&;>`$]*)?)\s*$', re.M)


def commands():
    seen, out = set(), []
    for cmd in COMMAND.findall(WORKFLOW.read_text()):
        cmd = cmd.strip()
        if cmd not in seen:
            seen.add(cmd)
            out.append(cmd)
    for path in sorted((ROOT / 'tests' / 'host').glob('check-mcd-*.py')):
        cmd = f'python3 tests/host/{path.name} --require-swift' if '--require-swift' in path.read_text() else f'python3 tests/host/{path.name}'
        if not any(c.split()[1] == f'tests/host/{path.name}' for c in out):
            out.append(cmd)
    return out


def known():
    if not KNOWN.exists():
        return None
    return {line.split('#', 1)[0].strip() for line in KNOWN.read_text().splitlines()} - {''}


def run(shard, of, out, timeout):
    mine = [c for i, c in enumerate(commands()) if i % of == shard]
    results = []
    for n, cmd in enumerate(mine, 1):
        start = time.time()
        try:
            p = subprocess.run(cmd, shell=True, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
            code, tail = p.returncode, (p.stdout + p.stderr)[-1500:]
        except subprocess.TimeoutExpired:
            code, tail = 'timeout', f'over {timeout} s'
        took = round(time.time() - start, 1)
        ok = code == 0
        print(f'[{n}/{len(mine)}] {"ok  " if ok else "FAIL"} {took:7.1f}s  {cmd}', flush=True)
        if not ok:
            print('      ' + tail.replace('\n', '\n      ')[-900:], flush=True)
        results.append({'cmd': cmd, 'ok': ok, 'code': str(code), 'seconds': took})
    Path(out).write_text(json.dumps(results, indent=1))


def summary(paths):
    results = []
    for p in paths:
        results += json.loads(Path(p).read_text())
    failed = sorted(r['cmd'] for r in results if not r['ok'])
    slow = sorted(results, key=lambda r: -r['seconds'])[:10]
    print(f'{len(results)} checks, {len(failed)} failed, {sum(r["seconds"] for r in results) / 60:.1f} min of checks')
    print('slowest: ' + '; '.join(f'{r["cmd"].split()[1].split("/")[-1]} {r["seconds"]}s' for r in slow))
    expected = known()
    if expected is None:
        print('\nNo tests/mcd-known-failures.txt yet: report only. The failures, in its format:\n')
        for cmd in failed:
            print(cmd)
        return 0
    new = [c for c in failed if c not in expected]
    fixed = sorted(c for c in expected if c not in failed and any(r['cmd'] == c for r in results))
    gone = sorted(c for c in expected if not any(r['cmd'] == c for r in results))
    for c in fixed:
        print(f'::notice::now passes (remove from tests/mcd-known-failures.txt): {c}')
    for c in gone:
        print(f'::notice::no longer run by build-ipa.yml (remove from tests/mcd-known-failures.txt): {c}')
    for c in new:
        print(f'::error::new failure: {c}')
    print(f'\n{len(new)} new failure(s), {len(fixed)} fixed, {len(failed) - len(new)} known')
    return 1 if new else 0


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--shard', type=int, default=0)
    ap.add_argument('--of', type=int, default=1)
    ap.add_argument('--out', default='preflight-results.json')
    ap.add_argument('--timeout', type=int, default=900)
    ap.add_argument('--summary', nargs='*')
    ap.add_argument('--list', action='store_true')
    a = ap.parse_args()
    if a.list:
        for c in commands():
            print(c)
        sys.exit(0)
    if a.summary is not None:
        sys.exit(summary(a.summary))
    run(a.shard, a.of, a.out, a.timeout)

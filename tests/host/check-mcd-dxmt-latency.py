#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
# Includes work from BCD by thebcd69.
"""MADEIRA_DXMT_MAX_LATENCY (tools/patch-mcd-dxmt-latency.py): how many frames a D3D11/10 game may run ahead of DXMT.

  1. The patch on a copy of the pinned dxmt: every anchor once, the result as intended, a second run changes nothing, and
     unset it keeps DXMT's own depth (max_latency_ = 3 and SetMaxLatency's value).
  2. The code it adds, compiled with g++/clang++ and stand-ins for DXMT's env and log helpers: 1..16 is taken and wins over
     a later SetMaxLatency (the game's SetMaximumFrameLatency); unset, empty, 0, 17, "2x" and "-1" leave DXMT's own.
  3. tools/build-d3d11-dll.sh applies it to its copy through BCD_PATCHES, with the marker its log line leaves in the DLL;
     nothing applies it to the submodule (the default 64-bit d3d11.dll is a prebuilt file, the 32-bit one stays DXMT's).
Without the dxmt submodule checked out, part 1 is skipped (CI checks it out)."""
from pathlib import Path
import importlib.util
import os
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


spec = importlib.util.spec_from_file_location('patch', ROOT / 'tools' / 'patch-mcd-dxmt-latency.py')
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)

# 1. The patch on a copy.
src = ROOT / 'dxmt' / 'src' / 'dxmt'
if (src / 'dxmt_command_queue.cpp').exists():
    with tempfile.TemporaryDirectory(prefix='mcd-latency-') as d:
        work = Path(d) / 'dxmt' / 'src'
        work.mkdir(parents=True)
        shutil.copytree(src, work / 'dxmt')
        first = subprocess.run(['python3', str(ROOT / 'tools' / 'patch-mcd-dxmt-latency.py')], cwd=d, capture_output=True, text=True)
        check(first.returncode == 0, 'the patch applies to the pinned dxmt (every anchor once)')
        hpp = (work / 'dxmt' / 'dxmt_command_queue.hpp').read_text()
        cpp = (work / 'dxmt' / 'dxmt_command_queue.cpp').read_text()
        check('uint32_t max_latency_ = 3;\n' in hpp and 'uint32_t mcd_latency_override_ = 0;' in hpp,
              "DXMT's default depth stays 3; the override starts at 0 (none)")
        check('max_latency_ = mcd_latency_override_ ? mcd_latency_override_ : value;' in hpp,
              "SetMaxLatency: the override wins, else the game's value as before")
        check(cpp.count('env::getEnvVar("MADEIRA_DXMT_MAX_LATENCY")') == 1 and '[mcd-latency] MCD MADEIRA_DXMT_MAX_LATENCY=' in cpp,
              'the constructor reads MADEIRA_DXMT_MAX_LATENCY once and logs it')
        before = (hpp, cpp)
        second = subprocess.run(['python3', str(ROOT / 'tools' / 'patch-mcd-dxmt-latency.py')], cwd=d, capture_output=True, text=True)
        after = ((work / 'dxmt' / 'dxmt_command_queue.hpp').read_text(), (work / 'dxmt' / 'dxmt_command_queue.cpp').read_text())
        check(second.returncode == 0 and before == after, 'a second run changes nothing')
    pristine = (src / 'dxmt_command_queue.hpp').read_text() + (src / 'dxmt_command_queue.cpp').read_text()
    check(patch.MARKER not in pristine, 'the submodule itself is not patched')
else:
    print('SKIP: dxmt is not checked out here; CI checks the patch against the pin')

# 2. The added code, compiled.
block = patch.CPP_CTOR_NEW[patch.CPP_CTOR_NEW.index('  /* MCD mcd-dxmt-latency-v1'):].rstrip().rstrip('}')
setter = patch.HPP_SET_NEW.splitlines()[1]
program = r'''
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <sstream>
#define WARN(...) warned++
static int warned = 0;
static const char *g_env = nullptr;
namespace env { std::string getEnvVar(const char *) { return g_env ? g_env : ""; } }
struct CommandQueue {
  uint32_t max_latency_ = 3;
  uint32_t mcd_latency_override_ = 0;
  CommandQueue() {
''' + block + r'''
  }
''' + setter + r'''
};
static int bad = 0;
static void expect(bool ok, const char *label) { std::printf("%s: %s\n", ok ? "PASS" : "FAIL", label); if (!ok) bad++; }
int main() {
  struct { const char *env; uint32_t want; uint32_t after_set5; } cases[] = {
    {nullptr, 3, 5}, {"", 3, 5}, {"1", 1, 1}, {"2", 2, 2}, {"16", 16, 16},
    {"0", 3, 5}, {"17", 3, 5}, {"2x", 3, 5}, {"-1", 3, 5}};
  for (auto &c : cases) {
    g_env = c.env;
    CommandQueue q;
    bool start = q.max_latency_ == c.want;
    q.SetMaxLatency(5);
    std::string label = std::string("MADEIRA_DXMT_MAX_LATENCY=") + (c.env ? c.env : "(unset)");
    expect(start && q.max_latency_ == c.after_set5, label.c_str());
  }
  return bad ? 1 : 0;
}
'''
cxx = os.environ.get('CXX') or shutil.which('clang++') or shutil.which('g++')
if cxx:
    with tempfile.TemporaryDirectory(prefix='mcd-latency-cc-') as d:
        (Path(d) / 'main.cpp').write_text(program)
        built = subprocess.run([cxx, '-std=c++20', '-Wall', '-Werror', '-Wno-unused-variable', str(Path(d) / 'main.cpp'), '-o', str(Path(d) / 'm')],
                               capture_output=True, text=True)
        check(built.returncode == 0, 'the added C++ compiles (-Wall -Werror)')
        if built.returncode:
            print(built.stderr[-2500:])
        else:
            run = subprocess.run([str(Path(d) / 'm')], capture_output=True, text=True)
            print(run.stdout, end='')
            check(run.returncode == 0, 'it takes 1..16, refuses the rest, and wins over SetMaxLatency')
else:
    print('SKIP: no C++ compiler')

# 3. The wiring.
sh = (ROOT / 'tools' / 'build-d3d11-dll.sh').read_text()
line = 'BCD_PATCHES+=("patch-mcd-dxmt-latency.py" "[mcd-latency] MCD MADEIRA_DXMT_MAX_LATENCY=")'
check(sh.count(line) == 1, "build-d3d11-dll.sh adds it to BCD_PATCHES, with its log line's marker")
check(sh.index(line) < sh.index('SHIP_HAS_BCD=1') < sh.index('for ((i = 0; i < ${#BCD_PATCHES[@]}; i += 2)); do'),
      'before the list is checked against the committed DLL and applied to the copy')
check(patch.CPP_CTOR_NEW.count('WARN("[mcd-latency] MCD MADEIRA_DXMT_MAX_LATENCY="') == 2, 'the marker is a string literal (both log lines), so the DLL carries it')
workflow = (ROOT / '.github' / 'workflows' / 'build-ipa.yml').read_text()
check('patch-mcd-dxmt-latency' not in workflow, 'no workflow step patches the submodule (the 32-bit d3d11.dll stays as it was)')

if failures:
    raise SystemExit(f'{failures} check(s) failed')
print('check-mcd-dxmt-latency: all passed')

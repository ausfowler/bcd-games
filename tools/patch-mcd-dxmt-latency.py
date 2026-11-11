#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
# Includes work from BCD by thebcd69.
"""MADEIRA_DXMT_MAX_LATENCY: how many frames a Direct3D 11/10 game may run ahead of DXMT (MCD).

DXMT's command queue lets the game's thread run max_latency_ frames ahead of the GPU: after Present N it waits in
PresentBoundary() for frame N - max_latency_ to finish (dxmt/src/dxmt/dxmt_command_queue.hpp, default 3, or what the game asks
with SetMaximumFrameLatency). Under a present cap (vsync mode 4, 40 FPS: afterMinimumDuration(1/40), winemetal_unix.c) the
queue stays full, so the frame on screen was built from input read about three frames earlier: a Valheim run on the owner's
iPhone Duo (2026-11-10, mode 4, 652 s) waited 24.9 ms in nextDrawable every frame and felt laggy.

MADEIRA_DXMT_MAX_LATENCY = 1..16 (a game's own line) sets the queue's depth and wins over the game's SetMaximumFrameLatency.
With 1, the game's thread waits right after its Present for the previous frame and starts the next one -- reads its input --
as soon as that frame is out. Meant with MADEIRA_PRESENT_LIMITER = 1 (BCD's mach_wait_until pacing, which presents with no
minimum duration so the drawables come straight back). Unset, empty or out of range: DXMT's own behaviour, unchanged.
Logged once: "[mcd-latency] MCD MADEIRA_DXMT_MAX_LATENCY=<n>" (also the marker tools/build-d3d11-dll.sh looks for).

PE side, so only a DXMT built here carries it: d3d11-src.dll (a 64-bit game gets it with env.MADEIRA_D3D11_SRC = 1; the
default 64-bit d3d11.dll is a prebuilt file). tools/build-d3d11-dll.sh applies this to its copy, from a directory whose
"dxmt" is that copy. Idempotent (marker "mcd-dxmt-latency-v1"); exits 1 naming the anchor when one moved, files unchanged.
"""
import pathlib
import sys

D = pathlib.Path("dxmt/src/dxmt")
MARKER = "mcd-dxmt-latency-v1"
HPP = D / "dxmt_command_queue.hpp"
CPP = D / "dxmt_command_queue.cpp"

HPP_FIELD_OLD = "  uint32_t max_latency_ = 3;\n"
HPP_FIELD_NEW = (
    "  uint32_t max_latency_ = 3;\n"
    "  /* MCD mcd-dxmt-latency-v1 (tools/patch-mcd-dxmt-latency.py): MADEIRA_DXMT_MAX_LATENCY, 0 = the game's / DXMT's own */\n"
    "  uint32_t mcd_latency_override_ = 0;\n"
)
HPP_SET_OLD = "  void SetMaxLatency(uint32_t value) { max_latency_ = value; };\n"
HPP_SET_NEW = (
    "  /* MCD mcd-dxmt-latency-v1: MADEIRA_DXMT_MAX_LATENCY wins over the game's SetMaximumFrameLatency */\n"
    "  void SetMaxLatency(uint32_t value) { max_latency_ = mcd_latency_override_ ? mcd_latency_override_ : value; };\n"
)
CPP_CTOR_OLD = """  std::string env = env::getEnvVar("DXMT_CAPTURE_FRAME");

  if (!env.empty()) {
    try {
      capture_state.scheduleNextFrameCapture(std::stoull(env));
    } catch (const std::invalid_argument &) {
    }
  }
}
"""
CPP_CTOR_NEW = """  std::string env = env::getEnvVar("DXMT_CAPTURE_FRAME");

  if (!env.empty()) {
    try {
      capture_state.scheduleNextFrameCapture(std::stoull(env));
    } catch (const std::invalid_argument &) {
    }
  }

  /* MCD mcd-dxmt-latency-v1 (tools/patch-mcd-dxmt-latency.py): MADEIRA_DXMT_MAX_LATENCY = 1..16 frames the game may run
   * ahead (DXMT's default 3); anything else leaves DXMT's own. */
  std::string mcd_latency = env::getEnvVar("MADEIRA_DXMT_MAX_LATENCY");
  if (!mcd_latency.empty()) {
    char *mcd_end = nullptr;
    unsigned long mcd_value = std::strtoul(mcd_latency.c_str(), &mcd_end, 10);
    if (mcd_end && *mcd_end == '\\0' && mcd_value >= 1 && mcd_value <= 16) {
      mcd_latency_override_ = (uint32_t)mcd_value;
      max_latency_ = (uint32_t)mcd_value;
      WARN("[mcd-latency] MCD MADEIRA_DXMT_MAX_LATENCY=", mcd_value,
           ": the game runs at most this many frames ahead (DXMT's default is 3)");
    } else {
      WARN("[mcd-latency] MCD MADEIRA_DXMT_MAX_LATENCY=", mcd_latency, " ignored (want 1..16)");
    }
  }
}
"""


def main():
    texts = {p: p.read_text() for p in (HPP, CPP)}
    marked = [MARKER in t for t in texts.values()]
    if all(marked):
        print("dxmt command queue: MADEIRA_DXMT_MAX_LATENCY already patched")
        return 0
    if any(marked):
        print("::error::patch-mcd-dxmt-latency: only some files carry the marker -- dxmt moved, review this patch")
        return 1
    checks = ((HPP, HPP_FIELD_OLD, "dxmt_command_queue.hpp: max_latency_"),
              (HPP, HPP_SET_OLD, "dxmt_command_queue.hpp: SetMaxLatency"),
              (CPP, CPP_CTOR_OLD, "dxmt_command_queue.cpp: the constructor's DXMT_CAPTURE_FRAME tail"))
    for path, old, name in checks:
        n = texts[path].count(old)
        if n != 1:
            print(f"::error::patch-mcd-dxmt-latency: {name}: anchor found {n} times (want 1) -- dxmt moved, review this patch")
            return 1
    if "#include <cstdlib>" not in texts[CPP] and "#include <stdlib.h>" not in texts[CPP]:
        texts[CPP] = texts[CPP].replace('#include "dxmt_command_queue.hpp"\n', '#include "dxmt_command_queue.hpp"\n#include <cstdlib>   /* MCD: strtoul */\n', 1)
    HPP.write_text(texts[HPP].replace(HPP_FIELD_OLD, HPP_FIELD_NEW, 1).replace(HPP_SET_OLD, HPP_SET_NEW, 1))
    CPP.write_text(texts[CPP].replace(CPP_CTOR_OLD, CPP_CTOR_NEW, 1))
    print("dxmt command queue patched (MADEIRA_DXMT_MAX_LATENCY, unset = DXMT's own)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

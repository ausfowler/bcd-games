# WebRTC.framework's third-party notices

MCD's Cloud engine embeds the `WebRTC.framework` that OpenNOW ships (`app/MCDCloud/Frameworks`). Like
every WebRTC build, it contains code from other projects, whose licences ask for their notices to travel
with the binary. OpenNOW's copy carries only WebRTC's own `LICENSE`, so MCD collects the others here, and
`tools/mcd-cloud-vendor.py` appends them to `app/Madeira/legal/LICENSES/BSD-3-WebRTC.txt` (Settings ›
About lists it).

What is inside was read from the framework itself (2026-11-02): its strings name `third_party/boringssl`,
`third_party/opus`, `third_party/abseil-cpp`, `third_party/protobuf`, `third_party/libc++` and
`third_party/libc++abi`, and the libvpx (VP8/VP9), libaom (AV1 encoder), dav1d (AV1 decoder), libyuv and
libsrtp code paths. pffft, RNNoise, crc32c and WebRTC's own `third_party` folders (Ooura FFT, sigslot,
base64, spl_sqrt_floor) are part of every WebRTC audio and networking build and are included as well:
a notice too many costs nothing, one too few is a licence breach.

Each text is the project's own licence file, fetched on 2026-11-02:

| File | Project | Licence | From |
|---|---|---|---|
| `boringssl.txt` | BoringSSL | Apache-2.0 (and its support-code notices) | github.com/google/boringssl `LICENSE` |
| `boringssl-before-2025.txt` | BoringSSL, releases before its 2025 relicensing | OpenSSL, SSLeay and ISC | github.com/google/boringssl tag `0.20240913.0` `LICENSE` |
| `boringssl-fiat.txt` | fiat-crypto, inside BoringSSL | MIT / Apache-2.0 | github.com/google/boringssl `third_party/fiat/LICENSE` |
| `opus.txt` | Opus | BSD-3-Clause | github.com/xiph/opus `COPYING` |
| `libvpx.txt`, `libvpx-PATENTS.txt` | libvpx | BSD-3-Clause, with a patent grant | github.com/webmproject/libvpx |
| `libaom.txt`, `libaom-PATENTS.txt` | libaom | BSD-2-Clause, with the AOM Patent License 1.0 | AOM's repository, through the github.com/m-ab-s/aom mirror |
| `dav1d.txt` | dav1d | BSD-2-Clause | github.com/videolan/dav1d `COPYING` |
| `libyuv.txt` | libyuv | BSD-3-Clause | libyuv's repository, through the github.com/lemenkov/libyuv mirror |
| `libsrtp.txt` | libSRTP | BSD-3-Clause | github.com/cisco/libsrtp |
| `abseil-cpp.txt` | Abseil | Apache-2.0 | github.com/abseil/abseil-cpp |
| `protobuf.txt` | Protocol Buffers | BSD-3-Clause | github.com/protocolbuffers/protobuf |
| `libcxx.txt`, `libcxxabi.txt` | LLVM libc++ and libc++abi | Apache-2.0 WITH LLVM-exception | github.com/llvm/llvm-project |
| `pffft.txt` | PFFFT | BSD-like (FFTPACK) | Chromium's `third_party/pffft/LICENSE` |
| `rnnoise.txt` | RNNoise | BSD-3-Clause | Chromium's `third_party/rnnoise/COPYING` |
| `crc32c.txt` | CRC32C | BSD-3-Clause | github.com/google/crc32c |
| `webrtc-ooura.txt` | Ooura FFT | Ooura's licence | WebRTC `common_audio/third_party/ooura` (github.com/webrtc-sdk/webrtc mirror) |
| `webrtc-sigslot.txt` | sigslot | public domain | WebRTC `rtc_base/third_party/sigslot` |
| `webrtc-base64.txt` | base64 | its own permissive notice | WebRTC `rtc_base/third_party/base64` |
| `webrtc-spl_sqrt_floor.txt` | spl_sqrt_floor | its own permissive notice | WebRTC `common_audio/third_party/spl_sqrt_floor` |
| `webrtc-PATENTS.txt` | WebRTC | its patent grant | WebRTC `PATENTS` |

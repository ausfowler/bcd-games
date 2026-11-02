# OpenNOW in MCD

MCD's Cloud engine is OpenNOW's iOS client (https://github.com/OpenCloudGaming/OpenNOW, MIT),
copied by `tools/mcd-cloud-vendor.py`. Do not edit `Sources/MCDCloud/OpenNOW` or `Frameworks` by
hand: change the script's patches and run it again.

- Commit: `f30eda8e2ec0dba17c08d1f5d9a1dda60106a8fb` (2026-10-31 fix(ios): support resizable Duo scenes and compact queue actions (#1390))
- Swift files: 127
- Libraries: OpenSSL and usrsctp from OpenNOW's pinned archive (SHA-256 `700e218ace883213de500707095ff322d8ec179235b231ceb61d0007a353ea56`), WebRTC from OpenNOW's repository; iPhone (ios-arm64) only.

## MCD's patches to OpenNOW's files

- `OpenNOWiOSApp.swift`: MCD is the app: OpenNOW's @main entry point must not be compiled into it.
- `OpenNOWiOSApp.swift`: Closes the block opened above.
- `NativeStreamInput.swift`: OpenNOW writes controller-rumble-status.json for diagnostics; in MCD, Documents is the folder you see in Files, so it goes to Caches.

## OpenSSL routines renamed (prefix `mcd_ossl_`)

GnuTLS, which MCD already links, defines the same CRYPTOGAMS routines; OpenSSL's copies are
renamed, definitions and references, so each library only ever calls its own:

- `_aes_v8_cbc_encrypt` → `_mcd_ossl_aes_v8_cbc_encrypt`
- `_aes_v8_ctr32_encrypt_blocks` → `_mcd_ossl_aes_v8_ctr32_encrypt_blocks`
- `_aes_v8_decrypt` → `_mcd_ossl_aes_v8_decrypt`
- `_aes_v8_ecb_encrypt` → `_mcd_ossl_aes_v8_ecb_encrypt`
- `_aes_v8_encrypt` → `_mcd_ossl_aes_v8_encrypt`
- `_aes_v8_set_decrypt_key` → `_mcd_ossl_aes_v8_set_decrypt_key`
- `_aes_v8_set_encrypt_key` → `_mcd_ossl_aes_v8_set_encrypt_key`
- `_aes_v8_xts_decrypt` → `_mcd_ossl_aes_v8_xts_decrypt`
- `_aes_v8_xts_encrypt` → `_mcd_ossl_aes_v8_xts_encrypt`
- `_gcm_ghash_v8` → `_mcd_ossl_gcm_ghash_v8`
- `_gcm_gmult_v8` → `_mcd_ossl_gcm_gmult_v8`
- `_gcm_init_v8` → `_mcd_ossl_gcm_init_v8`
- `_sha1_block_data_order` → `_mcd_ossl_sha1_block_data_order`
- `_sha256_block_data_order` → `_mcd_ossl_sha256_block_data_order`
- `_sha512_block_data_order` → `_mcd_ossl_sha512_block_data_order`

## OpenSSL headers

Their 525 `#include <openssl/...>` lines are written `#include <OpenSSL/openssl/...>`, so the
framework's headers resolve through the framework itself (a Swift package target has no header
search path setting; OpenNOW's Xcode project adds one).

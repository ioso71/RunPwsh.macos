# vendor/

`NppPluginInterfaceMac.h` is an **unmodified, byte-for-byte copy** of the
plugin API contract from the Nextpad++ host repository:

    /Volumes/S-Drive/Privat/Repository/Nextpad-plusplus/nextpad-plus-plus-macos/src/NppPluginInterfaceMac.h

Copied on: 2026-08-10 (from the copy already vendored in `../../finder/vendor/`,
same contract, same SHA-256 — no host-side change since the Finder plugin's
own vendoring on 2026-08-06)
SHA-256:   f4a10d6eed2a9fec6a26a5c181aa4c519ca18a58dab649cf7fea7ce73f19f47a

We vendor this header instead of pointing a relative include path into the
host repo because:

1. The host repo is explicitly off-limits for changes and should not gain a
   reverse dependency from a plugin project sitting next to it.
2. Plugins are built and shipped independently of the host source tree (they
   only need the stable ABI contract, not the rest of the app).

## Keeping it in sync

The plugin ABI is meant to be stable (mirrors the Windows Notepad++ plugin
API 1:1, plus a small macOS-only extension block at `NPPMSG + 500` and
above). If the host header changes, re-copy it and update the SHA-256 above:

```sh
cp "/Volumes/S-Drive/Privat/Repository/Nextpad-plusplus/nextpad-plus-plus-macos/src/NppPluginInterfaceMac.h" \
   "/Volumes/S-Drive/Privat/Repository/Nextpad-plusplus/plugins/Plugins/RunPwsh/vendor/NppPluginInterfaceMac.h"
shasum -a 256 vendor/NppPluginInterfaceMac.h
```

Do **not** hand-edit `NppPluginInterfaceMac.h` in this project — it must stay
an exact mirror of the host's contract.

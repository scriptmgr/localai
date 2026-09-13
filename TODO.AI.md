# TODO.AI.md

Pre-existing `script-lint` findings on `install.sh`, surfaced during the
2026-09-13 install.sh fix/README/LICENSE commit. None block that commit (all
pre-existing, not introduced by it) — tracked here per policy.

- [ ] install.sh:90 — function `info` missing `__` prefix, rename to `__info()`
- [ ] install.sh:91 — function `ok` missing `__` prefix, rename to `__ok()`
- [ ] install.sh:92 — function `warn` missing `__` prefix, rename to `__warn()`
- [ ] install.sh:93 — function `die` missing `__` prefix, rename to `__die()`
- [ ] install.sh:96 — function `have` missing `__` prefix, rename to `__have()`
- [ ] install.sh:97 — function `container_gone` missing `__` prefix, rename to `__container_gone()`
- [ ] install.sh:22 — var `INSTALL_DOCKGE` uses forbidden lifecycle-stage prefix, rename to `LOCALAI_INSTALL_DOCKGE`
- [ ] install.sh:23 — var `INSTALL_COMFYUI` uses forbidden lifecycle-stage prefix, rename to `LOCALAI_INSTALL_COMFYUI`
- [ ] install.sh:50 — var `INSTALL_GPU_DRIVER` uses forbidden lifecycle-stage prefix, rename to `LOCALAI_INSTALL_GPU_DRIVER`
- [ ] install.sh:97 — `grep -qx` missing `--` before query, use `grep -qx -- "$1"`
- [ ] install.sh:177 — `grep -qi` missing `--` before query, use `grep -qi -- nvidia`
- [ ] install.sh:309 — `grep -qi` missing `--` before query, use `grep -qi -- 'enabled'`
- [ ] install.sh:156 — inline comment on code line, move above the `;;`
- [ ] install.sh:178 — `grep -Eqi` missing `--` before query, use `grep -Eqi -- 'AMD|ATI|Advanced Micro Devices'`
- [ ] install.sh:525 — inline comment on code line, move above

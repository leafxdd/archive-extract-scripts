# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Overview

A collection of PowerShell scripts for batch-extracting password-protected archives that are disguised as `.mp4` files. Each script is tailored for a specific source/service with its own password and pipeline depth. All scripts share one WinRAR-based engine; they differ only in password, pipeline depth, and final-placement behaviour.

## Running a Script

Scripts are run from PowerShell 7 (`pwsh`). They also work under Windows PowerShell 5.1 because every script is saved as **UTF-8 with BOM** (without the BOM, 5.1 reads the CJK text as GBK and corrupts it). Place the `.mp4` / archive files in the same directory as the script, then execute:

```powershell
# Default: WorkDir = script location, deletes source files after a chain fully succeeds
.\FLYYZ_fixed.ps1

# Keep all source files, specify a custom work directory
.\FLYYZ_fixed.ps1 -WorkDir "D:\downloads\FLYYZ" -KeepFiles

# Mixed DORO/PADIO batch: auto-classifies by file name before extracting
.\DORO_PADIO.ps1

# Unified menu: pick the source interactively, then runs the matching pipeline
.\extract.ps1
```

Every script except `yejiang_split_steps_step3_mode.ps1` is parameter-based (`-WorkDir`, `-KeepFiles`; the per-source scripts also accept `-Password`). `yejiang_split_steps_step3_mode.ps1` is the one exception — edit the `$deleteFlag`, `$password`, and `$step3Flatten` variables at the top of the file before running.

## Required Tools

| Tool | Expected path |
|------|--------------|
| WinRAR | `%ProgramFiles%\WinRAR\WinRAR.exe` |

**WinRAR only.** Every stage of every script extracts with WinRAR; there is no 7-Zip dependency. This is safe because the archives these scripts handle never use compression methods unique to 7-Zip-Zstandard (e.g. zstd). If a future source does, WinRAR will fail to extract it and the chain will be reported as failed (source files preserved) rather than silently mishandled.

## Architecture

All scripts follow the same mental model:

1. **Stage 0 — Unmask** (skipped by the `direct` pipeline): rename `.mp4` → `.zip`, then extract with WinRAR into an isolated `output0\<entry-name>\`.
2. **Stage 1+ — Unwrap**: re-extract the archives found inside the previous stage's directory. Each script has a fixed depth (1, 2, or 3); there is no open-ended multi-pass loop.
3. **Final placement**: the last layer places content into `output\` (smart or structure-preserving, per script).
4. **Chain-scoped cleanup**: delete a source's archives only after its whole chain succeeds; then remove empty intermediate dirs and folders.

The pipeline depth and final-placement behaviour varies by script (all stages use WinRAR):

| Script | Pipeline | Depth | Final placement | Multi-format |
|--------|----------|-------|-----------------|-------------|
| `PADIO.ps1` | mp4 → output0\name → output | 2 | smart¹ | zip/7z/rar/all splits |
| `FLYYZ_fixed.ps1` | mp4 → output0\name → output | 2 | smart¹ | zip/7z/rar/all splits |
| `yecgaa_fixed.ps1` | mp4 → output0\name → output | 2 | smart¹ | zip/7z/rar/all splits |
| `yejiang.ps1` | mp4 → output0\name → output | 2 | smart¹ | zip/7z/rar/all splits |
| `DORO.ps1` | mp4 → output0\name → output1\name\archive → output | 3 | smart¹ | zip/7z/rar/all splits |
| `DORO_PADIO.ps1` | classified: PADIO (depth 2) or DORO (depth 3) | 2/3 | smart¹ | zip/7z/rar/all splits |
| `c291dGhwbHVz.ps1` | direct to output\<rel-path> (no mp4 rename) | 1 | structure-preserving (rel path) | zip/7z/rar/all splits |
| `yejiang_split_steps_step3_mode.ps1` | mp4 → output0\<rel>\name → output | 2 | structure-preserving, or flatten if `$step3Flatten` | zip/7z/rar/all splits |
| `extract.ps1` | unified menu → standard / three-stage / direct / yejiang sub-modes | 1–3 | per chosen pipeline | zip/7z/rar/all splits |

¹ **Smart final placement** (`Expand-ArchiveSmartFinal`): WinRAR cannot list an archive's contents to stdout, so structure is inspected by extracting first. The archive is extracted into an isolated temp dir under `output\`; if its top level contains at least one folder, each top-level item is moved directly into `output\`; if the top level is all loose files, the temp dir is renamed to a same-name subdirectory to avoid file scattering. This replaces the old `7z l -slt` preflight.

## Key Implementation Patterns

**Archive entrypoint detection** (`Get-ArchiveEntrypoints`): scans all files once and classifies them as `zip`, `7z`, `zip-z` (PKZIP split via `.z01`), `zip-z01` (a `.z01` whose `.zip` is missing), `zip-001`, `7z-001`, `rar`, `rar-part` (`.partN.rar`), or `rar-r00`. Only the first volume of each split set is emitted.

**Empty-extraction guard** (`Invoke-WinRARExtract`): WinRAR's exit code is only reliable for *data*-encrypted archives (wrong password → 7z exits 3, zip exits 10). For a **header-encrypted 7z** (`-mhe=on`), a wrong password makes WinRAR exit **0 while extracting nothing** — so trusting the exit code alone reports false success and deletes the source. The guard therefore requires that a successful extraction produced at least one item in its (freshly created, isolated) target directory; "exit 0 but zero items" is treated as failure. This is the root-cause fix for the earlier data-loss bug where a wrong-password inner archive still reported success and deleted source files.

**Chain-scoped cleanup**: never delete source or intermediate archives immediately after one extraction step succeeds. Each initial source carries a cleanup chain (`CleanupEntries`) holding the renamed source archive and every intermediate/final archive entrypoint derived from it. The chain is deleted only after all required stages for that source complete successfully; failed chains keep their source and intermediate archives for debugging. In the depth-3 pipeline a failed middle layer skips the final layer entirely. Empty-folder cleanup runs only after the successful chains have been cleaned. (`c291dGhwbHVz.ps1` is depth-1, so its per-entry deletion is already chain-scoped.)

**Intermediate directory isolation**: intermediate extractions never flatten into a shared `output0\` / `output1\`. Stage 0 extracts to `output0\<entry-name>\`; the DORO middle layer extracts each archive to `output1\<entry-name>\<rel-dir>\<archive-name>\`. This per-source isolation is what makes chain tracking possible. The final layer is the only one that uses smart placement into `output\`.

**Resume behaviour**: if a prior run completed stage 0 and then failed later, a rerun scans existing `output0\<entry-name>\` directories that still contain archive entrypoints and resumes them as stage-0 jobs. This prevents the user from having to restore already-deleted source `.zip` files after a failed later stage.

**Conflict handling**: every extraction goes through a wrapper that never overwrites. Existing isolated target directories get a `__2`, `__3`, … suffix (`Get-UniqueDirectoryPath`); smart/flatten conflicts in `output\` rename the existing top-level file or folder to `__existing_2`, `__existing_3`, … (`Move-ExistingPathAside`) before moving the new item in. WinRAR is invoked with `-or` (rename automatically) as a second guard.

**Steganographier MP4 disguise**: ordinary SteganographierGUI `mp4` output is cover-video bytes followed by appended ZIP data, so stage 0 must rename `.mp4` → `.zip` and extract with WinRAR. Do not reintroduce 7z anywhere in these scripts: 7z can fail to read these disguised inputs (and mis-handles the header-encrypted inner archives) even though WinRAR extracts them correctly.

**DORO/PADIO classifier** (`DORO_PADIO.ps1`): initial files are classified before extraction. Names containing `doro` use password `doro` and the three-stage DORO pipeline. Four-digit base names such as `1772.mp4` use password `PADIO294` and the two-stage PADIO pipeline. Unknown names open an arrow-key menu so the user can choose DORO, PADIO, or Skip; manual choices made before `.mp4` → `.zip` are cached for the renamed archive so the script does not ask twice.

**Unified menu** (`extract.ps1`): one script wraps the whole engine behind an arrow-key menu (`Show-Menu`). Selecting a source sets the password/junk-file config and dispatches to one of four pipeline orchestrators — `standard` (depth 2, PADIO/FLYYZ/yecgaa), `three-stage` (depth 3, DORO), `direct` (depth 1, c291), or `yejiang` (a sub-menu: `simple` = depth-2 smart, `split-structured` = structure-preserving, `split-flatten` = flatten to `output\`). All four share the same WinRAR engine, empty-guard, and chain-scoped deletion as the standalone scripts.

**WinRAR invocation**: `WinRAR.exe` is a GUI-subsystem program, so it must be launched with `Start-Process -Wait -PassThru -NoNewWindow` to obtain a real exit code; `-ibck` runs it in the background. Success is `ExitCode -eq 0` **and** the empty-extraction guard passing.

**Path safety**: use `-LiteralPath` everywhere (never `-Path` with user-provided values) to handle archive names containing `[`, `]`, CJK, spaces, and other glob metacharacters. Directory creation uses `[System.IO.Directory]::CreateDirectory()` for the same reason. Scripts must be saved UTF-8 **with BOM**.

**Passwords** are hardcoded per script: `yejiang`, `doro`, `PADIO294`, `c291dGhwbHVz`, `yecgaa`, `FLYYZ`. When creating a new script for a new source, copy `FLYYZ_fixed.ps1` (the canonical depth-2 template — WinRAR-only, smart final placement, empty-guard, chain-scoped deletion) and change only `$Password` and the display name in the header.

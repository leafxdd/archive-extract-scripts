# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Overview

A collection of PowerShell scripts for batch-extracting password-protected archives that are disguised as `.mp4` files. Each script is tailored for a specific source/service with its own password and pipeline depth.

## Running a Script

All scripts are run directly from PowerShell. Place the `.mp4` / archive files in the same directory as the script, then execute:

```powershell
# Default: WorkDir = script location, deletes source files after extraction
.\FLYYZ_fixed.ps1

# Keep source files, specify a custom work directory
.\FLYYZ_fixed.ps1 -WorkDir "D:\downloads\FLYYZ" -KeepFiles

# Mixed DORO/PADIO batch: auto-classifies by file name before extracting
.\DORO_PADIO.ps1
```

`yejiang.ps1` and `yejiang_split_steps_step3_mode.ps1` are older scripts with no parameters — edit the `$deleteFlag`, `$password`, and `$step3Flatten` variables at the top of the file before running.

## Required Tools

Both tools must be installed at their default paths:

| Tool | Expected path |
|------|--------------|
| WinRAR | `%ProgramFiles%\WinRAR\WinRAR.exe` |
| 7-Zip-Zstandard | `%ProgramFiles%\7-Zip-Zstandard\7z.exe` |

7-Zip-Zstandard (not standard 7-Zip) is required for zstd-compressed archives.

## Architecture

All scripts follow the same mental model:

1. **Stage 0 — Unmask**: Rename `.mp4` → `.zip`, then extract with WinRAR into `output0/`
2. **Stage 1+ — Unwrap**: Re-extract archives inside `output0/` (and optionally `output1/`) into `output/` using 7z
3. **Cleanup**: Delete intermediate dirs and empty folders

The pipeline depth and smart-extract behaviour varies by script:

| Script | Pipeline | Tool for stage 0 | Tool for stage 1+ | Smart extract | Multi-format |
|--------|----------|------------------|-------------------|---------------|-------------|
| `yejiang.ps1` | mp4 → output0 → output | WinRAR | WinRAR | No | zip/7z |
| `yejiang_split_steps_step3_mode.ps1` | same, adds `$step3Flatten` toggle | WinRAR | WinRAR | No | zip/7z |
| `PADIO.ps1` | mp4 → output0 → output | WinRAR | 7z | Yes¹ | zip/7z |
| `DORO.ps1` | mp4 → output0 → output1 → output | WinRAR | 7z | Yes¹ | zip/7z |
| `DORO_PADIO.ps1` | classified mp4/archive → output0/name → output (PADIO) or output1/name/archive → output (DORO) | WinRAR | 7z | Yes¹ | zip/7z/rar/all splits |
| `c291dGhwbHVz.ps1` | direct to output (no output0 step) | — | 7z | No | zip/7z/zip-splits |
| `yecgaa_fixed.ps1` | mp4 → output0 → output | WinRAR | 7z | No | zip/7z/rar/all splits |
| `FLYYZ_fixed.ps1` | mp4 → output0 → output | WinRAR | 7z | No | zip/7z/rar/all splits |

¹ **Smart extract**: uses `7z l -slt` to inspect whether the archive's root level already contains a folder. If yes, extracts directly into `output/`; if no, creates a same-name subdirectory to avoid file scattering.

## Key Implementation Patterns

**Archive entrypoint detection** (`Get-ArchiveEntrypoints` in `yecgaa_fixed.ps1` / `FLYYZ_fixed.ps1`): scans all files once and classifies them as `zip`, `7z`, `zip-z` (PKZIP split via `.z01`), `zip-001`, `7z-001`, `rar`, `rar-part`, or `rar-r00`. Only the first volume of each split set is emitted.

**DORO/PADIO classifier** (`DORO_PADIO.ps1`): initial files are classified before extraction. Names containing `doro` use password `doro` and the three-stage DORO pipeline. Four-digit base names such as `1772.mp4` use password `PADIO294` and the two-stage PADIO pipeline. Unknown names open an arrow-key menu so the user can choose DORO, PADIO, or Skip; manual choices made before `.mp4` → `.zip` are cached for the renamed archive so the script does not ask twice.

**Intermediate directory isolation** (`DORO_PADIO.ps1`): intermediate extractions never flatten into `output0/` or `output1/`. Stage 0 extracts to `output0/<entry-name>/`; the DORO middle layer extracts each archive to `output1/<entry-name>/<archive-name>/`. The final layer is the only layer that uses smart extract into `output/`.

**Conflict handling** (`DORO_PADIO.ps1`): every extraction goes through a preflight wrapper. Existing isolated target directories get a `__2`, `__3`, ... suffix; final smart-extract conflicts in `output/` rename the existing top-level file or folder to `__existing_2`, `__existing_3`, ... before extraction. 7z uses `-aot` and WinRAR uses `-or` as a second guard against accidental overwrite.

**Multi-pass extraction** (`Process-Archives`): loops up to 10 passes so that archives nested inside archives are fully expanded without manual intervention.

**Path safety**: use `-LiteralPath` everywhere (never `-Path` with user-provided values) to handle archive names containing `[`, `]`, and other glob metacharacters. Directory creation uses `[System.IO.Directory]::CreateDirectory()` for the same reason.

**Passwords** are hardcoded per script: `yejiang`, `doro`, `PADIO294`, `c291dGhwbHVz`, `yecgaa`, `FLYYZ`. When creating a new script for a new source, copy `FLYYZ_fixed.ps1` (the most capable template) and change only `$Password` and the display name in the header.

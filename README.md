# 📦 解压脚本集

> 🎬 一组 PowerShell 脚本，专治「伪装成 `.mp4` 的密码保护压缩包」。

这类文件由 SteganographierGUI 之类的工具生成：外层是一段封面视频字节，其后偷偷附加了真正的 ZIP 数据；ZIP 里往往还层层套娃，套着一到多层带密码的压缩包（zip / 7z / rar 及各种分卷）。这些脚本把「去伪装 → 逐层解包 → 落位 → 清理」一条龙全自动化，并按来源预置好对应密码。✨

所有脚本共用同一套 **🗜️ 基于 WinRAR** 的解压引擎，彼此只在「密码、管线层数、最终落位方式」上有差别。

## 🛠️ 环境要求

| 工具 | 期望路径 |
|------|----------|
| WinRAR | `%ProgramFiles%\WinRAR\WinRAR.exe` |
| PowerShell | 7+（`pwsh`）；也兼容 Windows PowerShell 5.1 |

✅ **只用 WinRAR，全程不碰 7-Zip。** 每一层解压都走 WinRAR。这对本仓库处理的压缩包是安全的——它们都不使用 7-Zip-Zstandard 独有的压缩算法（如 zstd）。万一将来某个来源用到了，WinRAR 会解压失败、整条链被判为失败（乖乖保留源文件），而不是被静默误处理。

> ⚠️ 脚本本身保存为 **UTF-8 with BOM**。少了 BOM，PowerShell 5.1 会把中文按 GBK 读取并喜提乱码。

## 🚀 快速开始

把 `.mp4` / 压缩包文件丢到脚本所在目录，然后执行：

```powershell
# 默认：工作目录 = 脚本所在目录，整条解压链成功后删除源文件
.\FLYYZ_fixed.ps1

# 保留所有源文件，并指定自定义工作目录
.\FLYYZ_fixed.ps1 -WorkDir "D:\downloads\FLYYZ" -KeepFiles

# DORO / PADIO 混合批量：先按文件名自动分类，再分别解压
.\DORO_PADIO.ps1

# 统一菜单：方向键交互选择来源，再跑对应管线
.\extract.ps1
```

## 📜 脚本一览

| 脚本 | 🔑 密码 | 层数 | 管线 | 📤 最终落位 |
|------|------|:----:|------|----------|
| `PADIO.ps1` | `PADIO294` | 2 | mp4 → output0 → output | 🧠 智能落位 |
| `FLYYZ_fixed.ps1` | `FLYYZ` | 2 | mp4 → output0 → output | 🧠 智能落位 |
| `yecgaa_fixed.ps1` | `yecgaa` | 2 | mp4 → output0 → output | 🧠 智能落位 |
| `yejiang.ps1` | `yejiang` | 2 | mp4 → output0 → output | 🧠 智能落位 |
| `DORO.ps1` | `doro` | 3 | mp4 → output0 → output1 → output | 🧠 智能落位 |
| `DORO_PADIO.ps1` | `doro` / `PADIO294` | 2/3 | 按文件名分类后走 PADIO 或 DORO 管线 | 🧠 智能落位 |
| `FLYYZ_yecgaa.ps1` | `FLYYZ` / `yecgaa` | 2 | 逐个手动分类，改名 F_xx / Y_xx → output0\来源 → output\编号名 | 🔢 编号目录 |
| `c291dGhwbHVz.ps1` | `c291dGhwbHVz` | 1 | 直接解压到 output（按相对路径，不改名 mp4） | 🗂️ 结构保留 |
| `yejiang_split_steps_step3_mode.ps1` | `yejiang` | 2 | mp4 → output0 → output | 🗂️ 结构保留 / 扁平化 |
| `extract.ps1` | 见菜单 | 1–3 | 统一菜单分发到各管线 | 视所选管线而定 |

📦 所有脚本都支持 zip / 7z / rar 以及各类分卷（`.z01`、`.001`、`.partN.rar`、`.r00` 等）。

## ⚙️ 参数与配置

除 `yejiang_split_steps_step3_mode.ps1` 外，每个脚本都是参数式的：

- `-WorkDir <路径>`：工作目录，默认是脚本所在目录。
- `-KeepFiles`：保留所有源文件（默认整条链成功后删除源压缩包）。
- `-Password <密码>`：覆盖默认密码（仅单来源脚本支持）。

🔧 `yejiang_split_steps_step3_mode.ps1` 是唯一的例外——运行前请编辑文件顶部的变量：

- `$deleteFlag`（默认 `$true`）：是否在成功后删除源文件。
- `$password`（默认 `"yejiang"`）。
- `$step3Flatten`（默认 `$false`）：`$true` 时把最终内容全部扁平化到 `output\`，否则保留目录结构。

### 🎛️ 统一菜单 `extract.ps1`

把整套引擎包在一个方向键菜单后面，选好来源即套用对应密码并分发到四类管线之一：

- `standard`（层数 2）：PADIO / FLYYZ / yecgaa
- `three-stage`（层数 3）：DORO
- `direct`（层数 1）：c291
- `yejiang`：子菜单——`simple`（深度 2 智能落位）/ `split-structured`（结构保留）/ `split-flatten`（扁平化到 `output\`）

🧹 `doro` 来源还会顺手清理 `好用的VPN和AI茶馆.txt` 之类的垃圾文件。

## 🔍 工作原理

每个脚本都遵循同一套心智模型：

1. **🎭 阶段 0 — 去伪装**（`direct` 管线跳过）：把 `.mp4` 改名为 `.zip`，用 WinRAR 解压到隔离的 `output0\<条目名>\`。
2. **🪆 阶段 1+ — 逐层解包**：对上一层目录里发现的压缩包再次解压。每个脚本层数固定（1 / 2 / 3），没有开放式多轮循环。
3. **📤 最终落位**：最后一层把内容放进 `output\`（智能落位或结构保留，按脚本而定）。
4. **🧹 链式清理**：只有当某个源的整条链全部成功后，才删除它的压缩包；随后清理空的中间目录。

### 🧪 关键设计

- 🛡️ **空解压防护**：WinRAR 的退出码只对「数据加密」的压缩包可靠（密码错 → 7z 退 3、zip 退 10）。但对**头部加密的 7z**（`-mhe=on`），密码错时 WinRAR 会**退出 0 却什么都没解出来**——只看退出码就会误报成功并删除源文件 💥。因此引擎额外要求：一次成功的解压必须在其（全新隔离的）目标目录里产出至少一个文件；「退出 0 但零文件」一律判为失败。这是早期「错密码内层包仍报成功、源文件被删」数据丢失 bug 的根因修复。

- 🔗 **链式清理（chain-scoped cleanup）**：绝不在单步解压成功后就急着删源文件。每个初始源都带一条清理链，记录其改名后的源压缩包与由它衍生的全部中间/最终压缩包，只有整条链所需的各阶段都成功才删除；失败的链会保留源文件和中间压缩包以便排查。在层数 3 的管线里，中间层失败会直接跳过最终层。

- 🧩 **智能落位**（`Expand-ArchiveSmartFinal`）：WinRAR 无法把压缩包内容列到标准输出，于是先把它解压进 `output\` 下的隔离临时目录再检查结构——若顶层至少含一个文件夹，就把每个顶层条目直接移入 `output\`；若顶层全是散落文件，则把临时目录改名为同名子目录，避免文件散落一地。

- ⏯️ **断点续传**：若上次运行已完成阶段 0、之后才失败，重跑时会扫描仍含压缩包的 `output0\<条目名>\` 目录并作为阶段 0 任务续跑，免去手动恢复已删除源 `.zip` 的麻烦。

- 🔒 **路径安全 & 不覆盖**：全程使用 `-LiteralPath`，正确处理含 `[` `]`、中文、空格等字符的文件名；目标目录冲突时加 `__2`/`__3` 后缀，落位冲突时把既有项改名为 `__existing_2` 等再移入；WinRAR 以 `-or` 调用作为第二道保险。

## 🔑 密码说明

各脚本按来源在顶部硬编码了密码：`yejiang`、`doro`、`PADIO294`、`c291dGhwbHVz`、`yecgaa`、`FLYYZ`。这些是用于解开第三方资源的固定口令，明文存放属设计取舍。⚠️ 本仓库为公开仓库，上述密码随源码一并公开。

🧬 新增来源时，复制 `FLYYZ_fixed.ps1`（标准的深度 2 模板：WinRAR-only、智能落位、空解压防护、链式删除），只改 `$Password` 和头部显示名即可。

---

<details>
<summary>🌐 <b>English version (click to expand)</b></summary>

<br>

# 📦 Archive Extraction Scripts

> 🎬 A set of PowerShell scripts that tackle **password-protected archives disguised as `.mp4` files**.

These files are produced by tools like SteganographierGUI: a cover-video byte stream up front, with the real ZIP data quietly appended behind it — and the ZIP usually nests one or more password-protected archives inside (zip / 7z / rar and all kinds of split volumes). These scripts automate the whole **unmask → unwrap → place → clean up** pipeline, with the right password preset per source. ✨

Every script shares one **🗜️ WinRAR-based** extraction engine; they differ only in password, pipeline depth, and final-placement behaviour.

## 🛠️ Requirements

| Tool | Expected path |
|------|---------------|
| WinRAR | `%ProgramFiles%\WinRAR\WinRAR.exe` |
| PowerShell | 7+ (`pwsh`); also works under Windows PowerShell 5.1 |

✅ **WinRAR only — never 7-Zip.** Every stage extracts with WinRAR. This is safe for the archives in this repo: none of them use 7-Zip-Zstandard-only compression methods (e.g. zstd). If a future source ever does, WinRAR will fail and the whole chain is reported as failed (source files kept), rather than being silently mishandled.

> ⚠️ The scripts themselves are saved as **UTF-8 with BOM**. Without the BOM, PowerShell 5.1 reads the CJK text as GBK and corrupts it.

## 🚀 Quick Start

Drop the `.mp4` / archive files into the script's directory, then run:

```powershell
# Default: WorkDir = script location, deletes source files after a chain fully succeeds
.\FLYYZ_fixed.ps1

# Keep all source files, specify a custom work directory
.\FLYYZ_fixed.ps1 -WorkDir "D:\downloads\FLYYZ" -KeepFiles

# Mixed DORO/PADIO batch: auto-classifies by file name before extracting
.\DORO_PADIO.ps1

# Unified menu: pick the source interactively, then run the matching pipeline
.\extract.ps1
```

## 📜 Scripts at a Glance

| Script | 🔑 Password | Depth | Pipeline | 📤 Final placement |
|------|------|:----:|------|----------|
| `PADIO.ps1` | `PADIO294` | 2 | mp4 → output0 → output | 🧠 smart |
| `FLYYZ_fixed.ps1` | `FLYYZ` | 2 | mp4 → output0 → output | 🧠 smart |
| `yecgaa_fixed.ps1` | `yecgaa` | 2 | mp4 → output0 → output | 🧠 smart |
| `yejiang.ps1` | `yejiang` | 2 | mp4 → output0 → output | 🧠 smart |
| `DORO.ps1` | `doro` | 3 | mp4 → output0 → output1 → output | 🧠 smart |
| `DORO_PADIO.ps1` | `doro` / `PADIO294` | 2/3 | classified into the PADIO or DORO pipeline | 🧠 smart |
| `FLYYZ_yecgaa.ps1` | `FLYYZ` / `yecgaa` | 2 | per-file manual classify, renamed F_xx / Y_xx → output0\source → output\number | 🔢 numbered dir |
| `c291dGhwbHVz.ps1` | `c291dGhwbHVz` | 1 | direct to output (by relative path, no mp4 rename) | 🗂️ structure-preserving |
| `yejiang_split_steps_step3_mode.ps1` | `yejiang` | 2 | mp4 → output0 → output | 🗂️ structure-preserving / flatten |
| `extract.ps1` | see menu | 1–3 | unified menu dispatching to each pipeline | depends on chosen pipeline |

📦 Every script supports zip / 7z / rar and all kinds of split sets (`.z01`, `.001`, `.partN.rar`, `.r00`, etc.).

## ⚙️ Parameters & Config

Except for `yejiang_split_steps_step3_mode.ps1`, every script is parameter-based:

- `-WorkDir <path>`: work directory, defaults to the script's location.
- `-KeepFiles`: keep all source files (by default source archives are deleted after a chain fully succeeds).
- `-Password <pw>`: override the default password (single-source scripts only).

🔧 `yejiang_split_steps_step3_mode.ps1` is the one exception — edit the variables at the top of the file before running:

- `$deleteFlag` (default `$true`): whether to delete source files on success.
- `$password` (default `"yejiang"`).
- `$step3Flatten` (default `$false`): when `$true`, flatten all final content into `output\`; otherwise keep the directory structure.

### 🎛️ Unified menu `extract.ps1`

Wraps the whole engine behind an arrow-key menu; pick a source and it applies the matching password and dispatches to one of four pipelines:

- `standard` (depth 2): PADIO / FLYYZ / yecgaa
- `three-stage` (depth 3): DORO
- `direct` (depth 1): c291
- `yejiang`: a sub-menu — `simple` (depth-2 smart) / `split-structured` (structure-preserving) / `split-flatten` (flatten into `output\`)

🧹 The `doro` source also cleans up junk files like `好用的VPN和AI茶馆.txt`.

## 🔍 How It Works

Every script follows the same mental model:

1. **🎭 Stage 0 — Unmask** (skipped by the `direct` pipeline): rename `.mp4` → `.zip`, extract with WinRAR into an isolated `output0\<entry-name>\`.
2. **🪆 Stage 1+ — Unwrap**: re-extract the archives found in the previous stage's directory. Each script has a fixed depth (1 / 2 / 3); there is no open-ended multi-pass loop.
3. **📤 Final placement**: the last layer places content into `output\` (smart or structure-preserving, per script).
4. **🧹 Chain-scoped cleanup**: a source's archives are deleted only after its whole chain succeeds; then empty intermediate dirs are removed.

### 🧪 Key Design

- 🛡️ **Empty-extraction guard**: WinRAR's exit code is only reliable for *data*-encrypted archives (wrong password → 7z exits 3, zip exits 10). But for a **header-encrypted 7z** (`-mhe=on`), a wrong password makes WinRAR **exit 0 while extracting nothing** — trusting the exit code alone reports false success and deletes the source 💥. So the engine also requires that a successful extraction produced at least one item in its (freshly isolated) target dir; "exit 0 but zero items" is treated as failure. This is the root-cause fix for the earlier data-loss bug.

- 🔗 **Chain-scoped cleanup**: never delete source archives right after one step succeeds. Each initial source carries a cleanup chain tracking its renamed source archive plus every intermediate/final archive derived from it; it is deleted only after all required stages succeed. Failed chains keep their source and intermediate archives for debugging. In the depth-3 pipeline, a failed middle layer skips the final layer entirely.

- 🧩 **Smart placement** (`Expand-ArchiveSmartFinal`): WinRAR can't list an archive's contents to stdout, so it extracts into an isolated temp dir under `output\` first and inspects the structure — if the top level has at least one folder, each top-level item is moved into `output\`; if it's all loose files, the temp dir is renamed to a same-name subdirectory to avoid scattering files.

- ⏯️ **Resume**: if a prior run finished stage 0 and only failed later, a rerun scans `output0\<entry-name>\` dirs that still contain archives and resumes them as stage-0 jobs — no need to manually restore already-deleted source `.zip` files.

- 🔒 **Path safety & no overwrite**: `-LiteralPath` everywhere to handle names with `[` `]`, CJK, spaces, etc.; target-dir conflicts get a `__2`/`__3` suffix, placement conflicts rename the existing item to `__existing_2` etc. before moving the new one in; WinRAR is invoked with `-or` as a second guard.

## 🔑 Passwords

Passwords are hardcoded per source at the top of each script: `yejiang`, `doro`, `PADIO294`, `c291dGhwbHVz`, `yecgaa`, `FLYYZ`. These are fixed credentials for unlocking third-party resources; plaintext storage is a deliberate trade-off. ⚠️ This is a public repository, so the passwords above are published along with the source.

🧬 To add a new source, copy `FLYYZ_fixed.ps1` (the canonical depth-2 template: WinRAR-only, smart placement, empty-guard, chain-scoped deletion) and change only `$Password` and the display name in the header.

</details>

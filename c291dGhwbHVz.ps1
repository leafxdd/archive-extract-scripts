#Requires -Version 5.1
<#
.SYNOPSIS
    c291dGhwbHVz 压缩包处理脚本（全 WinRAR 版）
.DESCRIPTION
    查找并解压 .zip / .z01 / .7z / .7z.001 / .rar / 各类分卷到 output，保持相对路径结构。
    单层管线：每个入口先解到隔离临时目录（带解压校验），成功后再并入 output\<相对路径>\，
    冲突自动改名，绝不覆盖；只有该入口解压成功后才删除其源文件。
.NOTES
    全部解压均使用 WinRAR，不再依赖 7-Zip。
    退出码 0 但未解出任何内容（头加密 7z 遇错误密码的典型表现）一律按失败处理，避免误删。
#>

param(
    [string]$WorkDir = $PSScriptRoot,
    [string]$Password = "c291dGhwbHVz",
    [switch]$KeepFiles = $false
)

# 规范化 WorkDir（避免通配符/相对路径导致的 Get-ChildItem 过滤异常）
try {
    $WorkDir = (Get-Item -LiteralPath $WorkDir -ErrorAction Stop).FullName
} catch {
    Write-Host "错误: WorkDir 不存在或不可访问: $WorkDir" -ForegroundColor Red
    Read-Host "按回车键退出"
    exit 1
}

# ==================== 初始化 ====================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

$WinRarExe = Join-Path $env:ProgramFiles "WinRAR\WinRAR.exe"
$DeleteFlag = -not $KeepFiles
$Output = Join-Path $WorkDir "output"

# ==================== 基础工具函数 ====================
function New-DirectoryIfMissing {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        [System.IO.Directory]::CreateDirectory($Path) | Out-Null
    }
}

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    try { return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\', '/') }
    catch { return $Path.TrimEnd('\', '/') }
}

function Test-IsUnderPath {
    param(
        [Parameter(Mandatory)][string]$ChildPath,
        [Parameter(Mandatory)][string]$ParentPath
    )
    $child = Get-NormalizedPath $ChildPath
    $parent = Get-NormalizedPath $ParentPath
    return ($child -ieq $parent) -or ($child.StartsWith($parent + '\', [System.StringComparison]::OrdinalIgnoreCase))
}

function Get-RelativeDirectory {
    param(
        [Parameter(Mandatory)][string]$RootDir,
        [Parameter(Mandatory)][string]$ChildDir
    )
    $root = Get-NormalizedPath $RootDir
    $child = Get-NormalizedPath $ChildDir
    if ($child -ieq $root) { return "" }
    if ($child.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $child.Substring($root.Length + 1).Trim('\')
    }
    return ""
}

function Get-SafeFolderName {
    param([Parameter(Mandatory)][string]$Name)
    $safe = $Name -replace '[<>:"/\\|?*\x00-\x1F]', '_'
    $safe = $safe.Trim().TrimEnd('.', ' ')
    if ([string]::IsNullOrWhiteSpace($safe)) { return "archive" }
    return $safe
}

function Get-UniqueDirectoryPath {
    param([Parameter(Mandatory)][string]$DirectoryPath)
    if (-not (Test-Path -LiteralPath $DirectoryPath)) { return $DirectoryPath }
    $item = Get-Item -LiteralPath $DirectoryPath -Force -ErrorAction SilentlyContinue
    if ($item -is [System.IO.DirectoryInfo]) {
        $children = @(Get-ChildItem -LiteralPath $DirectoryPath -Force -ErrorAction SilentlyContinue)
        if ($children.Count -eq 0) { return $DirectoryPath }
    }
    $parent = Split-Path -Parent $DirectoryPath
    $leaf = Split-Path -Leaf $DirectoryPath
    for ($i = 2; $i -lt 10000; $i++) {
        $candidate = Join-Path $parent ("{0}__{1}" -f $leaf, $i)
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw "无法为目录生成唯一名称: $DirectoryPath"
}

function Move-ExistingPathAside {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $parent = if ($item -is [System.IO.DirectoryInfo]) { $item.Parent.FullName } else { $item.DirectoryName }
    $leaf = $item.Name
    $stem = if ($item -is [System.IO.DirectoryInfo]) { $leaf } else { [System.IO.Path]::GetFileNameWithoutExtension($leaf) }
    $ext = if ($item -is [System.IO.DirectoryInfo]) { "" } else { [System.IO.Path]::GetExtension($leaf) }
    for ($i = 2; $i -lt 10000; $i++) {
        $newLeaf = if ($item -is [System.IO.DirectoryInfo]) { "{0}__existing_{1}" -f $stem, $i } else { "{0}__existing_{1}{2}" -f $stem, $i, $ext }
        $candidate = Join-Path $parent $newLeaf
        if (-not (Test-Path -LiteralPath $candidate)) {
            Move-Item -LiteralPath $item.FullName -Destination $candidate -ErrorAction Stop
            Write-Host "  [RENAME] 目标冲突，已改名: $leaf -> $newLeaf" -ForegroundColor Yellow
            return $candidate
        }
    }
    throw "无法为冲突项生成唯一名称: $Path"
}

function Get-EntryLabel {
    param([Parameter(Mandatory)][pscustomobject]$Entry)
    switch ($Entry.Type) {
        'zip-z'    { return 'zip分卷(z01)' }
        'zip-z01'  { return 'zip分卷(z01入口)' }
        'zip-001'  { return 'zip分卷(001)' }
        '7z-001'   { return '7z分卷' }
        'rar-part' { return 'rar分卷(part1)' }
        'rar-r00'  { return 'rar分卷(r00)' }
        default    { return $Entry.Type }
    }
}

# ==================== 压缩包入口检测 ====================
# 剪枝枚举：递归列出 RootDir 下所有文件；位于 ExcludeDirs 内的目录整棵跳过（不进入）。
# 与"全量枚举后逐文件过滤"产出相同集合，但被排除子树（如积累大量产物的 output\）完全不被遍历。
function Get-FilesWithPrunedDirs {
    param(
        [Parameter(Mandatory)][string]$RootDir,
        [string[]]$ExcludeDirs = @()
    )

    $excludeNorm = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ex in $ExcludeDirs) {
        if ($ex) { [void]$excludeNorm.Add((Get-NormalizedPath $ex)) }
    }

    if ($excludeNorm.Count -eq 0) {
        return @(Get-ChildItem -LiteralPath $RootDir -Recurse -File -Force -ErrorAction SilentlyContinue)
    }

    $files = New-Object 'System.Collections.Generic.List[object]'
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($RootDir)
    while ($queue.Count -gt 0) {
        $dir = $queue.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            if ($item.PSIsContainer) {
                # reparse point（junction/符号链接）不进入：防循环，与 pwsh7 -Recurse 默认行为一致
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                if (-not $excludeNorm.Contains((Get-NormalizedPath -Path $item.FullName))) { $queue.Enqueue($item.FullName) }
            } else {
                $files.Add($item)
            }
        }
    }
    return $files.ToArray()
}

function Get-ArchiveEntrypoints {
    param(
        [Parameter(Mandatory)][string]$RootDir,
        [string[]]$ExcludeDirs = @()
    )

    $allFiles = @(Get-FilesWithPrunedDirs -RootDir $RootDir -ExcludeDirs $ExcludeDirs)
    if ($allFiles.Count -eq 0) { return @() }

    $entries = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($file in $allFiles) {
        $name = $file.Name
        $full = $file.FullName

        if ($file.Extension -ieq '.rar') {
            if ($name -match '^(?<stem>.+?)\.part(?<part>\d+)\.rar$') {
                $partNum = 0
                [void][int]::TryParse($Matches.part, [ref]$partNum)
                if ($partNum -ne 1) { continue }
                if ($seen.Add($full)) { $entries.Add([pscustomobject]@{ Path = $full; Type = 'rar-part'; Dir = $file.DirectoryName; Base = $Matches.stem }) }
                continue
            }
            $r00 = Join-Path $file.DirectoryName ($file.BaseName + '.r00')
            $type = if (Test-Path -LiteralPath $r00) { 'rar-r00' } else { 'rar' }
            if ($seen.Add($full)) { $entries.Add([pscustomobject]@{ Path = $full; Type = $type; Dir = $file.DirectoryName; Base = $file.BaseName }) }
            continue
        }

        if ($file.Extension -ieq '.zip' -or $file.Extension -ieq '.7z') {
            $isZipSplitZ = $false
            if ($file.Extension -ieq '.zip') {
                $z01 = Join-Path $file.DirectoryName ($file.BaseName + '.z01')
                $isZipSplitZ = Test-Path -LiteralPath $z01
            }
            $type = if ($isZipSplitZ) { 'zip-z' } else { $file.Extension.TrimStart('.') }
            if ($seen.Add($full)) { $entries.Add([pscustomobject]@{ Path = $full; Type = $type; Dir = $file.DirectoryName; Base = $file.BaseName }) }
            continue
        }

        if ($name -match '^(?<stem>.+?)\.(?<fmt>7z|zip)\.(?<part>\d+)$') {
            $partNum = 0
            [void][int]::TryParse($Matches.part, [ref]$partNum)
            if ($partNum -ne 1) { continue }
            $fmt = $Matches.fmt.ToLowerInvariant()
            $type = "$fmt-001"
            if ($seen.Add($full)) { $entries.Add([pscustomobject]@{ Path = $full; Type = $type; Dir = $file.DirectoryName; Base = $Matches.stem }) }
            continue
        }

        if ($name -match '^(?<stem>.+?)\.z(?<part>\d+)$') {
            $partNum = 0
            [void][int]::TryParse($Matches.part, [ref]$partNum)
            if ($partNum -ne 1) { continue }
            $zipCandidate = Join-Path $file.DirectoryName ($Matches.stem + '.zip')
            if (Test-Path -LiteralPath $zipCandidate) {
                if ($seen.Add($zipCandidate)) { $entries.Add([pscustomobject]@{ Path = $zipCandidate; Type = 'zip-z'; Dir = $file.DirectoryName; Base = $Matches.stem }) }
            } else {
                if ($seen.Add($full)) { $entries.Add([pscustomobject]@{ Path = $full; Type = 'zip-z01'; Dir = $file.DirectoryName; Base = $Matches.stem }) }
            }
            continue
        }
    }

    return $entries.ToArray()
}

function Remove-ArchiveGroup {
    param([Parameter(Mandatory)][pscustomobject]$Entry)
    try {
        switch -Regex ($Entry.Type) {
            '^zip-z$' {
                $dir = $Entry.Dir; $base = [regex]::Escape($Entry.Base)
                Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^$base\.z\d+$" } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
                Remove-Item -LiteralPath $Entry.Path -Force -ErrorAction SilentlyContinue
            }
            '^zip-z01$' {
                $dir = $Entry.Dir; $base = [regex]::Escape($Entry.Base)
                Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^$base\.z\d+$" } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
                $zipPath = Join-Path $dir ($Entry.Base + '.zip')
                if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath $Entry.Path) { Remove-Item -LiteralPath $Entry.Path -Force -ErrorAction SilentlyContinue }
            }
            '^(zip|7z)-001$' {
                $dir = $Entry.Dir; $stemEsc = [regex]::Escape($Entry.Base); $fmt = ($Entry.Type -split '-')[0]
                Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^$stemEsc\.$fmt\.\d+$" } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
            }
            '^rar-part$' {
                $dir = $Entry.Dir; $stemEsc = [regex]::Escape($Entry.Base)
                Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^$stemEsc\.part\d+\.rar$" } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
            }
            '^rar-r00$' {
                $dir = $Entry.Dir; $stemEsc = [regex]::Escape($Entry.Base)
                Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^$stemEsc\.r\d\d$" } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
                $rarPath = Join-Path $dir ($Entry.Base + '.rar')
                if (Test-Path -LiteralPath $rarPath) { Remove-Item -LiteralPath $rarPath -Force -ErrorAction SilentlyContinue }
            }
            default {
                Remove-Item -LiteralPath $Entry.Path -Force -ErrorAction SilentlyContinue
            }
        }
        return $true
    } catch {
        Write-Host "  [WARN] 删除源压缩包失败: $_" -ForegroundColor Yellow
        return $false
    }
}

# ==================== 解压（全部使用 WinRAR）====================
function Invoke-WinRARExtract {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$TargetDir,
        [Parameter(Mandatory)][string]$ArchiveKey
    )

    New-DirectoryIfMissing -Path $TargetDir
    $proc = Start-Process -FilePath $WinRarExe -ArgumentList @(
        'x',
        "-p$ArchiveKey",
        '-ibck',
        '-inul',
        '-y',
        '-or',
        "`"$ArchivePath`"",
        "`"$TargetDir\`""
    ) -Wait -PassThru -NoNewWindow

    if ($null -eq $proc -or $proc.ExitCode -ne 0) { return $false }

    # 头加密 7z 遇错误密码时退出码仍为 0 却什么都不解；追加校验避免误判成功而误删。
    $extracted = @(Get-ChildItem -LiteralPath $TargetDir -Force -ErrorAction SilentlyContinue)
    if ($extracted.Count -eq 0) {
        Write-Host "  [FAIL] 退出码 0 但未解出任何文件（疑似密码错误或头加密包无法读取）" -ForegroundColor Red
        return $false
    }
    return $true
}

# 直接解压：先解到隔离临时目录（带校验），成功后并入 output\<相对路径>\，保持相对结构，冲突改名不覆盖
function Expand-ArchiveDirect {
    param(
        [Parameter(Mandatory)][pscustomobject]$Entry,
        [Parameter(Mandatory)][string]$TargetDir,
        [Parameter(Mandatory)][string]$ArchiveKey
    )

    New-DirectoryIfMissing -Path $TargetDir
    $tmp = Get-UniqueDirectoryPath -DirectoryPath (Join-Path $TargetDir (".__unpack_" + (Get-SafeFolderName -Name $Entry.Base)))
    New-DirectoryIfMissing -Path $tmp

    Write-Host "[EXTRACT] ($(Get-EntryLabel -Entry $Entry)) $(Split-Path -Leaf $Entry.Path) -> $TargetDir" -ForegroundColor Yellow
    $success = Invoke-WinRARExtract -ArchivePath $Entry.Path -TargetDir $tmp -ArchiveKey $ArchiveKey

    if (-not $success) {
        if (Test-Path -LiteralPath $tmp) {
            $leftover = @(Get-ChildItem -LiteralPath $tmp -Force -ErrorAction SilentlyContinue)
            if ($leftover.Count -eq 0) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            else { Write-Host "  [KEEP] 解压失败，保留临时目录: $(Split-Path -Leaf $tmp)" -ForegroundColor Yellow }
        }
        return $false
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $tmp -Force -ErrorAction SilentlyContinue)) {
        $dest = Join-Path $TargetDir $item.Name
        if (Test-Path -LiteralPath $dest) { [void](Move-ExistingPathAside -Path $dest) }
        Move-Item -LiteralPath $item.FullName -Destination $dest -ErrorAction Stop
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return $true
}

function Remove-EmptyDirs {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$ProtectDirs = @()
    )

    $protectNorm = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $ProtectDirs) {
        if ($p) { [void]$protectNorm.Add((Get-NormalizedPath $p)) }
    }

    # 收集时即跳过受保护子树与 reparse point，不再全量枚举后过滤
    $allDirs = New-Object 'System.Collections.Generic.List[object]'
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        $dir = $queue.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($protectNorm.Contains((Get-NormalizedPath -Path $item.FullName))) { continue }
            $allDirs.Add($item.FullName)
            $queue.Enqueue($item.FullName)
        }
    }

    # 从深到浅删除：子目录删空后父目录才会显空
    $sorted = @($allDirs.ToArray() | Sort-Object { $_.Split('\').Count } -Descending)

    $count = 0
    foreach ($dir in $sorted) {
        $isEmpty = $false
        # 判空取首项短路即可；枚举器必须及时释放，否则目录句柄会挡住随后的删除
        $enum = $null
        try {
            $enum = [System.IO.Directory]::EnumerateFileSystemEntries($dir).GetEnumerator()
            $isEmpty = -not $enum.MoveNext()
        } catch {
        } finally {
            if ($null -ne $enum) { $enum.Dispose() }
        }
        if ($isEmpty) {
            try { Remove-Item -LiteralPath $dir -Force -ErrorAction Stop; $count++ } catch { }
        }
    }
    if ($count -gt 0) { Write-Host "  [OK] 清理了 $count 个空文件夹" -ForegroundColor Green }
}

# ==================== 主流程 ====================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "c291dGhwbHVz 压缩包处理脚本（WinRAR）" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path -LiteralPath $WinRarExe)) {
    Write-Host "错误: 未找到 WinRAR" -ForegroundColor Red
    Write-Host "路径: $WinRarExe" -ForegroundColor Red
    Read-Host "按回车键退出"
    exit 1
}
Write-Host "[OK] WinRAR: $WinRarExe" -ForegroundColor Green
Write-Host ""

New-DirectoryIfMissing -Path $Output

Write-Host "解压 .zip / .7z / .rar / 各类分卷 -> output（保持相对路径）" -ForegroundColor Yellow
Write-Host "----------------------------------------"
$entries = @(Get-ArchiveEntrypoints -RootDir $WorkDir -ExcludeDirs @($Output))
if ($entries.Count -eq 0) {
    Write-Host "未发现可解压的压缩包" -ForegroundColor Gray
} else {
    foreach ($entry in $entries) {
        $relDir = Get-RelativeDirectory -RootDir $WorkDir -ChildDir $entry.Dir
        $targetDir = if ($relDir) { Join-Path $Output $relDir } else { $Output }

        $success = Expand-ArchiveDirect -Entry $entry -TargetDir $targetDir -ArchiveKey $Password
        if ($success) {
            Write-Host "  [OK] 成功: $(Split-Path -Leaf $entry.Path)" -ForegroundColor Green
            if ($DeleteFlag) {
                if (Remove-ArchiveGroup -Entry $entry) { Write-Host "  [DELETE] 已删除源压缩包/分卷" -ForegroundColor DarkGray }
            }
        } else {
            Write-Host "  [FAIL] 失败（源文件已保留）: $(Split-Path -Leaf $entry.Path)" -ForegroundColor Red
        }
        Write-Host ""
    }
}

if ($DeleteFlag) {
    Write-Host "清理空文件夹..." -ForegroundColor Yellow
    Write-Host "----------------------------------------"
    Remove-EmptyDirs -Root $WorkDir -ProtectDirs @($Output)
} else {
    Write-Host "KeepFiles 模式，跳过删除" -ForegroundColor Gray
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "全部完成" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "按回车键退出"

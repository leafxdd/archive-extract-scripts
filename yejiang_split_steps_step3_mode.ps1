#Requires -Version 5.1
<#
.SYNOPSIS
    yejiang_split_steps_step3_mode.ps1 - 分步解压脚本（全 WinRAR 版，保留目录结构）
.DESCRIPTION
    Step 1: 递归查找脚本目录下的 .mp4（排除 output0/output），重命名为同名 .zip
    Step 2: 每个源压缩包解压到 output0\<相对路径>\<压缩包名>\（保留结构、隔离）
    Step 3: 该源 output0 子树内的压缩包解压到 output（可选 平铺 或 保留目录结构）
    只有整条链（源 + 该源的所有中间/最终压缩包）全部解压成功后，才删除该链的源文件；
    失败链保留源文件与中间产物以便排查。
.NOTES
    - 全部解压均使用 WinRAR，不依赖 7-Zip。
    - 退出码 0 但未解出任何内容（头加密 7z 遇错误密码的典型表现）一律按失败处理，避免误删。
#>

# ==================== 配置区（按需修改）====================
# $true：整条链解压成功后删除源 zip/中间包；$false：保留所有源文件
$deleteFlag = $true

# 压缩包密码
$password = "yejiang"

# Step 3 解压模式：
#   $false：保留相对路径 + 压缩包名目录（保留目录结构）
#   $true ：平铺到 output 根目录（不保留相对路径/压缩包名目录）
$step3Flatten = $false
# ==========================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Output0   = Join-Path $scriptDir "output0"
$Output    = Join-Path $scriptDir "output"

$rarPaths = @(
    "$env:ProgramFiles\WinRAR\WinRAR.exe",
    "${env:ProgramFiles(x86)}\WinRAR\WinRAR.exe"
)
$WinRarExe = $null
foreach ($path in $rarPaths) {
    if (Test-Path -LiteralPath $path) { $WinRarExe = $path; break }
}
if (-not $WinRarExe) {
    Write-Host "[ERROR] 未找到 WinRAR.exe，请先安装 WinRAR。" -ForegroundColor Red
    Write-Host "        默认路径应为：%ProgramFiles%\WinRAR\WinRAR.exe" -ForegroundColor Yellow
    Read-Host "按 Enter 退出"
    exit 1
}
Write-Host "[OK] 找到 WinRAR: $WinRarExe" -ForegroundColor Green
Write-Host ""

# ==================== 基础工具函数 ====================
function New-DirectoryIfMissing {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { [System.IO.Directory]::CreateDirectory($Path) | Out-Null }
}

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    try { return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\', '/') }
    catch { return $Path.TrimEnd('\', '/') }
}

function Test-IsUnderPath {
    param([Parameter(Mandatory)][string]$ChildPath, [Parameter(Mandatory)][string]$ParentPath)
    $child = Get-NormalizedPath $ChildPath
    $parent = Get-NormalizedPath $ParentPath
    return ($child -ieq $parent) -or ($child.StartsWith($parent + '\', [System.StringComparison]::OrdinalIgnoreCase))
}

function Test-IsUnderAnyPath {
    param([Parameter(Mandatory)][string]$ChildPath, [string[]]$ParentPaths = @())
    foreach ($parent in $ParentPaths) {
        if ($parent -and (Test-IsUnderPath -ChildPath $ChildPath -ParentPath $parent)) { return $true }
    }
    return $false
}

function Get-SafeFolderName {
    param([Parameter(Mandatory)][string]$Name)
    $safe = $Name -replace '[<>:"/\\|?*\x00-\x1F]', '_'
    $safe = $safe.Trim().TrimEnd('.', ' ')
    if ([string]::IsNullOrWhiteSpace($safe)) { return "archive" }
    return $safe
}

function Get-RelativeDirectory {
    param([Parameter(Mandatory)][string]$RootDir, [Parameter(Mandatory)][string]$ChildDir)
    $root = Get-NormalizedPath $RootDir
    $child = Get-NormalizedPath $ChildDir
    if ($child -ieq $root) { return "" }
    if ($child.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $child.Substring($root.Length + 1).Trim('\')
    }
    return ""
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

function Get-UniqueFilePath {
    param([Parameter(Mandatory)][string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath)) { return $FilePath }
    $parent = Split-Path -Parent $FilePath
    $leaf = Split-Path -Leaf $FilePath
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
    $ext = [System.IO.Path]::GetExtension($leaf)
    for ($i = 2; $i -lt 10000; $i++) {
        $candidate = Join-Path $parent ("{0}__{1}{2}" -f $stem, $i, $ext)
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw "无法为文件生成唯一名称: $FilePath"
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
function Get-ArchiveEntrypoints {
    param([Parameter(Mandatory)][string]$RootDir, [string[]]$ExcludeDirs = @())

    $excludeNorm = @($ExcludeDirs | ForEach-Object { Get-NormalizedPath $_ })
    $allFiles = @(Get-ChildItem -LiteralPath $RootDir -Recurse -File -Force -ErrorAction SilentlyContinue)
    if ($allFiles.Count -eq 0) { return @() }

    $entries = @()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($file in $allFiles) {
        $skip = $false
        foreach ($ex in $excludeNorm) {
            if ($ex -and (Test-IsUnderPath -ChildPath $file.FullName -ParentPath $ex)) { $skip = $true; break }
        }
        if ($skip) { continue }

        $name = $file.Name
        $full = $file.FullName

        if ($file.Extension -ieq '.rar') {
            if ($name -match '^(?<stem>.+?)\.part(?<part>\d+)\.rar$') {
                $partNum = 0
                [void][int]::TryParse($Matches.part, [ref]$partNum)
                if ($partNum -ne 1) { continue }
                if ($seen.Add($full)) { $entries += [pscustomobject]@{ Path = $full; Type = 'rar-part'; Dir = $file.DirectoryName; Base = $Matches.stem } }
                continue
            }
            $r00 = Join-Path $file.DirectoryName ($file.BaseName + '.r00')
            $type = if (Test-Path -LiteralPath $r00) { 'rar-r00' } else { 'rar' }
            if ($seen.Add($full)) { $entries += [pscustomobject]@{ Path = $full; Type = $type; Dir = $file.DirectoryName; Base = $file.BaseName } }
            continue
        }

        if ($file.Extension -ieq '.zip' -or $file.Extension -ieq '.7z') {
            $isZipSplitZ = $false
            if ($file.Extension -ieq '.zip') {
                $z01 = Join-Path $file.DirectoryName ($file.BaseName + '.z01')
                $isZipSplitZ = Test-Path -LiteralPath $z01
            }
            $type = if ($isZipSplitZ) { 'zip-z' } else { $file.Extension.TrimStart('.') }
            if ($seen.Add($full)) { $entries += [pscustomobject]@{ Path = $full; Type = $type; Dir = $file.DirectoryName; Base = $file.BaseName } }
            continue
        }

        if ($name -match '^(?<stem>.+?)\.(?<fmt>7z|zip)\.(?<part>\d+)$') {
            $partNum = 0
            [void][int]::TryParse($Matches.part, [ref]$partNum)
            if ($partNum -ne 1) { continue }
            $fmt = $Matches.fmt.ToLowerInvariant()
            $type = "$fmt-001"
            if ($seen.Add($full)) { $entries += [pscustomobject]@{ Path = $full; Type = $type; Dir = $file.DirectoryName; Base = $Matches.stem } }
            continue
        }

        if ($name -match '^(?<stem>.+?)\.z(?<part>\d+)$') {
            $partNum = 0
            [void][int]::TryParse($Matches.part, [ref]$partNum)
            if ($partNum -ne 1) { continue }
            $zipCandidate = Join-Path $file.DirectoryName ($Matches.stem + '.zip')
            if (Test-Path -LiteralPath $zipCandidate) {
                if ($seen.Add($zipCandidate)) { $entries += [pscustomobject]@{ Path = $zipCandidate; Type = 'zip-z'; Dir = $file.DirectoryName; Base = $Matches.stem } }
            } else {
                if ($seen.Add($full)) { $entries += [pscustomobject]@{ Path = $full; Type = 'zip-z01'; Dir = $file.DirectoryName; Base = $Matches.stem } }
            }
            continue
        }
    }

    return @($entries)
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
    param([Parameter(Mandatory)][string]$ArchivePath, [Parameter(Mandatory)][string]$TargetDir)

    New-DirectoryIfMissing -Path $TargetDir
    $proc = Start-Process -FilePath $WinRarExe -ArgumentList @(
        'x', "-p$password", '-ibck', '-y', '-or',
        "`"$ArchivePath`"", "`"$TargetDir\`""
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

# 命名解压：解到指定的（唯一化）目标目录，保留目录结构、隔离、不覆盖
function Invoke-NamedExtraction {
    param([Parameter(Mandatory)][pscustomobject]$Entry, [Parameter(Mandatory)][string]$TargetDir)

    $actualTarget = Get-UniqueDirectoryPath -DirectoryPath $TargetDir
    if ($actualTarget -ne $TargetDir) {
        Write-Host "  [RENAME] 目标目录已存在，改用: $(Split-Path -Leaf $actualTarget)" -ForegroundColor Yellow
    }
    New-DirectoryIfMissing -Path $actualTarget
    Write-Host "[EXTRACT] ($(Get-EntryLabel -Entry $Entry)) $(Split-Path -Leaf $Entry.Path) -> $actualTarget" -ForegroundColor Yellow
    $success = Invoke-WinRARExtract -ArchivePath $Entry.Path -TargetDir $actualTarget
    return [pscustomobject]@{ Success = $success; TargetDir = $actualTarget }
}

# 平铺解压：先解到隔离临时目录（带校验），成功后并入 output 根，冲突改名不覆盖
function Expand-ArchiveFlatten {
    param([Parameter(Mandatory)][pscustomobject]$Entry, [Parameter(Mandatory)][string]$OutputDir)

    New-DirectoryIfMissing -Path $OutputDir
    $tmp = Get-UniqueDirectoryPath -DirectoryPath (Join-Path $OutputDir (".__unpack_" + (Get-SafeFolderName -Name $Entry.Base)))
    New-DirectoryIfMissing -Path $tmp
    Write-Host "[EXTRACT] ($(Get-EntryLabel -Entry $Entry)) $(Split-Path -Leaf $Entry.Path) -> $OutputDir (平铺)" -ForegroundColor Yellow
    $success = Invoke-WinRARExtract -ArchivePath $Entry.Path -TargetDir $tmp

    if (-not $success) {
        if (Test-Path -LiteralPath $tmp) {
            $leftover = @(Get-ChildItem -LiteralPath $tmp -Force -ErrorAction SilentlyContinue)
            if ($leftover.Count -eq 0) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            else { Write-Host "  [KEEP] 解压失败，保留临时目录: $(Split-Path -Leaf $tmp)" -ForegroundColor Yellow }
        }
        return $false
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $tmp -Force -ErrorAction SilentlyContinue)) {
        $dest = Join-Path $OutputDir $item.Name
        if (Test-Path -LiteralPath $dest) { [void](Move-ExistingPathAside -Path $dest) }
        Move-Item -LiteralPath $item.FullName -Destination $dest -ErrorAction Stop
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return $true
}

function Remove-EmptyDirs {
    param([Parameter(Mandatory)][string]$Root, [string[]]$ProtectDirs = @())
    $allDirs = @(Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $dir = $_.FullName; -not ($ProtectDirs | Where-Object { Test-IsUnderPath -ChildPath $dir -ParentPath $_ }) } |
        Sort-Object { $_.FullName.Split('\').Count } -Descending)
    $count = 0
    foreach ($dir in $allDirs) {
        $items = @(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue)
        if ($items.Count -eq 0) {
            try { Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop; $count++ } catch { }
        }
    }
    if ($count -gt 0) { Write-Host "  [OK] 清理了 $count 个空文件夹" -ForegroundColor Green }
}

# ==================== 主流程 ====================
New-DirectoryIfMissing -Path $Output0
New-DirectoryIfMissing -Path $Output
$excludeDirs = @($Output0, $Output)

# STEP 1: mp4 -> zip
Write-Host "[STEP 1] 递归查找 .mp4 -> 重命名为 .zip（不在此步解压）" -ForegroundColor Cyan
Write-Host ""
$mp4Files = @(Get-ChildItem -LiteralPath $scriptDir -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -ieq '.mp4' -and -not (Test-IsUnderAnyPath -ChildPath $_.FullName -ParentPaths $excludeDirs) })
foreach ($file in $mp4Files) {
    $desiredZipPath = Join-Path $file.DirectoryName ($file.BaseName + ".zip")
    $zipPath = Get-UniqueFilePath -FilePath $desiredZipPath
    try {
        Rename-Item -LiteralPath $file.FullName -NewName (Split-Path -Leaf $zipPath) -ErrorAction Stop
        Write-Host "[RENAME] $($file.Name) -> $(Split-Path -Leaf $zipPath)" -ForegroundColor Green
    } catch {
        Write-Host "[ERROR] 重命名失败: $($file.FullName) - $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 找出顶层源压缩包入口（排除 output0/output）
$sources = @(Get-ArchiveEntrypoints -RootDir $scriptDir -ExcludeDirs $excludeDirs)
$modeText = if ($step3Flatten) { "平铺到 output 根目录" } else { "保留相对路径+压缩包名目录结构" }

Write-Host ""
Write-Host "[STEP 2/3] 逐链解压（Step3 模式：$modeText）" -ForegroundColor Cyan
Write-Host "----------------------------------------"

$chains = @()
foreach ($source in $sources) {
    $chain = [pscustomobject]@{
        Name           = $source.Base
        Success        = $false
        FailedStage    = ""
        CleanupEntries = @($source)
    }

    # Step 2: 源 -> output0\<相对路径>\<压缩包名>\（隔离）
    $relDir = Get-RelativeDirectory -RootDir $scriptDir -ChildDir $source.Dir
    $stage2Base = if ($relDir) { Join-Path (Join-Path $Output0 $relDir) (Get-SafeFolderName -Name $source.Base) } else { Join-Path $Output0 (Get-SafeFolderName -Name $source.Base) }
    Write-Host "[CHAIN] $($source.Base)" -ForegroundColor Cyan
    $r2 = Invoke-NamedExtraction -Entry $source -TargetDir $stage2Base
    if (-not $r2.Success) {
        $chain.FailedStage = "Step2"
        Write-Host "[CHAIN FAIL] $($source.Base): Step2（源文件保留）" -ForegroundColor Red
        $chains += $chain
        Write-Host ""
        continue
    }

    # Step 3: 该源 output0 子树内的压缩包 -> output（平铺 / 保留结构）
    $step3Entries = @(Get-ArchiveEntrypoints -RootDir $r2.TargetDir)
    $allOk = $true
    foreach ($a in $step3Entries) {
        $chain.CleanupEntries = @($chain.CleanupEntries + $a)
        if ($step3Flatten) {
            $ok = Expand-ArchiveFlatten -Entry $a -OutputDir $Output
        } else {
            $relDir2 = Get-RelativeDirectory -RootDir $Output0 -ChildDir $a.Dir
            $target = if ($relDir2) { Join-Path (Join-Path $Output $relDir2) (Get-SafeFolderName -Name $a.Base) } else { Join-Path $Output (Get-SafeFolderName -Name $a.Base) }
            $r3 = Invoke-NamedExtraction -Entry $a -TargetDir $target
            $ok = $r3.Success
        }
        if (-not $ok) { $allOk = $false }
    }

    $chain.Success = $allOk
    if ($chain.Success) {
        Write-Host "[CHAIN OK] $($source.Base)" -ForegroundColor Green
    } else {
        $chain.FailedStage = "Step3"
        Write-Host "[CHAIN FAIL] $($source.Base): Step3（源文件保留）" -ForegroundColor Red
    }
    $chains += $chain
    Write-Host ""
}

# ==================== 清理：只删除完整成功链 ====================
if ($deleteFlag) {
    $completed = @($chains | Where-Object { $_.Success })
    if ($completed.Count -eq 0) {
        Write-Host "没有完整成功的链路需要清理" -ForegroundColor Gray
    } else {
        Write-Host "[CLEAN] 删除完整成功链的源/中间压缩包..." -ForegroundColor Cyan
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $deleted = 0
        foreach ($chain in $completed) {
            foreach ($entry in @($chain.CleanupEntries | Where-Object { $null -ne $_ })) {
                $key = "{0}|{1}" -f $entry.Type, (Get-NormalizedPath -Path $entry.Path)
                if (-not $seen.Add($key)) { continue }
                if (Remove-ArchiveGroup -Entry $entry) {
                    Write-Host "  [DELETE] $(Split-Path -Leaf $entry.Path)" -ForegroundColor DarkGray
                    $deleted++
                }
            }
        }
        Write-Host "  [OK] 已删除 $deleted 个链路压缩包入口" -ForegroundColor Green
    }

    # output0 若已空则删除，否则保留以便排查
    if (Test-Path -LiteralPath $Output0) {
        $remaining = @(Get-ChildItem -LiteralPath $Output0 -Recurse -File -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $Output0 -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "[OK] 已删除中间目录 output0" -ForegroundColor Green
        } else {
            Write-Host "[KEEP] output0 仍有文件，保留以供排查" -ForegroundColor Yellow
        }
    }

    Write-Host "[CLEAN] 删除源目录的空文件夹（保留 output）..." -ForegroundColor Cyan
    Remove-EmptyDirs -Root $scriptDir -ProtectDirs @($Output)
} else {
    Write-Host "[SKIP] deleteFlag=false，跳过所有删除" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "[DONE] 完成！" -ForegroundColor Green
Read-Host "按 Enter 退出"

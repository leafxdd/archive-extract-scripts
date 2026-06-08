#Requires -Version 5.1
<#
.SYNOPSIS
    FLYYZ 压缩包处理脚本 - 优化版
.DESCRIPTION
    1. 将伪装成MP4的压缩包还原为zip
    2. 解压所有压缩包到output0
    3. 再从output0解压到output
    4. 支持 zip/7z/zip分卷/7z分卷
#>

param(
    [string]$WorkDir = $PSScriptRoot,
    [string]$Password = "FLYYZ",
    [switch]$KeepFiles = $false
)

# ==================== 初始化设置 ====================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

# 工具路径
$7zExe = Join-Path $env:ProgramFiles "7-Zip-Zstandard\7z.exe"
$WinRarExe = Join-Path $env:ProgramFiles "WinRAR\WinRAR.exe"

# 输出目录
$Output0 = Join-Path $WorkDir "output0"
$Output = Join-Path $WorkDir "output"

# 删除标志
$DeleteFlag = -not $KeepFiles

# ==================== 工具检查 ====================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "FLYYZ 压缩包处理脚本" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path -LiteralPath $7zExe)) {
    Write-Host "错误: 未找到 7-Zip-Zstandard" -ForegroundColor Red
    Write-Host "路径: $7zExe" -ForegroundColor Red
    Write-Host "请从 https://github.com/mcmilk/7-Zip-zstd 下载安装" -ForegroundColor Yellow
    Read-Host "按回车键退出"
    exit 1
}
Write-Host "✓ 7-Zip-Zstandard: $7zExe" -ForegroundColor Green

if (-not (Test-Path -LiteralPath $WinRarExe)) {
    Write-Host "错误: 未找到 WinRAR" -ForegroundColor Red
    Write-Host "路径: $WinRarExe" -ForegroundColor Red
    Read-Host "按回车键退出"
    exit 1
}
Write-Host "✓ WinRAR: $WinRarExe" -ForegroundColor Green
Write-Host ""

# 创建输出目录
if (-not (Test-Path -LiteralPath $Output0)) { 
    [System.IO.Directory]::CreateDirectory($Output0) | Out-Null 
}
if (-not (Test-Path -LiteralPath $Output)) { 
    [System.IO.Directory]::CreateDirectory($Output) | Out-Null 
}

# ==================== 辅助函数 ====================

# 路径归一化/排除判断（解决嵌套文件夹扫描遗漏、大小写/分隔符差异）
function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    try {
        return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\','/')
    } catch {
        return $Path.TrimEnd('\','/')
    }
}

function Test-IsUnderPath {
    param(
        [Parameter(Mandatory)][string]$ChildPath,
        [Parameter(Mandatory)][string]$ParentPath
    )
    $c = (Get-NormalizedPath $ChildPath)
    $p = (Get-NormalizedPath $ParentPath)
    # 统一末尾分隔符，避免 C:\a\b 与 C:\a\b1 的误判
    $p2 = $p + '\'
    return ($c -ieq $p) -or ($c.StartsWith($p2, [System.StringComparison]::OrdinalIgnoreCase))
}

# 识别并返回“需要作为入口解压”的压缩包（含分卷入口：.7z.001 / .zip.001 / .z01+.zip）
function Get-ArchiveEntrypoints {
    param(
        [Parameter(Mandatory)][string]$RootDir,
        [string[]]$ExcludeDirs = @()
    )

    $excludeNorm = @($ExcludeDirs | ForEach-Object { Get-NormalizedPath $_ })

    $allFiles = Get-ChildItem -LiteralPath $RootDir -Recurse -File -Force -ErrorAction SilentlyContinue
    if (-not $allFiles) { return @() }

    $entries = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($f in $allFiles) {
        # 排除目录（output / output0 等）
        $skip = $false
        foreach ($ex in $excludeNorm) {
            if ($ex -and (Test-IsUnderPath -ChildPath $f.FullName -ParentPath $ex)) { $skip = $true; break }
        }
        if ($skip) { continue }

        $name = $f.Name
        $full = $f.FullName

        # 0) RAR（单文件 / part 分卷 / r00 分卷）
        if ($f.Extension -ieq '.rar') {
            # rar.part01.rar / rar.part1.rar ...（入口：part1/part01）
            if ($name -match '^(?<stem>.+?)\.part(?<part>\d+)\.rar$') {
                $partNum = 0
                [void][int]::TryParse($Matches.part, [ref]$partNum)
                if ($partNum -ne 1) { continue }

                if ($seen.Add($full)) {
                    $entries.Add([pscustomobject]@{ Path=$full; Type='rar-part'; Dir=$f.DirectoryName; Base=$Matches.stem })
                }
                continue
            }

            # 传统 r00/r01... 分卷（入口：xxx.rar，旁边有 xxx.r00）
            $r00 = Join-Path $f.DirectoryName ($f.BaseName + '.r00')
            $type = if (Test-Path -LiteralPath $r00) { 'rar-r00' } else { 'rar' }

            if ($seen.Add($full)) {
                $entries.Add([pscustomobject]@{ Path=$full; Type=$type; Dir=$f.DirectoryName; Base=$f.BaseName })
            }
            continue
        }

        # 1) 普通 .zip / .7z
        if ($f.Extension -ieq '.zip' -or $f.Extension -ieq '.7z') {
            # 识别 PKZIP 传统分卷：同目录存在 .z01（入口：xxx.zip）
            $isZipSplitZ = $false
            if ($f.Extension -ieq '.zip') {
                $z01 = Join-Path $f.DirectoryName ($f.BaseName + '.z01')
                $isZipSplitZ = Test-Path -LiteralPath $z01
            }
            $type = if ($isZipSplitZ) { 'zip-z' } else { $f.Extension.TrimStart('.') }

            if ($seen.Add($full)) {
                $entries.Add([pscustomobject]@{ Path=$full; Type=$type; Dir=$f.DirectoryName; Base=$f.BaseName })
            }
            continue
        }

        # 2) 7-Zip / Zip 数字分卷：xxx.7z.001 / xxx.zip.001（也兼容 0001/01 等，只取第一卷）
        if ($name -match '^(?<stem>.+?)\.(?<fmt>7z|zip)\.(?<part>\d+)$') {
            $fmt = $Matches.fmt.ToLowerInvariant()
            $partNum = 0
            [void][int]::TryParse($Matches.part, [ref]$partNum)
            if ($partNum -ne 1) { continue }

            $type = "$fmt-001"
            if ($seen.Add($full)) {
                $entries.Add([pscustomobject]@{ Path=$full; Type=$type; Dir=$f.DirectoryName; Base=$Matches.stem })
            }
            continue
        }

        # 3) 传统 ZIP 分卷：xxx.z01 + xxx.zip（入口通常是 xxx.zip；若缺失则尝试 xxx.z01）
        if ($name -match '^(?<stem>.+?)\.z(?<part>\d+)$') {
            $partNum = 0
            [void][int]::TryParse($Matches.part, [ref]$partNum)
            if ($partNum -ne 1) { continue }

            $zipCandidate = Join-Path $f.DirectoryName ($Matches.stem + '.zip')
            if (Test-Path -LiteralPath $zipCandidate) {
                if ($seen.Add($zipCandidate)) {
                    $entries.Add([pscustomobject]@{ Path=$zipCandidate; Type='zip-z'; Dir=$f.DirectoryName; Base=$Matches.stem })
                }
            } else {
                # 兜底：没有 .zip 也把 .z01 当入口试一把
                if ($seen.Add($full)) {
                    $entries.Add([pscustomobject]@{ Path=$full; Type='zip-z01'; Dir=$f.DirectoryName; Base=$Matches.stem })
                }
            }
            continue
        }
    }

    return $entries
}


function Remove-ArchiveGroup {
    param(
        [Parameter(Mandatory)][pscustomobject]$Entry
    )

    try {
        switch -Regex ($Entry.Type) {
            '^zip-z$' {
                # 删除 xxx.zip + xxx.z01/xxx.z02...
                $zipPath = $Entry.Path
                $dir = $Entry.Dir
                $base = [regex]::Escape($Entry.Base)
                $zParts = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^$base\.z\d+$" }
                foreach ($p in $zParts) { Remove-Item -LiteralPath $p.FullName -Force -ErrorAction SilentlyContinue }
                Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            }
            '^zip-z01$' {
                # 删除 xxx.z01/xxx.z02... 以及（如果存在）xxx.zip
                $firstPath = $Entry.Path
                $dir = $Entry.Dir
                $base = [regex]::Escape($Entry.Base)
                $zParts = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^$base\.z\d+$" }
                foreach ($p in $zParts) { Remove-Item -LiteralPath $p.FullName -Force -ErrorAction SilentlyContinue }
                $zipPath = Join-Path $dir ($Entry.Base + '.zip')
                if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath $firstPath) { Remove-Item -LiteralPath $firstPath -Force -ErrorAction SilentlyContinue }
            }
            '^(zip|7z)-001$' {
                # 删除 xxx.zip.001/002... 或 xxx.7z.001/002...
                $dir = $Entry.Dir
                $stemEsc = [regex]::Escape($Entry.Base)
                $fmt = ($Entry.Type -split '-')[0]
                $parts = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^$stemEsc\.$fmt\.\d+$" }
                foreach ($p in $parts) { Remove-Item -LiteralPath $p.FullName -Force -ErrorAction SilentlyContinue }
            }
            '^rar-part$' {
                # 删除 xxx.part01.rar / xxx.part02.rar ...
                $dir = $Entry.Dir
                $stemEsc = [regex]::Escape($Entry.Base)
                $parts = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^$stemEsc\.part\d+\.rar$" }
                foreach ($p in $parts) { Remove-Item -LiteralPath $p.FullName -Force -ErrorAction SilentlyContinue }
            }
            '^rar-r00$' {
                # 删除 xxx.rar + xxx.r00/xxx.r01...
                $dir = $Entry.Dir
                $stemEsc = [regex]::Escape($Entry.Base)
                $rParts = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^$stemEsc\.r\d\d$" }
                foreach ($p in $rParts) { Remove-Item -LiteralPath $p.FullName -Force -ErrorAction SilentlyContinue }
                $rarPath = Join-Path $dir ($Entry.Base + '.rar')
                if (Test-Path -LiteralPath $rarPath) { Remove-Item -LiteralPath $rarPath -Force -ErrorAction SilentlyContinue }
            }
            default {
                # 普通单文件：zip / 7z / rar
                Remove-Item -LiteralPath $Entry.Path -Force -ErrorAction SilentlyContinue
            }
        }
        return $true
    } catch {
        return $false
    }
}


function Invoke-WinRARExtract {
    param(
        [string]$ArchivePath,
        [string]$TargetDir
    )
    
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        [System.IO.Directory]::CreateDirectory($TargetDir) | Out-Null
    }
    
    $proc = Start-Process -FilePath $WinRarExe -ArgumentList @('x', "-p$Password", '-ibck', '-y', "`"$ArchivePath`"", "`"$TargetDir\`"") -Wait -PassThru -NoNewWindow
    return ($proc.ExitCode -eq 0)
}

# 7z 解压函数
function Invoke-7zExtract {
    param(
        [string]$ArchivePath,
        [string]$TargetDir
    )
    
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        [System.IO.Directory]::CreateDirectory($TargetDir) | Out-Null
    }
    
    & $7zExe x "-p$Password" -aoa -y "-o$TargetDir" $ArchivePath
    return ($LASTEXITCODE -eq 0)
}

# 处理压缩包函数
function Process-Archives {
    param(
        [string]$SourceDir,
        [string]$TargetDir,
        [switch]$DeleteAfter
    )
    
    # 多轮扫描/解压：解决“解压后又出现更深层压缩包”的情况
    $maxPasses = 10
    $processed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    for ($pass = 1; $pass -le $maxPasses; $pass++) {
        $entries = Get-ArchiveEntrypoints -RootDir $SourceDir
        if ($entries) {
            $entries = @($entries | Where-Object { -not $processed.Contains($_.Path) })
        }
        if (-not $entries -or $entries.Count -eq 0) {
            if ($pass -eq 1) {
                Write-Host "未发现可解压的压缩包" -ForegroundColor Gray
            }
            break
        }

        Write-Host ("\n[PASS $pass] 发现 $($entries.Count) 个压缩包入口，开始解压…") -ForegroundColor Cyan

        foreach ($e in $entries) {
            $label = switch ($e.Type) {
                'zip-z' { 'zip分卷(z01)' }
                'zip-001' { 'zip分卷(001)' }
                '7z-001' { '7z分卷' }
                default { $e.Type }
            }

            Write-Host "[EXTRACT] ($label) $(Split-Path -Leaf $e.Path) → $TargetDir" -ForegroundColor Yellow
            $success = Invoke-7zExtract -ArchivePath $e.Path -TargetDir $TargetDir

            if ($success) {
                Write-Host "  ✓ 成功: $(Split-Path -Leaf $e.Path)" -ForegroundColor Green
                [void]$processed.Add($e.Path)
                if ($DeleteAfter) {
                    [void](Remove-ArchiveGroup -Entry $e)
                    Write-Host "  → 已删除源压缩包/分卷" -ForegroundColor DarkGray
                }
            } else {
                Write-Host "  ✗ 失败: $(Split-Path -Leaf $e.Path)" -ForegroundColor Red
                [void]$processed.Add($e.Path)
            }
        }
    }
}

# ==================== 步骤 0: 重命名 MP4 为 ZIP ====================
Write-Host "步骤 0: 查找 .mp4 文件并重命名为 .zip" -ForegroundColor Yellow
Write-Host "----------------------------------------"

$mp4Files = Get-ChildItem -LiteralPath $WorkDir -Recurse -File -ErrorAction SilentlyContinue | 
    Where-Object { 
        $_.Extension -eq '.mp4' -and
        $_.FullName -notlike "*\output\*" -and 
        $_.FullName -notlike "*\output0\*"
    }

foreach ($file in $mp4Files) {
    $newName = $file.BaseName + ".zip"
    try {
        Rename-Item -LiteralPath $file.FullName -NewName $newName -ErrorAction Stop
        Write-Host "[RENAME] $($file.Name) → $newName" -ForegroundColor Green
    } catch {
        Write-Host "[ERROR] 重命名失败: $($file.Name) - $_" -ForegroundColor Red
    }
}

Write-Host ""

# ==================== 步骤 1: 解压到 output0 (使用WinRAR) ====================
Write-Host "步骤 1: 解压 .zip / .7z / 分卷压缩包 → output0 (WinRAR)" -ForegroundColor Yellow
Write-Host "----------------------------------------"

# 获取工作目录下的压缩包入口（排除 output / output0），支持：
# - 普通 .zip / .7z
# - zip 分卷：xxx.z01 + xxx.zip
# - zip 分卷：xxx.zip.001/002...
# - 7z 分卷：xxx.7z.001/002...
$entries = Get-ArchiveEntrypoints -RootDir $WorkDir -ExcludeDirs @($Output, $Output0)

if (-not $entries -or $entries.Count -eq 0) {
    Write-Host "未发现可解压的压缩包" -ForegroundColor Gray
} else {
    foreach ($e in $entries) {
        $label = switch ($e.Type) {
            'zip-z' { 'zip分卷(z01)' }
            'zip-001' { 'zip分卷(001)' }
            '7z-001' { '7z分卷' }
            default { $e.Type }
        }

        Write-Host "[EXTRACT] ($label) $(Split-Path -Leaf $e.Path) → output0" -ForegroundColor Yellow
        # 7z 格式用 7-Zip-Zstandard，rar/zip 格式用 WinRAR
        if ($e.Type -imatch '^7z') {
            & $7zExe 'x' "-p$Password" '-aoa' "-o$Output0" $e.Path
            $success = ($LASTEXITCODE -eq 0)
        } else {
            $success = Invoke-WinRARExtract -ArchivePath $e.Path -TargetDir $Output0
        }

        if ($success) {
            Write-Host "  ✓ 成功: $(Split-Path -Leaf $e.Path)" -ForegroundColor Green
            if ($DeleteFlag) {
                [void](Remove-ArchiveGroup -Entry $e)
                Write-Host "  → 已删除源压缩包/分卷" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  ✗ 失败: $(Split-Path -Leaf $e.Path)" -ForegroundColor Red
        }
    }
}

Write-Host ""

# ==================== 步骤 2: 从 output0 解压到 output (使用7z) ====================
Write-Host "步骤 2: 从 output0 解压到 output (7z)" -ForegroundColor Yellow
Write-Host "----------------------------------------"

Process-Archives -SourceDir $Output0 -TargetDir $Output -DeleteAfter:$DeleteFlag

Write-Host ""

# ==================== 清理工作 ====================
Write-Host "步骤 3: 清理工作..." -ForegroundColor Yellow
Write-Host "----------------------------------------"

# 删除 output0
# 与 -KeepFiles 开关保持一致：默认清理；使用 -KeepFiles 时保留 output0 作为中间文件。
if ($DeleteFlag -and (Test-Path -LiteralPath $Output0)) {
    $remaining = Get-ChildItem -LiteralPath $Output0 -Recurse -File -ErrorAction SilentlyContinue
    if (-not $remaining) {
        Remove-Item -LiteralPath $Output0 -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "✓ 已删除 output0（已为空）" -ForegroundColor Green
    } else {
        Write-Host "⚠ output0 中仍有文件（解压失败残留），已保留以供排查" -ForegroundColor Yellow
    }
} elseif (-not $DeleteFlag -and (Test-Path -LiteralPath $Output0)) {
    Write-Host "-KeepFiles 已启用，保留 output0 文件夹" -ForegroundColor Gray
}

# 清理空文件夹
if ($DeleteFlag) {
    Write-Host ""
    Write-Host "清理空文件夹..." -ForegroundColor Yellow
    
    $allDirs = Get-ChildItem -LiteralPath $WorkDir -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            -not (Test-IsUnderPath $_.FullName $Output) -and
            $_.FullName -ne $Output0
        } |
        Sort-Object { $_.FullName.Split('\').Count } -Descending
    
    $deletedCount = 0
    foreach ($dir in $allDirs) {
        $items = Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
        if ($items.Count -eq 0) {
            try {
                Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop
                Write-Host "已删除: $($dir.FullName)" -ForegroundColor DarkGray
                $deletedCount++
            } catch { }
        }
    }
    
    if ($deletedCount -eq 0) {
        Write-Host "没有空文件夹需要清理" -ForegroundColor Gray
    } else {
        Write-Host "共清理 $deletedCount 个空文件夹" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "全部完成！" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "按回车键退出"
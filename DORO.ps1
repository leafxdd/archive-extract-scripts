#Requires -Version 5.1
<#
.SYNOPSIS
    DORO 压缩包处理脚本 - 合并版
.DESCRIPTION
    1. 将伪装成MP4的压缩包还原并解压到output0（根目录）
    2. 解压output0中的压缩包到output1（根目录）
    3. 智能解压output1中的压缩包到output（根据压缩包结构决定是否创建同名文件夹）
    4. 清理垃圾文件和空文件夹
#>

param(
    [string]$WorkDir = $PSScriptRoot,
    [string]$Password = "doro",
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
$Output1 = Join-Path $WorkDir "output1"
$Output = Join-Path $WorkDir "output"

# 删除标志（与KeepFiles相反）
$DeleteFlag = -not $KeepFiles

# 垃圾文件列表
$JunkFiles = @(
    "好用的VPN和AI茶馆.txt"
)

# ==================== 工具检查 ====================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "DORO 压缩包处理脚本" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 检查 7-Zip-Zstandard
if (-not (Test-Path -LiteralPath $7zExe)) {
    Write-Host "错误: 未找到 7-Zip-Zstandard" -ForegroundColor Red
    Write-Host "路径: $7zExe" -ForegroundColor Red
    Write-Host "请从 https://github.com/mcmilk/7-Zip-zstd 下载安装" -ForegroundColor Yellow
    Read-Host "按回车键退出"
    exit 1
}
Write-Host "✓ 7-Zip-Zstandard: $7zExe" -ForegroundColor Green

# 检查 WinRAR
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
if (-not (Test-Path -LiteralPath $Output1)) { 
    [System.IO.Directory]::CreateDirectory($Output1) | Out-Null 
}
if (-not (Test-Path -LiteralPath $Output)) { 
    [System.IO.Directory]::CreateDirectory($Output) | Out-Null 
}

# ==================== 函数定义 ====================

function Test-IsUnderPath {
    param(
        [Parameter(Mandatory)][string]$ChildPath,
        [Parameter(Mandatory)][string]$ParentPath
    )
    $c = [IO.Path]::GetFullPath($ChildPath).TrimEnd('\')
    $p = [IO.Path]::GetFullPath($ParentPath).TrimEnd('\')
    return ($c -ieq $p) -or ($c.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase))
}

# 函数：使用 7z 检查压缩包根目录是否有文件夹
function Test-ArchiveHasRootFolder {
    param([string]$ArchivePath, [string]$ArchivePassword)
    
    try {
        # 使用 7z l 列出压缩包内容
        $result = & $7zExe l "-p$ArchivePassword" -slt -- $ArchivePath 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  警告: 无法列出压缩包内容，将使用默认行为" -ForegroundColor Yellow
            return $false
        }
        
        # 解析输出，查找根目录项
        $entries = @()
        $currentEntry = @{}
        
        foreach ($line in $result) {
            if ($line -match '^Path = (.+)$') {
                if ($currentEntry.Count -gt 0) {
                    $entries += [PSCustomObject]$currentEntry
                }
                $currentEntry = @{ Path = $matches[1] }
            } elseif ($line -match '^Folder = (.+)$') {
                $currentEntry['Folder'] = $matches[1]
            } elseif ($line -match '^Attributes = (.+)$') {
                $currentEntry['Attributes'] = $matches[1]
            }
        }
        if ($currentEntry.Count -gt 0) {
            $entries += [PSCustomObject]$currentEntry
        }
        
        # 检查根目录是否有文件夹
        foreach ($entry in $entries) {
            $path = $entry.Path
            # 跳过压缩包自身路径
            if ($path -eq (Split-Path $ArchivePath -Leaf)) { continue }
            
            # 检查是否是根目录项（不包含路径分隔符）
            $cleanPath = $path.TrimEnd('\', '/')
            if ($cleanPath -notmatch '[/\\]') {
                # 这是根目录项，检查是否是文件夹
                $isFolder = ($entry.Folder -eq '+') -or 
                           ($entry.Attributes -match '^D') -or
                           ($path.EndsWith('\') -or $path.EndsWith('/'))
                
                if ($isFolder) {
                    return $true
                }
            }
        }
        
        return $false
    } catch {
        Write-Host "  警告: 检查压缩包结构时出错: $_" -ForegroundColor Yellow
        return $false
    }
}

# 函数：解压压缩包到指定目录（直接解压，不创建同名文件夹）
function Expand-ArchiveToDir {
    param(
        [System.IO.FileInfo]$File,
        [string]$TargetDir
    )
    
    Write-Host "解压: $($File.Name) → $TargetDir" -ForegroundColor White
    
    if (-not (Test-Path -LiteralPath $TargetDir)) { 
        [System.IO.Directory]::CreateDirectory($TargetDir) | Out-Null
    }
    
    # 使用 7z 解压
    & $7zExe 'x' "-p$Password" '-aoa' "-o$TargetDir" $File.FullName | Out-Host
    return $LASTEXITCODE
}

# 函数：智能解压（根据压缩包结构决定目标目录）
function Expand-ArchiveSmart {
    param(
        [System.IO.FileInfo]$File,
        [string]$BaseTargetDir,
        [string]$ArchiveName
    )
    
    Write-Host "检查: $($File.Name)" -ForegroundColor White
    
    # 检查压缩包根目录是否有文件夹
    $hasRootFolder = Test-ArchiveHasRootFolder -ArchivePath $File.FullName -ArchivePassword $Password
    
    if ($hasRootFolder) {
        # 根目录有文件夹，直接解压到目标目录
        $targetDir = $BaseTargetDir
        Write-Host "  → 根目录有文件夹，解压到: $targetDir" -ForegroundColor Cyan
    } else {
        # 根目录没有文件夹，解压到同名文件夹
        $targetDir = Join-Path $BaseTargetDir $ArchiveName
        Write-Host "  → 根目录无文件夹，解压到: $targetDir" -ForegroundColor Cyan
    }
    
    if (-not (Test-Path -LiteralPath $targetDir)) { 
        [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null
    }
    
    Write-Host "  解压中..." -ForegroundColor White
    & $7zExe 'x' "-p$Password" '-aoa' "-o$targetDir" $File.FullName | Out-Host
    return $LASTEXITCODE
}

# 函数：处理目录中的所有压缩包
function Process-ArchivesInDir {
    param(
        [string]$SourceDir,
        [string]$TargetDir,
        [switch]$SmartExtract,
        [switch]$DeleteAfter
    )
    
    # 处理 .zip 和 .7z 文件（非分卷）
    $archives = Get-ChildItem -LiteralPath $SourceDir -Recurse -File -ErrorAction SilentlyContinue | 
        Where-Object { 
            $_.Extension -match '^\.(zip|7z)$' -and 
            $_.Name -notmatch '\.7z\.\d+$' 
        }
    
    foreach ($file in $archives) {
        if ($SmartExtract) {
            $archiveName = $file.BaseName
            $exitCode = Expand-ArchiveSmart -File $file -BaseTargetDir $TargetDir -ArchiveName $archiveName
        } else {
            $exitCode = Expand-ArchiveToDir -File $file -TargetDir $TargetDir
        }
        
        if ($exitCode -eq 0) {
            Write-Host "  ✓ 成功: $($file.Name)" -ForegroundColor Green
            if ($DeleteAfter) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                Write-Host "  → 已删除: $($file.FullName)" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  ✗ 失败: $($file.Name) (ExitCode: $exitCode)" -ForegroundColor Red
        }
        Write-Host ""
    }
    
    # 处理 .7z.001 分卷压缩包
    $volumeArchives = Get-ChildItem -LiteralPath $SourceDir -Recurse -File -ErrorAction SilentlyContinue | 
        Where-Object { $_.Name -match '\.7z\.001$' }
    
    foreach ($file in $volumeArchives) {
        Write-Host "(分卷压缩包)" -ForegroundColor Magenta
        
        if ($SmartExtract) {
            $archiveName = $file.BaseName -replace '\.7z$', ''
            $exitCode = Expand-ArchiveSmart -File $file -BaseTargetDir $TargetDir -ArchiveName $archiveName
        } else {
            $exitCode = Expand-ArchiveToDir -File $file -TargetDir $TargetDir
        }
        
        if ($exitCode -eq 0) {
            Write-Host "  ✓ 成功: $($file.Name)" -ForegroundColor Green
            if ($DeleteAfter) {
                $basePattern = $file.BaseName -replace '\.7z$', ''
                $escapedPattern = [regex]::Escape($basePattern)
                $volumeFiles = Get-ChildItem -LiteralPath $file.DirectoryName -File -ErrorAction SilentlyContinue | 
                    Where-Object { $_.Name -match "^$escapedPattern\.7z\.\d+$" }
                foreach ($vf in $volumeFiles) {
                    Remove-Item -LiteralPath $vf.FullName -Force -ErrorAction SilentlyContinue
                    if (Test-Path -LiteralPath $vf.FullName) {
                        Write-Host "  ⚠ 删除分卷失败: $($vf.Name)" -ForegroundColor Yellow
                    }
                }
                Write-Host "  → 已删除分卷文件: $basePattern.7z.*" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  ✗ 失败: $($file.Name) (ExitCode: $exitCode)" -ForegroundColor Red
        }
        Write-Host ""
    }
}

# ==================== 步骤 1: 处理伪装的 MP4 文件 ====================
Write-Host "步骤 1: 处理伪装的 MP4 文件 → output0" -ForegroundColor Yellow
Write-Host "----------------------------------------"

$mp4Files = Get-ChildItem -LiteralPath $WorkDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Extension -eq '.mp4' -and
    -not (Test-IsUnderPath $_.FullName $Output) -and
    -not (Test-IsUnderPath $_.FullName $Output0) -and
    -not (Test-IsUnderPath $_.FullName $Output1)
}

if ($mp4Files.Count -eq 0) {
    Write-Host "未找到 MP4 文件" -ForegroundColor Gray
} else {
    foreach ($mp4 in $mp4Files) {
        # 重命名为 zip
        $zipName = $mp4.BaseName + ".zip"
        $zipPath = Join-Path $mp4.DirectoryName $zipName
        
        try {
            Rename-Item -LiteralPath $mp4.FullName -NewName $zipName -Force
            
            Write-Host "解压: $zipName → $Output0" -ForegroundColor White
            
            # 使用 WinRAR 解压到 output0 根目录
            $proc = Start-Process -FilePath $WinRarExe -ArgumentList @('x', "-p$Password", '-ibck', '-y', "`"$zipPath`"", "`"$Output0\`"") -Wait -PassThru -NoNewWindow

            if ($proc.ExitCode -eq 0) {
                Write-Host "  ✓ 成功: $zipName" -ForegroundColor Green
                if ($DeleteFlag) {
                    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
                    Write-Host "  → 已删除: $zipPath" -ForegroundColor DarkGray
                }
            } else {
                Write-Host "  ✗ 失败: $zipName (ExitCode: $($proc.ExitCode))" -ForegroundColor Red
            }
        } catch {
            Write-Host "  ✗ 错误处理 $($mp4.Name): $_" -ForegroundColor Red
        }
        Write-Host ""
    }
}

# 处理工作目录中已有的 zip/7z 压缩包（用户可能手动重命名了 mp4→zip）
$existingArchives = Get-ChildItem -LiteralPath $WorkDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Extension -match '^\.(zip|7z)$' -and
    $_.Name -notmatch '\.7z\.\d+$' -and
    -not (Test-IsUnderPath $_.FullName $Output) -and
    -not (Test-IsUnderPath $_.FullName $Output0) -and
    -not (Test-IsUnderPath $_.FullName $Output1)
}

if ($existingArchives.Count -gt 0) {
    Write-Host "处理已有压缩包 → output0" -ForegroundColor Yellow
    foreach ($file in $existingArchives) {
        Write-Host "解压: $($file.Name) → $Output0" -ForegroundColor White
        $proc = Start-Process -FilePath $WinRarExe -ArgumentList @('x', "-p$Password", '-ibck', '-y', "`"$($file.FullName)`"", "`"$Output0\`"") -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -eq 0) {
            Write-Host "  ✓ 成功: $($file.Name)" -ForegroundColor Green
            if ($DeleteFlag) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                Write-Host "  → 已删除: $($file.FullName)" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  ✗ 失败: $($file.Name) (ExitCode: $($proc.ExitCode))" -ForegroundColor Red
        }
        Write-Host ""
    }
}

# ==================== 步骤 2: 解压 output0 → output1 ====================
Write-Host "步骤 2: 解压 output0 中的压缩包 → output1" -ForegroundColor Yellow
Write-Host "----------------------------------------"

Process-ArchivesInDir -SourceDir $Output0 -TargetDir $Output1 -DeleteAfter:$DeleteFlag

# ==================== 步骤 3: 智能解压 output1 → output ====================
Write-Host "步骤 3: 智能解压 output1 中的压缩包 → output" -ForegroundColor Yellow
Write-Host "----------------------------------------"

Process-ArchivesInDir -SourceDir $Output1 -TargetDir $Output -SmartExtract -DeleteAfter:$DeleteFlag

# ==================== 步骤 4: 删除 output0 和 output1 ====================
Write-Host "步骤 4: 删除中间目录..." -ForegroundColor Yellow
Write-Host "----------------------------------------"

if (Test-Path -LiteralPath $Output0) {
    $remaining = Get-ChildItem -LiteralPath $Output0 -Recurse -File -ErrorAction SilentlyContinue
    if (-not $remaining) {
        Remove-Item -LiteralPath $Output0 -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "✓ 已删除 output0 文件夹" -ForegroundColor Green
    } else {
        Write-Host "⚠ output0 中仍有文件（解压失败残留），已保留以供排查" -ForegroundColor Yellow
    }
}

if (Test-Path -LiteralPath $Output1) {
    $remaining = Get-ChildItem -LiteralPath $Output1 -Recurse -File -ErrorAction SilentlyContinue
    if (-not $remaining) {
        Remove-Item -LiteralPath $Output1 -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "✓ 已删除 output1 文件夹" -ForegroundColor Green
    } else {
        Write-Host "⚠ output1 中仍有文件（解压失败残留），已保留以供排查" -ForegroundColor Yellow
    }
}

Write-Host ""

# ==================== 步骤 5: 清理垃圾文件 ====================
Write-Host "步骤 5: 清理垃圾文件..." -ForegroundColor Yellow
Write-Host "----------------------------------------"

$deleteCount = 0
foreach ($junkFile in $JunkFiles) {
    $found = Get-ChildItem -LiteralPath $Output -Recurse -File -ErrorAction SilentlyContinue | 
        Where-Object { $_.Name -eq $junkFile }
    foreach ($f in $found) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        Write-Host "已删除垃圾文件: $($f.FullName)" -ForegroundColor DarkGray
        $deleteCount++
    }
}

if ($deleteCount -eq 0) {
    Write-Host "未发现垃圾文件" -ForegroundColor Gray
} else {
    Write-Host "共删除 $deleteCount 个垃圾文件" -ForegroundColor Green
}

Write-Host ""

# ==================== 步骤 6: 清理空文件夹 ====================
if ($DeleteFlag) {
    Write-Host "步骤 6: 清理空文件夹..." -ForegroundColor Yellow
    Write-Host "----------------------------------------"
    
    # 获取所有子目录，按深度倒序排列（先处理最深的）
    $allDirs = Get-ChildItem -LiteralPath $WorkDir -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            -not (Test-IsUnderPath $_.FullName $Output) -and
            $_.FullName -ne $Output0 -and
            $_.FullName -ne $Output1
        } |
        Sort-Object { $_.FullName.Split('\').Count } -Descending

    $deletedCount = 0
    foreach ($dir in $allDirs) {
        # 检查目录是否为空
        $items = Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
        if ($null -ne $items -and @($items).Count -eq 0) {
            try {
                Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop
                Write-Host "已删除: $($dir.FullName)" -ForegroundColor DarkGray
                $deletedCount++
            } catch {
                # 忽略删除失败
            }
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
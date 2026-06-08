#Requires -Version 5.1
<#
.SYNOPSIS
    PADIO 压缩包处理脚本 - 合并版
.DESCRIPTION
    1. 将伪装成MP4的压缩包还原并解压到output0
    2. 智能解压output0中的压缩包到output（根据压缩包结构决定是否创建同名文件夹）
    3. 清理空文件夹
#>

param(
    [string]$WorkDir = $PSScriptRoot,
    [string]$Password = "PADIO294",
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

# 删除标志（与KeepFiles相反）
$DeleteFlag = -not $KeepFiles

# ==================== 工具检查 ====================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "PADIO 压缩包处理脚本" -ForegroundColor Cyan
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
if (-not (Test-Path -LiteralPath $Output)) { 
    [System.IO.Directory]::CreateDirectory($Output) | Out-Null 
}

# ==================== 步骤 1: 处理伪装的 MP4 文件 ====================
Write-Host "步骤 1: 处理伪装的 MP4 文件..." -ForegroundColor Yellow
Write-Host "----------------------------------------"

$mp4Files = Get-ChildItem -LiteralPath $WorkDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Extension -eq '.mp4' -and
    $_.FullName -notlike "*\output\*" -and 
    $_.FullName -notlike "*\output0\*"
}

if ($mp4Files.Count -eq 0) {
    Write-Host "未找到 MP4 文件" -ForegroundColor Gray
} else {
    foreach ($mp4 in $mp4Files) {
        # 计算相对路径
        $wdBase  = [IO.Path]::GetFullPath($WorkDir).TrimEnd('\') + '\'
        $mpDir   = [IO.Path]::GetFullPath($mp4.DirectoryName)
        $relPath = if ($mpDir.StartsWith($wdBase, [StringComparison]::OrdinalIgnoreCase)) {
                       $mpDir.Substring($wdBase.Length).TrimEnd('\') } else { '' }
        
        # 重命名为 zip
        $zipName = $mp4.BaseName + ".zip"
        $zipPath = Join-Path $mp4.DirectoryName $zipName
        
        try {
            Rename-Item -LiteralPath $mp4.FullName -NewName $zipName -Force
            
            # 创建目标目录
            if ($relPath) {
                $targetDir = Join-Path $Output0 $relPath
            } else {
                $targetDir = $Output0
            }
            if (-not (Test-Path -LiteralPath $targetDir)) { 
                [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null
            }
            
            Write-Host "解压: $zipName" -ForegroundColor White
            
            # 使用 WinRAR 解压
            $proc = Start-Process -FilePath $WinRarExe -ArgumentList @('x', "-p$Password", '-ibck', '-y', "`"$zipPath`"", "`"$targetDir\`"") -Wait -PassThru -NoNewWindow

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
    }
}

# 处理工作目录中已有的 zip/7z 压缩包（用户可能手动重命名了 mp4→zip）
$existingArchives = Get-ChildItem -LiteralPath $WorkDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Extension -match '^\.(zip|7z)$' -and
    $_.Name -notmatch '\.7z\.\d+$' -and
    $_.FullName -notlike "*\output\*" -and
    $_.FullName -notlike "*\output0\*"
}

if ($existingArchives.Count -gt 0) {
    Write-Host "处理已有压缩包 → output0" -ForegroundColor Yellow
    foreach ($file in $existingArchives) {
        $wdBase  = [IO.Path]::GetFullPath($WorkDir).TrimEnd('\') + '\'
        $mpDir   = [IO.Path]::GetFullPath($file.DirectoryName)
        $relPath = if ($mpDir.StartsWith($wdBase, [StringComparison]::OrdinalIgnoreCase)) {
                       $mpDir.Substring($wdBase.Length).TrimEnd('\') } else { '' }
        if ($relPath) {
            $targetDir = Join-Path $Output0 $relPath
        } else {
            $targetDir = $Output0
        }
        if (-not (Test-Path -LiteralPath $targetDir)) {
            [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null
        }
        Write-Host "解压: $($file.Name)" -ForegroundColor White
        $proc = Start-Process -FilePath $WinRarExe -ArgumentList @('x', "-p$Password", '-ibck', '-y', "`"$($file.FullName)`"", "`"$targetDir\`"") -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -eq 0) {
            Write-Host "  ✓ 成功: $($file.Name)" -ForegroundColor Green
            if ($DeleteFlag) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                Write-Host "  → 已删除: $($file.FullName)" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  ✗ 失败: $($file.Name) (ExitCode: $($proc.ExitCode))" -ForegroundColor Red
        }
    }
}

Write-Host ""

# ==================== 步骤 2: 处理 output0 中的压缩包 ====================
Write-Host "步骤 2: 处理 output0 中的压缩包..." -ForegroundColor Yellow
Write-Host "----------------------------------------"

# 函数：使用 7z 检查压缩包根目录是否有文件夹
function Test-ArchiveHasRootFolder {
    param([string]$ArchivePath, [string]$ArchivePassword)
    
    try {
        # 使用 7z l 列出压缩包内容
        $result = & $7zExe l "-p$ArchivePassword" -slt "$ArchivePath" 2>&1
        
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

# 函数：处理单个压缩包
function Expand-ArchiveFile {
    param(
        [System.IO.FileInfo]$File,
        [string]$RelativePath,
        [string]$ArchiveName
    )
    
    Write-Host "检查: $($File.Name)" -ForegroundColor White
    
    # 检查压缩包根目录是否有文件夹
    $hasRootFolder = Test-ArchiveHasRootFolder -ArchivePath $File.FullName -ArchivePassword $Password
    
    if ($hasRootFolder) {
        # 根目录有文件夹，直接解压到 output（保持相对路径）
        if ($RelativePath) {
            $targetDir = Join-Path $Output $RelativePath
        } else {
            $targetDir = $Output
        }
        Write-Host "  → 根目录有文件夹，解压到: $targetDir" -ForegroundColor Cyan
    } else {
        # 根目录没有文件夹，解压到同名文件夹
        if ($RelativePath) {
            $targetDir = Join-Path (Join-Path $Output $RelativePath) $ArchiveName
        } else {
            $targetDir = Join-Path $Output $ArchiveName
        }
        Write-Host "  → 根目录无文件夹，解压到: $targetDir" -ForegroundColor Cyan
    }
    
    # 创建目标目录
    if (-not (Test-Path -LiteralPath $targetDir)) { 
        [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null
    }
    
    # 使用 7z 解压
    Write-Host "  解压中..." -ForegroundColor White
    & $7zExe 'x' "-p$Password" '-aoa' "-o$targetDir" $File.FullName | Out-Host
    return $LASTEXITCODE
}

# 处理 .zip 和 .7z 文件（非分卷）
$archives = Get-ChildItem -LiteralPath $Output0 -Recurse -File -ErrorAction SilentlyContinue | 
    Where-Object { 
        $_.Extension -match '^\.(zip|7z)$' -and 
        $_.Name -notmatch '\.7z\.\d+$' 
    }

foreach ($file in $archives) {
    $relPath = $file.DirectoryName.Replace($Output0, '').TrimStart('\')
    $archiveName = $file.BaseName
    
    $exitCode = Expand-ArchiveFile -File $file -RelativePath $relPath -ArchiveName $archiveName
    
    if ($exitCode -eq 0) {
        Write-Host "  ✓ 成功: $($file.Name)" -ForegroundColor Green
        if ($DeleteFlag) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            Write-Host "  → 已删除: $($file.FullName)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  ✗ 失败: $($file.Name) (ExitCode: $exitCode)" -ForegroundColor Red
    }
    Write-Host ""
}

# 处理 .7z.001 分卷压缩包
$volumeArchives = Get-ChildItem -LiteralPath $Output0 -Recurse -File -ErrorAction SilentlyContinue | 
    Where-Object { $_.Name -match '\.7z\.001$' }

foreach ($file in $volumeArchives) {
    $relPath = $file.DirectoryName.Replace($Output0, '').TrimStart('\')
    $archiveName = $file.BaseName -replace '\.7z$', ''
    
    Write-Host "(分卷压缩包)" -ForegroundColor Magenta
    $exitCode = Expand-ArchiveFile -File $file -RelativePath $relPath -ArchiveName $archiveName
    
    if ($exitCode -eq 0) {
        Write-Host "  ✓ 成功: $($file.Name)" -ForegroundColor Green
        if ($DeleteFlag) {
            $basePattern = $file.BaseName -replace '\.7z$', ''
            $escapedPattern = [regex]::Escape($basePattern)
            $volumeFiles = Get-ChildItem -LiteralPath $file.DirectoryName -File -ErrorAction SilentlyContinue | 
                Where-Object { $_.Name -match "^$escapedPattern\.7z\.\d+$" }
            $volumeFiles | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
            Write-Host "  → 已删除分卷文件: $basePattern.7z.*" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  ✗ 失败: $($file.Name) (ExitCode: $exitCode)" -ForegroundColor Red
    }
    Write-Host ""
}

# ==================== 步骤 3: 清理中间目录和空文件夹 ====================
if ($DeleteFlag) {
    Write-Host "步骤 3: 清理..." -ForegroundColor Yellow
    Write-Host "----------------------------------------"

    # 检查 output0 是否可以安全删除
    if (Test-Path -LiteralPath $Output0) {
        $remaining = Get-ChildItem -LiteralPath $Output0 -Recurse -File -ErrorAction SilentlyContinue
        if (-not $remaining) {
            Remove-Item -LiteralPath $Output0 -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "✓ 已删除 output0" -ForegroundColor Green
        } else {
            Write-Host "⚠ output0 中仍有文件（解压失败残留），已保留以供排查" -ForegroundColor Yellow
        }
    }

    # 清理空文件夹
    $allDirs = Get-ChildItem -LiteralPath $WorkDir -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notlike "*\output\*" -and
            $_.FullName -ne $Output -and
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
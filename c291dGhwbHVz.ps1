#Requires -Version 5.1
<#
.SYNOPSIS
    c291dGhwbHVz 压缩包处理脚本 - PowerShell版
.DESCRIPTION
    查找并解压 .zip / .z01 / .7z / .7z.001 到 output，保持相对路径结构
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

# ==================== 初始化设置 ====================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

# 工具路径
$7zExe = Join-Path $env:ProgramFiles "7-Zip-Zstandard\7z.exe"

# 输出目录
$Output = Join-Path $WorkDir "output"

# 删除标志（与KeepFiles相反）
$DeleteFlag = -not $KeepFiles


# ==================== 路径安全辅助函数（处理 [] 等通配符字符） ====================
function Ensure-Directory {
    param([Parameter(Mandatory=$true)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        # 已存在但不是目录
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw "路径已存在但不是文件夹，无法作为输出目录使用: $Path"
        }
        return
    }

    try {
        # 使用 .NET 直接创建目录，避免 PowerShell 通配符解析（尤其是 [] 等字符）
        [System.IO.Directory]::CreateDirectory($Path) | Out-Null
    } catch {
        throw "无法创建目录: $Path`n$($_.Exception.Message)"
    }
}


# ==================== 工具检查 ====================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "c291dGhwbHVz 压缩包处理脚本" -ForegroundColor Cyan
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
Write-Host ""

# 创建输出目录
Ensure-Directory $Output

# ==================== 处理压缩包 ====================
Write-Host "查找并解压 .zip / .z01 / .7z / .7z.001 到 output" -ForegroundColor Yellow
Write-Host "----------------------------------------"

# 处理 .zip 和 .7z 文件（非分卷）
# 说明：PowerShell 5.1 下 -Include/-Recurse 组合在某些路径（尤其包含 [] 等通配符字符）时容易筛不到文件。
# 这里改为 -LiteralPath + -Filter（由文件系统提供方过滤），同时包含同目录与递归目录。
$archives = @()
$archives += Get-ChildItem -LiteralPath $WorkDir -Recurse -File -Filter "*.zip" -ErrorAction SilentlyContinue
$archives += Get-ChildItem -LiteralPath $WorkDir -Recurse -File -Filter "*.7z"  -ErrorAction SilentlyContinue

$archives = $archives |
    Where-Object {
        $_.FullName -notlike "*\output\*" -and
        $_.Name -notmatch '\.7z\.\d+$'    # 防御性：如果误抓到类似 xxx.7z.001 这种命名
    } |
    Sort-Object -Property FullName -Unique

foreach ($file in $archives) {
    # 计算相对路径
    $wdBase  = $WorkDir.TrimEnd('\') + '\'
    $relPath = if ($file.DirectoryName.StartsWith($wdBase, [StringComparison]::OrdinalIgnoreCase)) {
                   $file.DirectoryName.Substring($wdBase.Length).TrimEnd('\') } else { '' }

    # 确定目标目录
    if ($relPath) {
        $targetDir = Join-Path $Output $relPath
    } else {
        $targetDir = $Output
    }
    
    Ensure-Directory $targetDir
    
    # 检查是否有对应的 .z01 文件（zip分卷）
    $baseName = $file.BaseName
    $z01File = Join-Path $file.DirectoryName "$baseName.z01"
    
    if (Test-Path -LiteralPath $z01File) {
        # zip 分卷压缩包
        Write-Host "解压（zip分卷）: $($file.Name) → $targetDir" -ForegroundColor White
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
        
        Push-Location -LiteralPath $targetDir
        & $7zExe x "-p$Password" -y -bsp1 "$($file.FullName)"
        $exitCode = $LASTEXITCODE
        Pop-Location
        
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
        
        if ($exitCode -eq 0) {
            Write-Host "  ✓ 成功: $($file.Name)" -ForegroundColor Green
            if ($DeleteFlag) {
                Write-Host "  → 删除zip分卷文件: $baseName.z* 和 $baseName.zip" -ForegroundColor DarkGray
                $escapedBase = [regex]::Escape($baseName)
                Get-ChildItem -LiteralPath $file.DirectoryName -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match "^$escapedBase\.z\d+$" } |
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Host "  ✗ 失败: $($file.Name) (ExitCode: $exitCode)" -ForegroundColor Red
        }
    } else {
        # 普通压缩包
        Write-Host "解压: $($file.Name) → $targetDir" -ForegroundColor White
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
        
        Push-Location -LiteralPath $targetDir
        & $7zExe x "-p$Password" -y -bsp1 "$($file.FullName)"
        $exitCode = $LASTEXITCODE
        Pop-Location
        
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
        
        if ($exitCode -eq 0) {
            Write-Host "  ✓ 成功: $($file.Name)" -ForegroundColor Green
            if ($DeleteFlag) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                Write-Host "  → 已删除: $($file.FullName)" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  ✗ 失败: $($file.Name) (ExitCode: $exitCode)" -ForegroundColor Red
        }
    }
    Write-Host ""
}

# 处理 .7z.001 分卷压缩包
Write-Host ""
$volumeArchives = Get-ChildItem -LiteralPath $WorkDir -Recurse -File -Filter "*.7z.*" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.FullName -notlike "*\output\*" -and
        $_.Name -match '\.7z\.(0*1)$'     # 仅取首卷：xxx.7z.001 / xxx.7z.0001
    }

foreach ($file in $volumeArchives) {
    # 计算相对路径
    $wdBase  = $WorkDir.TrimEnd('\') + '\'
    $relPath = if ($file.DirectoryName.StartsWith($wdBase, [StringComparison]::OrdinalIgnoreCase)) {
                   $file.DirectoryName.Substring($wdBase.Length).TrimEnd('\') } else { '' }

    # 确定目标目录
    if ($relPath) {
        $targetDir = Join-Path $Output $relPath
    } else {
        $targetDir = $Output
    }
    
    Ensure-Directory $targetDir
    
    Write-Host "解压（7z分卷）: $($file.Name) → $targetDir" -ForegroundColor White
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    
    Push-Location -LiteralPath $targetDir
    & $7zExe x "-p$Password" -y -bsp1 "$($file.FullName)"
    $exitCode = $LASTEXITCODE
    Pop-Location
    
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    
    if ($exitCode -eq 0) {
        Write-Host "  ✓ 成功: $($file.Name)" -ForegroundColor Green
        if ($DeleteFlag) {
            $basePattern = $file.BaseName -replace '\.7z$', ''
            $escapedBase = [regex]::Escape($basePattern)
            Write-Host "  → 删除7z分卷文件: $basePattern.7z.*" -ForegroundColor DarkGray
            $volumeFiles = Get-ChildItem -LiteralPath $file.DirectoryName -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "^$escapedBase\.7z\.\d+$" }
            $volumeFiles | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        }
    } else {
        Write-Host "  ✗ 失败: $($file.Name) (ExitCode: $exitCode)" -ForegroundColor Red
    }
    Write-Host ""
}

# ==================== 清理空文件夹 ====================
if ($DeleteFlag) {
    Write-Host "清理空文件夹..." -ForegroundColor Yellow
    Write-Host "----------------------------------------"
    
    # 获取所有子目录，按深度倒序排列（先处理最深的）
    $allDirs = Get-ChildItem -LiteralPath $WorkDir -Directory -Recurse -ErrorAction SilentlyContinue | 
        Where-Object { 
            $_.FullName -notlike "*\output\*" -and 
            $_.FullName -ne $Output
        } | 
        Sort-Object { $_.FullName.Split('\').Count } -Descending
    
    $deletedCount = 0
    foreach ($dir in $allDirs) {
        # 检查目录是否为空
        $items = Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
        if ($items.Count -eq 0) {
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
} else {
    Write-Host "KeepFiles 模式，跳过空文件夹清理" -ForegroundColor Gray
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "全部完成！" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "按回车键退出"
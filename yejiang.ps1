#Requires -Version 5.1
<#
.SYNOPSIS
    yejiang.ps1 - 叶酱解压脚本 (PowerShell版)
.DESCRIPTION
    自动将 .mp4 文件还原并解压至 output0，再二次解压到 output 目录结构。
#>

# 统一编码设置
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ==================== 配置区域 ====================
# 删除标志：$true=解压后删除 zip 和源目录空文件夹；$false=保留 zip
$deleteFlag = $true

# 解压密码
$password = "yejiang"

# 路径变量
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$output0 = Join-Path $scriptDir "output0"
$output  = Join-Path $scriptDir "output"

# WinRAR 路径检测（兼容 64 位和 32 位）
$rarPaths = @(
    "$env:ProgramFiles\WinRAR\WinRAR.exe",
    "${env:ProgramFiles(x86)}\WinRAR\WinRAR.exe"
)

$rarPath = $null
foreach ($path in $rarPaths) {
    if (Test-Path $path) {
        $rarPath = $path
        break
    }
}

if (-not $rarPath) {
    Write-Host "[ERROR] 未找到 WinRAR，请先安装 WinRAR。" -ForegroundColor Red
    Write-Host "        下载地址: https://www.win-rar.com/download.html" -ForegroundColor Yellow
    Read-Host "按 Enter 退出"
    exit 1
}

Write-Host "[OK] 找到 WinRAR: $rarPath" -ForegroundColor Green
Write-Host ""

# 创建输出目录
if (-not (Test-Path -LiteralPath $output0)) {
    [System.IO.Directory]::CreateDirectory($output0) | Out-Null
}
if (-not (Test-Path -LiteralPath $output)) {
    [System.IO.Directory]::CreateDirectory($output) | Out-Null
}

# ==================== 辅助函数 ====================

function Test-ShouldSkip {
    param([string]$filePath)
    $p  = [IO.Path]::GetFullPath($filePath).TrimEnd('\')
    $ex0 = [IO.Path]::GetFullPath($output0).TrimEnd('\')
    $ex1 = [IO.Path]::GetFullPath($output).TrimEnd('\')
    foreach ($ex in @($ex0, $ex1)) {
        if ($p -ieq $ex -or $p.StartsWith($ex + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Invoke-WinRARExtract {
    param(
        [string]$archivePath,
        [string]$targetDir
    )
    if (-not (Test-Path -LiteralPath $targetDir)) {
        [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null
    }
    $proc = Start-Process -FilePath $rarPath -ArgumentList @('x', "-p$password", '-ibck', '-y', $archivePath, "$targetDir\") -Wait -PassThru -NoNewWindow
    return ($proc.ExitCode -eq 0)
}

# ==================== 步骤 1：将 .mp4 还原为 .zip 并解压到 output0 ====================
Write-Host "[STEP 1] 查找 .mp4 文件，还原为 .zip 并解压到 output0" -ForegroundColor Cyan
Write-Host ""

$mp4Files = Get-ChildItem -LiteralPath $scriptDir -Recurse -Filter "*.mp4" -File -ErrorAction SilentlyContinue

foreach ($file in $mp4Files) {
    if (Test-ShouldSkip $file.DirectoryName) { continue }

    $baseName    = $file.BaseName
    $zipFileName = "$baseName.zip"
    $zipFilePath = Join-Path $file.DirectoryName $zipFileName

    try {
        Rename-Item -LiteralPath $file.FullName -NewName $zipFileName -ErrorAction Stop
        Write-Host "[RENAME] $($file.Name) -> $zipFileName" -ForegroundColor Green
    }
    catch {
        Write-Host "[ERROR] 重命名失败: $($file.Name) - $($_.Exception.Message)" -ForegroundColor Red
        continue
    }

    Write-Host "[EXTRACT] $zipFileName -> output0\" -ForegroundColor Yellow

    $success = Invoke-WinRARExtract -archivePath $zipFilePath -targetDir $output0

    if ($success) {
        Write-Host "[OK] 解压成功: $zipFileName" -ForegroundColor Green
    }
    else {
        Write-Host "[ERROR] 解压失败: $zipFileName" -ForegroundColor Red
    }

    if ($deleteFlag) {
        if (Test-Path -LiteralPath $zipFilePath) {
            Write-Host "[CLEAN] 删除已解压的 zip: $zipFileName" -ForegroundColor DarkGray
            Remove-Item -LiteralPath $zipFilePath -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        Write-Host "[KEEP] 保留 zip 文件: $zipFileName" -ForegroundColor DarkGray
    }
}

# ==================== 步骤 2：将 output0 中的压缩包再次解压到 output ====================
Write-Host ""
Write-Host "[STEP 2] 从 output0 再次解压 .zip / .7z 到 output 目录..." -ForegroundColor Cyan

$archiveFiles = Get-ChildItem -LiteralPath $output0 -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -imatch '^\.(zip|7z)$' }

foreach ($file in $archiveFiles) {
    Write-Host "[EXTRACT] $($file.Name) -> output\" -ForegroundColor Yellow

    $success = Invoke-WinRARExtract -archivePath $file.FullName -targetDir $output

    if ($success) {
        Write-Host "[OK] 解压成功: $($file.Name)" -ForegroundColor Green

        if ($deleteFlag) {
            if (Test-Path -LiteralPath $file.FullName) {
                Write-Host "[CLEAN] 删除已解压文件: $($file.Name)" -ForegroundColor DarkGray
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            Write-Host "[KEEP] 保留源文件: $($file.Name)" -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host "[ERROR] 解压失败: $($file.Name)" -ForegroundColor Red
    }
}

# ==================== 清理空文件夹 ====================
Write-Host ""

if ($deleteFlag) {
    Write-Host "[CLEAN] 开始清理源目录的空文件夹（跳过 output）..." -ForegroundColor Cyan

    $allDirs = Get-ChildItem -LiteralPath $scriptDir -Directory -Recurse -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Split('\').Count } -Descending

    foreach ($dir in $allDirs) {
        $d   = [IO.Path]::GetFullPath($dir.FullName).TrimEnd('\')
        $ex0 = [IO.Path]::GetFullPath($output0).TrimEnd('\')
        $ex1 = [IO.Path]::GetFullPath($output).TrimEnd('\')
        # 跳过 output 及其子目录（output0 在解压完成后可正常被清除）
        if ($d -ieq $ex1 -or $d.StartsWith($ex1 + '\', [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $items = Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
        if ($null -ne $items -and @($items).Count -eq 0) {
            try {
                Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop
                Write-Host "[OK] 删除空文件夹: $($dir.FullName)" -ForegroundColor DarkGray
            }
            catch {
                # 忽略删除失败
            }
        }
    }
    Write-Host "[OK] 文件夹清理完成（已保留 output）" -ForegroundColor Green
}
else {
    Write-Host "[SKIP] deleteFlag=false，跳过文件夹清理" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "[DONE] 所有处理完成！" -ForegroundColor Green
Read-Host "按 Enter 退出"

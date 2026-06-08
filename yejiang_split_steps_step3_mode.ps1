#Requires -Version 5.1
<#
.SYNOPSIS
    yejiang_split_steps.ps1 - 分步解压脚本
.DESCRIPTION
    Step 1: 递归查找脚本目录下的 .mp4，排除 output0/output，重命名为同名 .zip
    Step 2: 递归查找脚本目录下的 .zip，排除 output0/output，按相对路径 + 压缩包名解压到 output0
    Step 3: 递归查找 output0 内的 .zip/.7z，解压到 output（可选平铺 或 保留目录结构）
.NOTES
    - 需要 WinRAR (WinRAR.exe) 支持命令行解压：x -p"password" -ibck -y "archive" "target\"
    - $deleteFlag 为 $true 时，Step 2/3 解压成功后删除源压缩包（mp4 在 Step1 已被重命名为 zip）
#>

# 统一编码设置
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ==================== 配置区域 ====================
# $true：解压成功后删除源 zip/7z；$false：保留源文件
$deleteFlag = $true

# 压缩包密码
$password = "yejiang"

# Step 3 解压模式：
#   $false：保留相对路径 + 压缩包名子目录（保留目录结构）
#   $true ：平铺解压到 output 根目录（忽略相对路径/压缩包名目录）
$step3Flatten = $false
# ===============================================

# 脚本目录与输出目录
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$output0   = Join-Path $scriptDir "output0"
$output    = Join-Path $scriptDir "output"

# WinRAR 路径（64 位/32 位）
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
    Write-Host "[ERROR] 未找到 WinRAR.exe，请先安装 WinRAR。" -ForegroundColor Red
    Write-Host "        安装后默认路径应为：%ProgramFiles%\WinRAR\WinRAR.exe" -ForegroundColor Yellow
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

function Get-FullNormPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-IsUnderPath {
    param(
        [Parameter(Mandatory=$true)][string]$ChildPath,
        [Parameter(Mandatory=$true)][string]$ParentPath
    )
    $c = Get-FullNormPath $ChildPath
    $p = Get-FullNormPath $ParentPath
    return ($c -ieq $p) -or ($c.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase))
}

# 是否在 output0/output 目录内（用于排除递归扫描）
function Test-ShouldSkipPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    return (Test-IsUnderPath $Path $output0) -or (Test-IsUnderPath $Path $output)
}

# 计算相对路径（纯字符串 Substring，避免 URI 编码问题）
function Get-RelativePath {
    param(
        [Parameter(Mandatory=$true)][string]$BasePath,
        [Parameter(Mandatory=$true)][string]$TargetPath
    )
    $base   = [IO.Path]::GetFullPath($BasePath.TrimEnd('\') + '\')
    $target = [IO.Path]::GetFullPath($TargetPath)
    if ($target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        return $target.Substring($base.Length).TrimEnd('\')
    }
    return ''
}

# 生成解压目标目录：OutputRoot\<相对路径>\<压缩包名>\
function Get-ExtractTargetDir {
    param(
        [Parameter(Mandatory=$true)][string]$ArchiveDir,
        [Parameter(Mandatory=$true)][string]$ArchiveBaseName,
        [Parameter(Mandatory=$true)][string]$InputRoot,
        [Parameter(Mandatory=$true)][string]$OutputRoot
    )
    $relDir = Get-RelativePath -BasePath $InputRoot -TargetPath $ArchiveDir
    $target = if ($relDir) { Join-Path $OutputRoot $relDir } else { $OutputRoot }
    return Join-Path $target $ArchiveBaseName
}

# 调用 WinRAR 解压
function Invoke-WinRARExtract {
    param(
        [Parameter(Mandatory=$true)][string]$archivePath,
        [Parameter(Mandatory=$true)][string]$targetDir
    )
    if (-not (Test-Path -LiteralPath $targetDir)) {
        [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null
    }
    $proc = Start-Process -FilePath $rarPath -ArgumentList @('x', "-p$password", '-ibck', '-y', $archivePath, "$targetDir\") -Wait -PassThru -NoNewWindow
    return ($proc.ExitCode -eq 0)
}

# ==================== STEP 1：mp4 -> zip（只重命名，不解压）====================
Write-Host "[STEP 1] 递归查找 .mp4 -> 重命名为 .zip，不解压" -ForegroundColor Cyan
Write-Host ""

$mp4Files = Get-ChildItem -LiteralPath $scriptDir -Recurse -Filter "*.mp4" -File -ErrorAction SilentlyContinue

foreach ($file in $mp4Files) {
    if (Test-ShouldSkipPath $file.FullName) { continue }

    $zipFileName = "$($file.BaseName).zip"
    $zipFilePath = Join-Path $file.DirectoryName $zipFileName

    if (Test-Path -LiteralPath $zipFilePath) {
        Write-Host "[SKIP] 已存在同名 zip，跳过重命名：$($file.FullName)" -ForegroundColor DarkYellow
        continue
    }

    try {
        Rename-Item -LiteralPath $file.FullName -NewName $zipFileName -ErrorAction Stop
        Write-Host "[RENAME] $($file.Name) -> $zipFileName" -ForegroundColor Green
    }
    catch {
        Write-Host "[ERROR] 重命名失败：$($file.FullName) - $($_.Exception.Message)" -ForegroundColor Red
        continue
    }
}

# ==================== STEP 2：扫描 .zip -> 解压到 output0（相对路径+压缩包名）====================
Write-Host ""
Write-Host "[STEP 2] 递归查找 .zip -> 解压到 output0（相对路径+压缩包名）" -ForegroundColor Cyan
Write-Host ""

$zipFiles = Get-ChildItem -LiteralPath $scriptDir -Recurse -Filter "*.zip" -File -ErrorAction SilentlyContinue

foreach ($file in $zipFiles) {
    if (Test-ShouldSkipPath $file.FullName) { continue }

    $extractDir = Get-ExtractTargetDir `
        -ArchiveDir      $file.DirectoryName `
        -ArchiveBaseName $file.BaseName `
        -InputRoot       $scriptDir `
        -OutputRoot      $output0

    Write-Host "[EXTRACT] $($file.FullName) -> $extractDir\" -ForegroundColor Yellow

    $success = Invoke-WinRARExtract -archivePath $file.FullName -targetDir $extractDir

    if ($success) {
        Write-Host "[OK] 解压成功: $($file.Name)" -ForegroundColor Green

        if ($deleteFlag) {
            try {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                Write-Host "[CLEAN] 已删除源压缩包: $($file.Name)" -ForegroundColor DarkGray
            }
            catch {
                Write-Host "[WARN] 删除源压缩包失败: $($file.FullName) - $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }
        else {
            Write-Host "[KEEP] 保留源压缩包: $($file.Name)" -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host "[ERROR] 解压失败: $($file.FullName)" -ForegroundColor Red
    }
}

# ==================== STEP 3：output0 二级解压 -> 解压到 output（可选平铺/目录结构）====================
Write-Host ""
$modeText = if ($step3Flatten) { "平铺到 output 根目录" } else { "保留相对路径+压缩包名子目录结构" }
Write-Host "[STEP 3] 递归查找 output0 内的 .zip/.7z -> 解压到 output（$modeText）" -ForegroundColor Cyan
Write-Host ""

$archiveFiles = Get-ChildItem -LiteralPath $output0 -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -imatch '^\.(zip|7z)$' }

foreach ($file in $archiveFiles) {
    $extractDir = if ($step3Flatten) {
        $output
    }
    else {
        Get-ExtractTargetDir `
            -ArchiveDir      $file.DirectoryName `
            -ArchiveBaseName $file.BaseName `
            -InputRoot       $output0 `
            -OutputRoot      $output
    }

    Write-Host "[EXTRACT] $($file.FullName) -> $extractDir\" -ForegroundColor Yellow

    $success = Invoke-WinRARExtract -archivePath $file.FullName -targetDir $extractDir

    if ($success) {
        Write-Host "[OK] 解压成功: $($file.Name)" -ForegroundColor Green

        if ($deleteFlag) {
            try {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                Write-Host "[CLEAN] 已删除源压缩包: $($file.Name)" -ForegroundColor DarkGray
            }
            catch {
                Write-Host "[WARN] 删除源压缩包失败: $($file.FullName) - $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }
        else {
            Write-Host "[KEEP] 保留源压缩包: $($file.Name)" -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host "[ERROR] 解压失败: $($file.FullName)" -ForegroundColor Red
    }
}

# ==================== 清理空文件夹（可选）====================
Write-Host ""

if ($deleteFlag) {
    Write-Host "[CLEAN] 删除源目录的空文件夹（跳过 output0/output）..." -ForegroundColor Cyan

    $allDirs = Get-ChildItem -LiteralPath $scriptDir -Directory -Recurse -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Split('\').Count } -Descending

    foreach ($dir in $allDirs) {
        if ((Test-IsUnderPath $dir.FullName $output0) -or (Test-IsUnderPath $dir.FullName $output)) {
            continue
        }

        $items = Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
        if ($null -ne $items -and @($items).Count -eq 0) {
            try {
                Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop
                Write-Host "[OK] 已删除空目录: $($dir.FullName)" -ForegroundColor DarkGray
            }
            catch { }
        }
    }

    Write-Host "[OK] 完成！output0/output 已保留" -ForegroundColor Green
}
else {
    Write-Host "[SKIP] deleteFlag=false，跳过空目录清理" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "[DONE] 完成！" -ForegroundColor Green
Read-Host "按 Enter 退出"

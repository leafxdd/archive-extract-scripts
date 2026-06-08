#Requires -Version 5.1
<#
.SYNOPSIS
    extract.ps1 - 统一解压脚本（合并所有来源）
.DESCRIPTION
    启动后显示交互式菜单，选择来源后自动执行对应的解压管线。
    支持 zip/7z/rar/所有分卷格式，自动处理 mp4 伪装。
#>

param(
    [string]$WorkDir = $PSScriptRoot,
    [switch]$KeepFiles = $false
)

# ==================== 初始化 ====================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

$7zExe     = Join-Path $env:ProgramFiles "7-Zip-Zstandard\7z.exe"
$WinRarExe = Join-Path $env:ProgramFiles "WinRAR\WinRAR.exe"
$DeleteFlag = -not $KeepFiles

# ==================== 来源配置 ====================
$Profiles = [ordered]@{
    'yecgaa'        = @{ Password='yecgaa';        Pipeline='standard';    SmartExtract=$false; JunkFiles=@();                        Need7z=$true;  NeedWinRAR=$true  }
    'FLYYZ'         = @{ Password='FLYYZ';         Pipeline='standard';    SmartExtract=$false; JunkFiles=@();                        Need7z=$true;  NeedWinRAR=$true  }
    'doro'          = @{ Password='doro';           Pipeline='three-stage'; SmartExtract=$true;  JunkFiles=@('好用的VPN和AI茶馆.txt'); Need7z=$true;  NeedWinRAR=$true  }
    'PADIO294'      = @{ Password='PADIO294';       Pipeline='standard';    SmartExtract=$true;  JunkFiles=@();                        Need7z=$true;  NeedWinRAR=$true  }
    'c291dGhwbHVz'  = @{ Password='c291dGhwbHVz';  Pipeline='direct';      SmartExtract=$false; JunkFiles=@();                        Need7z=$true;  NeedWinRAR=$false }
    'yejiang'       = @{ Password='yejiang';        Pipeline='yejiang';     SmartExtract=$false; JunkFiles=@();                        Need7z=$false; NeedWinRAR=$true  }
}

# ==================== 交互式菜单 ====================
function Show-Menu {
    param(
        [string]$Title,
        [string[]]$Options
    )

    $selected = 0
    $cursorVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false

    $TL = [char]0x2554; $TR = [char]0x2557; $BL = [char]0x255A; $BR = [char]0x255D
    $H  = [char]0x2550; $V  = [char]0x2551; $ML = [char]0x2560; $MR = [char]0x2563

    # 计算字符串的终端显示宽度（CJK/全角字符占2列）
    function Get-DisplayWidth([string]$s) {
        $w = 0
        foreach ($c in $s.ToCharArray()) {
            $code = [int]$c
            if (($code -ge 0x1100 -and $code -le 0x115F) -or
                ($code -ge 0x2E80 -and $code -le 0xA4CF -and $code -ne 0x303F) -or
                ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
                ($code -ge 0xF900 -and $code -le 0xFAFF) -or
                ($code -ge 0xFE10 -and $code -le 0xFE6F) -or
                ($code -ge 0xFF01 -and $code -le 0xFF60) -or
                ($code -ge 0xFFE0 -and $code -le 0xFFE6)) {
                $w += 2
            } else { $w += 1 }
        }
        return $w
    }

    # 用空格填充到指定显示宽度
    function Pad-ToDisplayWidth([string]$s, [int]$targetWidth) {
        $dw = Get-DisplayWidth $s
        $pad = $targetWidth - $dw
        if ($pad -gt 0) { return $s + (' ' * $pad) }
        return $s
    }

    # 自适应宽度：按显示宽度计算
    $allLines = @(" $Title ") + ($Options | ForEach-Object { "  > $_" })
    $maxDW = ($allLines | ForEach-Object { Get-DisplayWidth $_ } | Measure-Object -Maximum).Maximum
    $width = [Math]::Max($maxDW + 2, 30)

    try {
        while ($true) {
            [Console]::Clear()
            $border = "$H" * $width
            Write-Host "$TL$border$TR" -ForegroundColor Cyan
            $titleText = Pad-ToDisplayWidth " $Title " $width
            Write-Host "$V$titleText$V" -ForegroundColor Cyan
            Write-Host "$ML$border$MR" -ForegroundColor Cyan

            for ($i = 0; $i -lt $Options.Count; $i++) {
                $marker = if ($i -eq $selected) { '>' } else { ' ' }
                $text = Pad-ToDisplayWidth "  $marker $($Options[$i])" $width
                if ($i -eq $selected) {
                    Write-Host "$V" -NoNewline -ForegroundColor Cyan
                    Write-Host $text -NoNewline -ForegroundColor Green
                    Write-Host "$V" -ForegroundColor Cyan
                } else {
                    Write-Host "$V" -NoNewline -ForegroundColor Cyan
                    Write-Host $text -NoNewline -ForegroundColor White
                    Write-Host "$V" -ForegroundColor Cyan
                }
            }

            Write-Host "$BL$border$BR" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  Up/Down to move, Enter to select, Esc to quit" -ForegroundColor DarkGray

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $selected = if ($selected -gt 0) { $selected - 1 } else { $Options.Count - 1 } }
                'DownArrow' { $selected = if ($selected -lt $Options.Count - 1) { $selected + 1 } else { 0 } }
                'Enter'     { return $selected }
                'Escape'    { return -1 }
            }
        }
    } finally {
        [Console]::CursorVisible = $cursorVisible
    }
}

# ==================== 共享工具函数 ====================

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    try { return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\','/') }
    catch { return $Path.TrimEnd('\','/') }
}

function Test-IsUnderPath {
    param(
        [Parameter(Mandatory)][string]$ChildPath,
        [Parameter(Mandatory)][string]$ParentPath
    )
    $c = Get-NormalizedPath $ChildPath
    $p = Get-NormalizedPath $ParentPath
    return ($c -ieq $p) -or ($c.StartsWith($p + '\', [System.StringComparison]::OrdinalIgnoreCase))
}

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
        $skip = $false
        foreach ($ex in $excludeNorm) {
            if ($ex -and (Test-IsUnderPath -ChildPath $f.FullName -ParentPath $ex)) { $skip = $true; break }
        }
        if ($skip) { continue }

        $name = $f.Name
        $full = $f.FullName

        # RAR
        if ($f.Extension -ieq '.rar') {
            if ($name -match '^(?<stem>.+?)\.part(?<part>\d+)\.rar$') {
                $partNum = 0; [void][int]::TryParse($Matches.part, [ref]$partNum)
                if ($partNum -ne 1) { continue }
                if ($seen.Add($full)) { $entries.Add([pscustomobject]@{ Path=$full; Type='rar-part'; Dir=$f.DirectoryName; Base=$Matches.stem }) }
                continue
            }
            $r00 = Join-Path $f.DirectoryName ($f.BaseName + '.r00')
            $type = if (Test-Path -LiteralPath $r00) { 'rar-r00' } else { 'rar' }
            if ($seen.Add($full)) { $entries.Add([pscustomobject]@{ Path=$full; Type=$type; Dir=$f.DirectoryName; Base=$f.BaseName }) }
            continue
        }

        # ZIP / 7Z
        if ($f.Extension -ieq '.zip' -or $f.Extension -ieq '.7z') {
            $isZipSplitZ = $false
            if ($f.Extension -ieq '.zip') {
                $z01 = Join-Path $f.DirectoryName ($f.BaseName + '.z01')
                $isZipSplitZ = Test-Path -LiteralPath $z01
            }
            $type = if ($isZipSplitZ) { 'zip-z' } else { $f.Extension.TrimStart('.') }
            if ($seen.Add($full)) { $entries.Add([pscustomobject]@{ Path=$full; Type=$type; Dir=$f.DirectoryName; Base=$f.BaseName }) }
            continue
        }

        # 数字分卷 xxx.7z.001 / xxx.zip.001
        if ($name -match '^(?<stem>.+?)\.(?<fmt>7z|zip)\.(?<part>\d+)$') {
            $fmt = $Matches.fmt.ToLowerInvariant()
            $partNum = 0; [void][int]::TryParse($Matches.part, [ref]$partNum)
            if ($partNum -ne 1) { continue }
            $type = "$fmt-001"
            if ($seen.Add($full)) { $entries.Add([pscustomobject]@{ Path=$full; Type=$type; Dir=$f.DirectoryName; Base=$Matches.stem }) }
            continue
        }

        # 传统 ZIP 分卷 xxx.z01
        if ($name -match '^(?<stem>.+?)\.z(?<part>\d+)$') {
            $partNum = 0; [void][int]::TryParse($Matches.part, [ref]$partNum)
            if ($partNum -ne 1) { continue }
            $zipCandidate = Join-Path $f.DirectoryName ($Matches.stem + '.zip')
            if (Test-Path -LiteralPath $zipCandidate) {
                if ($seen.Add($zipCandidate)) { $entries.Add([pscustomobject]@{ Path=$zipCandidate; Type='zip-z'; Dir=$f.DirectoryName; Base=$Matches.stem }) }
            } else {
                if ($seen.Add($full)) { $entries.Add([pscustomobject]@{ Path=$full; Type='zip-z01'; Dir=$f.DirectoryName; Base=$Matches.stem }) }
            }
            continue
        }
    }
    return $entries
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
            default { Remove-Item -LiteralPath $Entry.Path -Force -ErrorAction SilentlyContinue }
        }
        return $true
    } catch { return $false }
}

# ==================== 解压函数 ====================

function Invoke-WinRARExtract {
    param([string]$ArchivePath, [string]$TargetDir, [string]$Pwd)
    if (-not (Test-Path -LiteralPath $TargetDir)) { [System.IO.Directory]::CreateDirectory($TargetDir) | Out-Null }
    $proc = Start-Process -FilePath $WinRarExe -ArgumentList @('x', "-p$Pwd", '-ibck', '-y', "`"$ArchivePath`"", "`"$TargetDir\`"") -Wait -PassThru -NoNewWindow
    return ($proc.ExitCode -eq 0)
}

function Invoke-7zExtract {
    param([string]$ArchivePath, [string]$TargetDir, [string]$Pwd)
    if (-not (Test-Path -LiteralPath $TargetDir)) { [System.IO.Directory]::CreateDirectory($TargetDir) | Out-Null }
    & $7zExe x "-p$Pwd" -aoa -y "-o$TargetDir" $ArchivePath
    return ($LASTEXITCODE -eq 0)
}

function Test-ArchiveHasRootFolder {
    param([string]$ArchivePath, [string]$Pwd)
    try {
        $result = & $7zExe l "-p$Pwd" -slt -- $ArchivePath 2>&1
        if ($LASTEXITCODE -ne 0) { return $false }
        $entries = @(); $cur = @{}
        foreach ($line in $result) {
            if ($line -match '^Path = (.+)$') {
                if ($cur.Count -gt 0) { $entries += [PSCustomObject]$cur }
                $cur = @{ Path = $matches[1] }
            } elseif ($line -match '^Folder = (.+)$') { $cur['Folder'] = $matches[1] }
            elseif ($line -match '^Attributes = (.+)$') { $cur['Attributes'] = $matches[1] }
        }
        if ($cur.Count -gt 0) { $entries += [PSCustomObject]$cur }
        foreach ($entry in $entries) {
            $p = $entry.Path
            if ($p -eq (Split-Path $ArchivePath -Leaf)) { continue }
            $clean = $p.TrimEnd('\','/')
            if ($clean -notmatch '[/\\]') {
                if (($entry.Folder -eq '+') -or ($entry.Attributes -match '^D') -or $p.EndsWith('\') -or $p.EndsWith('/')) { return $true }
            }
        }
        return $false
    } catch { return $false }
}

function Expand-ArchiveSmart {
    param([System.IO.FileInfo]$File, [string]$OutputDir, [string]$Pwd)
    $hasRoot = Test-ArchiveHasRootFolder -ArchivePath $File.FullName -Pwd $Pwd
    if ($hasRoot) {
        $targetDir = $OutputDir
        Write-Host "  (根目录含文件夹，直接解压)" -ForegroundColor DarkGray
    } else {
        $targetDir = Join-Path $OutputDir $File.BaseName
        Write-Host "  (根目录无文件夹，创建子目录: $($File.BaseName))" -ForegroundColor DarkGray
    }
    return (Invoke-7zExtract -ArchivePath $File.FullName -TargetDir $targetDir -Pwd $Pwd)
}

function Process-Archives {
    param([string]$SourceDir, [string]$TargetDir, [string]$Pwd, [bool]$Delete, [bool]$Smart = $false)
    $maxPasses = 10
    $processed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    for ($pass = 1; $pass -le $maxPasses; $pass++) {
        $entries = Get-ArchiveEntrypoints -RootDir $SourceDir
        if ($entries) { $entries = @($entries | Where-Object { -not $processed.Contains($_.Path) }) }
        if (-not $entries -or $entries.Count -eq 0) {
            if ($pass -eq 1) { Write-Host "未发现可解压的压缩包" -ForegroundColor Gray }
            break
        }
        Write-Host "`n[PASS $pass] 发现 $($entries.Count) 个压缩包入口" -ForegroundColor Cyan
        foreach ($e in $entries) {
            $label = switch ($e.Type) { 'zip-z' { 'zip分卷(z01)' }; 'zip-001' { 'zip分卷(001)' }; '7z-001' { '7z分卷' }; default { $e.Type } }
            Write-Host "[EXTRACT] ($label) $(Split-Path -Leaf $e.Path)" -ForegroundColor Yellow
            if ($Smart) {
                $fi = Get-Item -LiteralPath $e.Path
                $success = Expand-ArchiveSmart -File $fi -OutputDir $TargetDir -Pwd $Pwd
            } else {
                $success = Invoke-7zExtract -ArchivePath $e.Path -TargetDir $TargetDir -Pwd $Pwd
            }
            [void]$processed.Add($e.Path)
            if ($success) {
                Write-Host "  ✓ 成功" -ForegroundColor Green
                if ($Delete) { [void](Remove-ArchiveGroup -Entry $e); Write-Host "  → 已删除源压缩包" -ForegroundColor DarkGray }
            } else {
                Write-Host "  ✗ 失败" -ForegroundColor Red
            }
        }
    }
}

function Remove-EmptyDirs {
    param([string]$Root, [string[]]$ProtectDirs)
    $allDirs = Get-ChildItem -LiteralPath $Root -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $d = $_.FullName; -not ($ProtectDirs | Where-Object { Test-IsUnderPath $d $_ }) } |
        Sort-Object { $_.FullName.Split('\').Count } -Descending
    $count = 0
    foreach ($dir in $allDirs) {
        $items = Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
        if ($items.Count -eq 0) {
            try { Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop; $count++ } catch { }
        }
    }
    if ($count -gt 0) { Write-Host "清理了 $count 个空文件夹" -ForegroundColor Green }
}

# ==================== 管线函数 ====================

function Invoke-StandardPipeline {
    param([hashtable]$Prof)
    $pwd_ = $Prof.Password
    $Output0 = Join-Path $WorkDir "output0"
    $Output  = Join-Path $WorkDir "output"
    if (-not (Test-Path -LiteralPath $Output0)) { [System.IO.Directory]::CreateDirectory($Output0) | Out-Null }
    if (-not (Test-Path -LiteralPath $Output))  { [System.IO.Directory]::CreateDirectory($Output)  | Out-Null }

    # 步骤 0: mp4 → zip
    Write-Host "`n步骤 0: 重命名 .mp4 → .zip" -ForegroundColor Yellow
    Write-Host "----------------------------------------"
    $mp4Files = Get-ChildItem -LiteralPath $WorkDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.mp4' -and -not (Test-IsUnderPath $_.FullName $Output0) -and -not (Test-IsUnderPath $_.FullName $Output) }
    foreach ($file in $mp4Files) {
        $newName = $file.BaseName + ".zip"
        try { Rename-Item -LiteralPath $file.FullName -NewName $newName -ErrorAction Stop; Write-Host "[RENAME] $($file.Name) → $newName" -ForegroundColor Green }
        catch { Write-Host "[ERROR] 重命名失败: $($file.Name) - $_" -ForegroundColor Red }
    }

    # 步骤 1: 解压到 output0
    Write-Host "`n步骤 1: 解压到 output0" -ForegroundColor Yellow
    Write-Host "----------------------------------------"
    $entries = Get-ArchiveEntrypoints -RootDir $WorkDir -ExcludeDirs @($Output, $Output0)
    if (-not $entries -or $entries.Count -eq 0) {
        Write-Host "未发现压缩包" -ForegroundColor Gray
    } else {
        foreach ($e in $entries) {
            $label = switch ($e.Type) { 'zip-z' { 'zip分卷(z01)' }; 'zip-001' { 'zip分卷(001)' }; '7z-001' { '7z分卷' }; default { $e.Type } }
            Write-Host "[EXTRACT] ($label) $(Split-Path -Leaf $e.Path) → output0" -ForegroundColor Yellow
            if ($e.Type -imatch '^7z') {
                $success = Invoke-7zExtract -ArchivePath $e.Path -TargetDir $Output0 -Pwd $pwd_
            } else {
                $success = Invoke-WinRARExtract -ArchivePath $e.Path -TargetDir $Output0 -Pwd $pwd_
            }
            if ($success) {
                Write-Host "  ✓ 成功" -ForegroundColor Green
                if ($DeleteFlag) { [void](Remove-ArchiveGroup -Entry $e); Write-Host "  → 已删除源压缩包" -ForegroundColor DarkGray }
            } else { Write-Host "  ✗ 失败" -ForegroundColor Red }
        }
    }

    # 步骤 2: output0 → output (7z 多轮)
    Write-Host "`n步骤 2: output0 → output" -ForegroundColor Yellow
    Write-Host "----------------------------------------"
    if ($Prof.SmartExtract) {
        Process-Archives -SourceDir $Output0 -TargetDir $Output -Pwd $pwd_ -Delete $DeleteFlag -Smart $true
    } else {
        Process-Archives -SourceDir $Output0 -TargetDir $Output -Pwd $pwd_ -Delete $DeleteFlag
    }

    # 清理
    Write-Host "`n清理..." -ForegroundColor Yellow
    if ($DeleteFlag -and (Test-Path -LiteralPath $Output0)) {
        $remaining = Get-ChildItem -LiteralPath $Output0 -Recurse -File -ErrorAction SilentlyContinue
        if (-not $remaining) {
            Remove-Item -LiteralPath $Output0 -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "✓ 已删除 output0" -ForegroundColor Green
        } else {
            Write-Host "⚠ output0 中仍有文件（解压失败残留），已保留以供排查" -ForegroundColor Yellow
        }
    }
    if ($DeleteFlag) { Remove-EmptyDirs -Root $WorkDir -ProtectDirs @($Output, $Output0) }
}

function Invoke-ThreeStagePipeline {
    param([hashtable]$Prof)
    $pwd_ = $Prof.Password
    $Output0 = Join-Path $WorkDir "output0"
    $Output1 = Join-Path $WorkDir "output1"
    $Output  = Join-Path $WorkDir "output"
    foreach ($d in @($Output0, $Output1, $Output)) {
        if (-not (Test-Path -LiteralPath $d)) { [System.IO.Directory]::CreateDirectory($d) | Out-Null }
    }

    # 步骤 0: mp4 → zip
    Write-Host "`n步骤 0: 重命名 .mp4 → .zip" -ForegroundColor Yellow
    Write-Host "----------------------------------------"
    $mp4Files = Get-ChildItem -LiteralPath $WorkDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.mp4' -and -not (Test-IsUnderPath $_.FullName $Output) -and -not (Test-IsUnderPath $_.FullName $Output0) -and -not (Test-IsUnderPath $_.FullName $Output1) }
    foreach ($file in $mp4Files) {
        $newName = $file.BaseName + ".zip"
        try { Rename-Item -LiteralPath $file.FullName -NewName $newName -ErrorAction Stop; Write-Host "[RENAME] $($file.Name) → $newName" -ForegroundColor Green }
        catch { Write-Host "[ERROR] 重命名失败: $($file.Name) - $_" -ForegroundColor Red }
    }

    # 步骤 1: WinRAR → output0
    Write-Host "`n步骤 1: 解压到 output0 (WinRAR)" -ForegroundColor Yellow
    Write-Host "----------------------------------------"
    $zipFiles = Get-ChildItem -LiteralPath $WorkDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match '^\.(zip|7z)$' -and $_.Name -notmatch '\.7z\.\d+$' -and -not (Test-IsUnderPath $_.FullName $Output) -and -not (Test-IsUnderPath $_.FullName $Output0) -and -not (Test-IsUnderPath $_.FullName $Output1) }
    foreach ($file in $zipFiles) {
        Write-Host "[EXTRACT] $($file.Name) → output0" -ForegroundColor Yellow
        $success = Invoke-WinRARExtract -ArchivePath $file.FullName -TargetDir $Output0 -Pwd $pwd_
        if ($success) {
            Write-Host "  ✓ 成功" -ForegroundColor Green
            if ($DeleteFlag) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue; Write-Host "  → 已删除" -ForegroundColor DarkGray }
        } else { Write-Host "  ✗ 失败" -ForegroundColor Red }
    }

    # 步骤 2: output0 → output1 (7z 普通)
    Write-Host "`n步骤 2: output0 → output1 (7z)" -ForegroundColor Yellow
    Write-Host "----------------------------------------"
    Process-Archives -SourceDir $Output0 -TargetDir $Output1 -Pwd $pwd_ -Delete $DeleteFlag

    # 步骤 3: output1 → output (7z 智能)
    Write-Host "`n步骤 3: output1 → output (智能解压)" -ForegroundColor Yellow
    Write-Host "----------------------------------------"
    Process-Archives -SourceDir $Output1 -TargetDir $Output -Pwd $pwd_ -Delete $DeleteFlag -Smart $true

    # 垃圾文件清理
    if ($Prof.JunkFiles.Count -gt 0) {
        Write-Host "`n清理垃圾文件..." -ForegroundColor Yellow
        Get-ChildItem -LiteralPath $Output -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $Prof.JunkFiles -contains $_.Name } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue; Write-Host "  已删除: $($_.Name)" -ForegroundColor DarkGray }
    }

    # 清理中间目录
    Write-Host "`n清理..." -ForegroundColor Yellow
    if ($DeleteFlag) {
        foreach ($d in @($Output0, $Output1)) {
            if (Test-Path -LiteralPath $d) {
                $remaining = Get-ChildItem -LiteralPath $d -Recurse -File -ErrorAction SilentlyContinue
                if (-not $remaining) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "✓ 已删除 $(Split-Path -Leaf $d)" -ForegroundColor Green }
                else { Write-Host "⚠ $(Split-Path -Leaf $d) 中仍有文件，已保留" -ForegroundColor Yellow }
            }
        }
        Remove-EmptyDirs -Root $WorkDir -ProtectDirs @($Output, $Output0, $Output1)
    }
}

function Invoke-DirectPipeline {
    param([hashtable]$Prof)
    $pwd_ = $Prof.Password
    $Output = Join-Path $WorkDir "output"
    if (-not (Test-Path -LiteralPath $Output)) { [System.IO.Directory]::CreateDirectory($Output) | Out-Null }

    # 直接解压（保持相对路径）
    Write-Host "`n解压到 output（保持相对路径）" -ForegroundColor Yellow
    Write-Host "----------------------------------------"
    $entries = Get-ArchiveEntrypoints -RootDir $WorkDir -ExcludeDirs @($Output)
    if (-not $entries -or $entries.Count -eq 0) {
        Write-Host "未发现压缩包" -ForegroundColor Gray
    } else {
        foreach ($e in $entries) {
            $wdBase = $WorkDir.TrimEnd('\') + '\'
            $relPath = if ($e.Dir.StartsWith($wdBase, [StringComparison]::OrdinalIgnoreCase)) { $e.Dir.Substring($wdBase.Length).TrimEnd('\') } else { '' }
            $targetDir = if ($relPath) { Join-Path $Output $relPath } else { $Output }
            if (-not (Test-Path -LiteralPath $targetDir)) { [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null }

            $label = switch ($e.Type) { 'zip-z' { 'zip分卷(z01)' }; 'zip-001' { 'zip分卷(001)' }; '7z-001' { '7z分卷' }; default { $e.Type } }
            Write-Host "[EXTRACT] ($label) $(Split-Path -Leaf $e.Path) → $targetDir" -ForegroundColor Yellow
            $success = Invoke-7zExtract -ArchivePath $e.Path -TargetDir $targetDir -Pwd $pwd_
            if ($success) {
                Write-Host "  ✓ 成功" -ForegroundColor Green
                if ($DeleteFlag) { [void](Remove-ArchiveGroup -Entry $e); Write-Host "  → 已删除源压缩包" -ForegroundColor DarkGray }
            } else { Write-Host "  ✗ 失败" -ForegroundColor Red }
        }
    }

    if ($DeleteFlag) { Remove-EmptyDirs -Root $WorkDir -ProtectDirs @($Output) }
}

function Invoke-YejiangPipeline {
    param([string]$SubMode)
    $pwd_ = 'yejiang'
    $output0 = Join-Path $WorkDir "output0"
    $output  = Join-Path $WorkDir "output"
    if (-not (Test-Path -LiteralPath $output0)) { [System.IO.Directory]::CreateDirectory($output0) | Out-Null }
    if (-not (Test-Path -LiteralPath $output))  { [System.IO.Directory]::CreateDirectory($output)  | Out-Null }

    # 步骤 1: mp4 → zip
    Write-Host "`n步骤 1: 重命名 .mp4 → .zip" -ForegroundColor Yellow
    Write-Host "----------------------------------------"
    $mp4Files = Get-ChildItem -LiteralPath $WorkDir -Recurse -Filter "*.mp4" -File -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-IsUnderPath $_.FullName $output0) -and -not (Test-IsUnderPath $_.FullName $output) }
    foreach ($file in $mp4Files) {
        $newName = "$($file.BaseName).zip"
        try { Rename-Item -LiteralPath $file.FullName -NewName $newName -ErrorAction Stop; Write-Host "[RENAME] $($file.Name) → $newName" -ForegroundColor Green }
        catch { Write-Host "[ERROR] 重命名失败: $($file.Name) - $_" -ForegroundColor Red }
    }

    switch ($SubMode) {
        'simple' {
            # 步骤 2: zip → output0 (WinRAR)
            Write-Host "`n步骤 2: 解压 .zip → output0" -ForegroundColor Yellow
            $zipFiles = Get-ChildItem -LiteralPath $WorkDir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -ieq '.zip' -and -not (Test-IsUnderPath $_.FullName $output0) -and -not (Test-IsUnderPath $_.FullName $output) }
            foreach ($file in $zipFiles) {
                Write-Host "[EXTRACT] $($file.Name) → output0" -ForegroundColor Yellow
                $success = Invoke-WinRARExtract -ArchivePath $file.FullName -TargetDir $output0 -Pwd $pwd_
                if ($success) {
                    Write-Host "  ✓ 成功" -ForegroundColor Green
                    if ($DeleteFlag) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
                } else { Write-Host "  ✗ 失败" -ForegroundColor Red }
            }
            # 步骤 3: output0 → output (WinRAR)
            Write-Host "`n步骤 3: output0 → output" -ForegroundColor Yellow
            $archFiles = Get-ChildItem -LiteralPath $output0 -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -imatch '^\.(zip|7z)$' }
            foreach ($file in $archFiles) {
                Write-Host "[EXTRACT] $($file.Name) → output" -ForegroundColor Yellow
                $success = Invoke-WinRARExtract -ArchivePath $file.FullName -TargetDir $output -Pwd $pwd_
                if ($success) {
                    Write-Host "  ✓ 成功" -ForegroundColor Green
                    if ($DeleteFlag) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
                } else { Write-Host "  ✗ 失败" -ForegroundColor Red }
            }
        }
        'split-structured' {
            $scriptDir = $WorkDir
            # 步骤 2: zip → output0 (保留相对路径+压缩包名)
            Write-Host "`n步骤 2: 解压 .zip → output0 (保留目录结构)" -ForegroundColor Yellow
            $zipFiles = Get-ChildItem -LiteralPath $scriptDir -Recurse -Filter "*.zip" -File -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-IsUnderPath $_.FullName $output0) -and -not (Test-IsUnderPath $_.FullName $output) }
            foreach ($file in $zipFiles) {
                $base = [IO.Path]::GetFullPath($scriptDir.TrimEnd('\') + '\')
                $target = [IO.Path]::GetFullPath($file.DirectoryName)
                $relDir = if ($target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { $target.Substring($base.Length).TrimEnd('\') } else { '' }
                $extractDir = if ($relDir) { Join-Path (Join-Path $output0 $relDir) $file.BaseName } else { Join-Path $output0 $file.BaseName }
                Write-Host "[EXTRACT] $($file.Name) → $extractDir" -ForegroundColor Yellow
                $success = Invoke-WinRARExtract -ArchivePath $file.FullName -TargetDir $extractDir -Pwd $pwd_
                if ($success) {
                    Write-Host "  ✓ 成功" -ForegroundColor Green
                    if ($DeleteFlag) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
                } else { Write-Host "  ✗ 失败" -ForegroundColor Red }
            }
            # 步骤 3: output0 → output (保留目录结构)
            Write-Host "`n步骤 3: output0 → output (保留目录结构)" -ForegroundColor Yellow
            $archFiles = Get-ChildItem -LiteralPath $output0 -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -imatch '^\.(zip|7z)$' }
            foreach ($file in $archFiles) {
                $base = [IO.Path]::GetFullPath($output0.TrimEnd('\') + '\')
                $target = [IO.Path]::GetFullPath($file.DirectoryName)
                $relDir = if ($target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { $target.Substring($base.Length).TrimEnd('\') } else { '' }
                $extractDir = if ($relDir) { Join-Path (Join-Path $output $relDir) $file.BaseName } else { Join-Path $output $file.BaseName }
                Write-Host "[EXTRACT] $($file.Name) → $extractDir" -ForegroundColor Yellow
                $success = Invoke-WinRARExtract -ArchivePath $file.FullName -TargetDir $extractDir -Pwd $pwd_
                if ($success) {
                    Write-Host "  ✓ 成功" -ForegroundColor Green
                    if ($DeleteFlag) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
                } else { Write-Host "  ✗ 失败" -ForegroundColor Red }
            }
        }
        'split-flatten' {
            # 步骤 2: 同 split-structured
            Write-Host "`n步骤 2: 解压 .zip → output0 (保留目录结构)" -ForegroundColor Yellow
            $zipFiles = Get-ChildItem -LiteralPath $WorkDir -Recurse -Filter "*.zip" -File -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-IsUnderPath $_.FullName $output0) -and -not (Test-IsUnderPath $_.FullName $output) }
            foreach ($file in $zipFiles) {
                $base = [IO.Path]::GetFullPath($WorkDir.TrimEnd('\') + '\')
                $target = [IO.Path]::GetFullPath($file.DirectoryName)
                $relDir = if ($target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { $target.Substring($base.Length).TrimEnd('\') } else { '' }
                $extractDir = if ($relDir) { Join-Path (Join-Path $output0 $relDir) $file.BaseName } else { Join-Path $output0 $file.BaseName }
                Write-Host "[EXTRACT] $($file.Name) → $extractDir" -ForegroundColor Yellow
                $success = Invoke-WinRARExtract -ArchivePath $file.FullName -TargetDir $extractDir -Pwd $pwd_
                if ($success) {
                    Write-Host "  ✓ 成功" -ForegroundColor Green
                    if ($DeleteFlag) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
                } else { Write-Host "  ✗ 失败" -ForegroundColor Red }
            }
            # 步骤 3: output0 → output (平铺)
            Write-Host "`n步骤 3: output0 → output (平铺)" -ForegroundColor Yellow
            $archFiles = Get-ChildItem -LiteralPath $output0 -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -imatch '^\.(zip|7z)$' }
            foreach ($file in $archFiles) {
                Write-Host "[EXTRACT] $($file.Name) → output (平铺)" -ForegroundColor Yellow
                $success = Invoke-WinRARExtract -ArchivePath $file.FullName -TargetDir $output -Pwd $pwd_
                if ($success) {
                    Write-Host "  ✓ 成功" -ForegroundColor Green
                    if ($DeleteFlag) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
                } else { Write-Host "  ✗ 失败" -ForegroundColor Red }
            }
        }
    }

    # 清理
    if ($DeleteFlag) {
        if (Test-Path -LiteralPath $output0) {
            $remaining = Get-ChildItem -LiteralPath $output0 -Recurse -File -ErrorAction SilentlyContinue
            if (-not $remaining) { Remove-Item -LiteralPath $output0 -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "✓ 已删除 output0" -ForegroundColor Green }
            else { Write-Host "⚠ output0 中仍有文件（解压失败残留），已保留以供排查" -ForegroundColor Yellow }
        }
        Remove-EmptyDirs -Root $WorkDir -ProtectDirs @($output, $output0)
    }
}

# ==================== 主入口 ====================

# 一级菜单
$profileKeys = @($Profiles.Keys)
$menuOptions = $profileKeys | ForEach-Object {
    $p = $Profiles[$_]
    $desc = switch ($p.Pipeline) {
        'standard'    { "mp4->output0->output" }
        'three-stage' { "mp4->output0->output1->output" }
        'direct'      { "direct 7z, no mp4 rename" }
        'yejiang'     { "WinRAR only, sub-modes" }
    }
    "$_  ($desc)"
}

$choice = Show-Menu -Title "Extract - Select Source" -Options $menuOptions
if ($choice -eq -1) { Write-Host "已取消" -ForegroundColor Gray; exit 0 }

$selectedKey = $profileKeys[$choice]
$prof = $Profiles[$selectedKey]

# yejiang 二级菜单
$yejiangSubMode = $null
if ($prof.Pipeline -eq 'yejiang') {
    $subOptions = @(
        "simple (mp4->output0->output)",
        "split (keep dir structure)",
        "split (flatten to output root)"
    )
    $subChoice = Show-Menu -Title "yejiang - Select Mode" -Options $subOptions
    if ($subChoice -eq -1) { Write-Host "已取消" -ForegroundColor Gray; exit 0 }
    $yejiangSubMode = @('simple', 'split-structured', 'split-flatten')[$subChoice]
}

# 工具检查
[Console]::Clear()
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  $selectedKey 解压管线" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($prof.Need7z) {
    if (-not (Test-Path -LiteralPath $7zExe)) {
        Write-Host "错误: 未找到 7-Zip-Zstandard" -ForegroundColor Red
        Write-Host "路径: $7zExe" -ForegroundColor Red
        Write-Host "请从 https://github.com/mcmilk/7-Zip-zstd 下载安装" -ForegroundColor Yellow
        Read-Host "按回车键退出"; exit 1
    }
    Write-Host "✓ 7-Zip-Zstandard: $7zExe" -ForegroundColor Green
}
if ($prof.NeedWinRAR) {
    if (-not (Test-Path -LiteralPath $WinRarExe)) {
        Write-Host "错误: 未找到 WinRAR" -ForegroundColor Red
        Write-Host "路径: $WinRarExe" -ForegroundColor Red
        Read-Host "按回车键退出"; exit 1
    }
    Write-Host "✓ WinRAR: $WinRarExe" -ForegroundColor Green
}
Write-Host "工作目录: $WorkDir" -ForegroundColor Gray
Write-Host ""

# 执行管线
switch ($prof.Pipeline) {
    'standard'    { Invoke-StandardPipeline   -Prof $prof }
    'three-stage' { Invoke-ThreeStagePipeline -Prof $prof }
    'direct'      { Invoke-DirectPipeline     -Prof $prof }
    'yejiang'     { Invoke-YejiangPipeline    -SubMode $yejiangSubMode }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "全部完成！" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "按回车键退出"




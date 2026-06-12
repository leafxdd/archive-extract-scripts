#Requires -Version 5.1
<#
.SYNOPSIS
    DORO/PADIO 自动分类融合解压脚本（全 WinRAR 版）
.DESCRIPTION
    1. 在工作目录中查找初始 .mp4 / 压缩包入口并按文件名分类：
       - 文件名包含 doro：使用 DORO 密码 doro，执行三层管线
       - 文件基名为四位数字：使用 PADIO 密码 PADIO294，执行两层管线
       - 无法自动分类：弹出方向键菜单，手动选择 DORO / PADIO / 跳过
    2. 中间层解压到压缩包对应的隔离目录，避免 output0/output1 平铺混在一起
    3. 最后一层 smart extract：先解到隔离临时目录再判断结构（不依赖 7z 列表）
       - 顶层含文件夹：把顶层各项直接铺到 output
       - 顶层全是文件：解压到压缩包同名目录，避免散落
    4. 每次解压前/铺放前做目标冲突检查，发现重复文件/目录会自动改名，避免覆盖
    5. 只有整条解压链全部成功后才删除该链的源文件和中间压缩包
.NOTES
    全部解压均使用 WinRAR（GUI 程序，Start-Process -Wait 取退出码）：
    密码错误时 WinRAR 返回非 0（7z 档 3、zip 档 10），可靠区分成功/失败。
    不再依赖 7-Zip。本脚本处理的压缩包不含 7z-zstd 专有压缩算法。
    -Parallel N 可让最多 N 个 WinRAR 同时解压（默认 1 = 串行）；落位与删除始终串行。
    SSD 建议 2-4，机械硬盘建议保持 1（并行寻道反而更慢）。#>


param(
    [string]$WorkDir = $PSScriptRoot,
    [switch]$KeepFiles = $false,
    [int]$Parallel = 1
)

# ==================== 初始化 ====================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

$WinRarExe = Join-Path $env:ProgramFiles "WinRAR\WinRAR.exe"
$DeleteFlag = -not $KeepFiles

$Output0 = Join-Path $WorkDir "output0"
$Output1 = Join-Path $WorkDir "output1"
$Output  = Join-Path $WorkDir "output"

$Profiles = @{
    DORO = [pscustomobject]@{
        Key       = "DORO"
        Display   = "DORO"
        Password  = "doro"
        Depth     = 3
        JunkFiles = @("好用的VPN和AI茶馆.txt")
    }
    PADIO = [pscustomobject]@{
        Key       = "PADIO"
        Display   = "PADIO"
        Password  = "PADIO294"
        Depth     = 2
        JunkFiles = @()
    }
}
$ManualProfileSelections = @{}

# ==================== 基础工具函数 ====================
function Show-Menu {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Options
    )

    $selected = 0
    $cursorVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false

    $topLeft = [char]0x2554
    $topRight = [char]0x2557
    $bottomLeft = [char]0x255A
    $bottomRight = [char]0x255D
    $horizontal = [char]0x2550
    $vertical = [char]0x2551
    $middleLeft = [char]0x2560
    $middleRight = [char]0x2563

    function Get-DisplayWidth {
        param([string]$Text)

        $width = 0
        foreach ($char in $Text.ToCharArray()) {
            $code = [int]$char
            if (($code -ge 0x1100 -and $code -le 0x115F) -or
                ($code -ge 0x2E80 -and $code -le 0xA4CF -and $code -ne 0x303F) -or
                ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
                ($code -ge 0xF900 -and $code -le 0xFAFF) -or
                ($code -ge 0xFE10 -and $code -le 0xFE6F) -or
                ($code -ge 0xFF01 -and $code -le 0xFF60) -or
                ($code -ge 0xFFE0 -and $code -le 0xFFE6)) {
                $width += 2
            } else {
                $width += 1
            }
        }
        return $width
    }

    function Get-ConsoleWindowWidth {
        try {
            $width = $Host.UI.RawUI.WindowSize.Width
            if ($width -gt 0) { return $width }
        } catch { }

        try {
            $width = [Console]::WindowWidth
            if ($width -gt 0) { return $width }
        } catch { }

        return 80
    }

    function Limit-ToDisplayWidth {
        param(
            [string]$Text,
            [int]$MaxWidth
        )

        if ($MaxWidth -le 0) { return "" }
        if ((Get-DisplayWidth -Text $Text) -le $MaxWidth) { return $Text }

        $suffix = "..."
        $suffixWidth = Get-DisplayWidth -Text $suffix
        if ($MaxWidth -le $suffixWidth) { return "." * $MaxWidth }

        $targetWidth = $MaxWidth - $suffixWidth
        $usedWidth = 0
        $builder = [System.Text.StringBuilder]::new()
        foreach ($char in $Text.ToCharArray()) {
            $charWidth = Get-DisplayWidth -Text ([string]$char)
            if (($usedWidth + $charWidth) -gt $targetWidth) { break }
            [void]$builder.Append($char)
            $usedWidth += $charWidth
        }

        return $builder.ToString() + $suffix
    }

    function Pad-ToDisplayWidth {
        param([string]$Text, [int]$TargetWidth)

        $displayWidth = Get-DisplayWidth -Text $Text
        $pad = $TargetWidth - $displayWidth
        if ($pad -gt 0) { return $Text + (' ' * $pad) }
        return $Text
    }

    function Test-ConsoleKeyAvailable {
        try {
            return [Console]::KeyAvailable
        } catch {
            return $false
        }
    }

    $allLines = @(" $Title ") + ($Options | ForEach-Object { "  > $_" })
    $maxWidth = ($allLines | ForEach-Object { Get-DisplayWidth -Text $_ } | Measure-Object -Maximum).Maximum

    try {
        while ($true) {
            $windowWidth = Get-ConsoleWindowWidth
            $maxInnerWidth = [Math]::Max(1, $windowWidth - 3)
            $desiredWidth = [Math]::Max($maxWidth + 2, 30)
            $width = [Math]::Min($desiredWidth, $maxInnerWidth)

            [Console]::Clear()
            $border = "$horizontal" * $width
            Write-Host "$topLeft$border$topRight" -ForegroundColor Cyan
            $titleText = Pad-ToDisplayWidth -Text (Limit-ToDisplayWidth -Text " $Title " -MaxWidth $width) -TargetWidth $width
            Write-Host "$vertical$titleText$vertical" -ForegroundColor Cyan
            Write-Host "$middleLeft$border$middleRight" -ForegroundColor Cyan

            for ($i = 0; $i -lt $Options.Count; $i++) {
                $marker = if ($i -eq $selected) { '>' } else { ' ' }
                $optionText = Limit-ToDisplayWidth -Text "  $marker $($Options[$i])" -MaxWidth $width
                $text = Pad-ToDisplayWidth -Text $optionText -TargetWidth $width
                Write-Host "$vertical" -NoNewline -ForegroundColor Cyan
                if ($i -eq $selected) {
                    Write-Host $text -NoNewline -ForegroundColor Green
                } else {
                    Write-Host $text -NoNewline -ForegroundColor White
                }
                Write-Host "$vertical" -ForegroundColor Cyan
            }

            Write-Host "$bottomLeft$border$bottomRight" -ForegroundColor Cyan
            Write-Host ""
            $helpText = Limit-ToDisplayWidth -Text "  Up/Down 选择，Enter 确认，Esc 跳过" -MaxWidth ([Math]::Max(1, $windowWidth - 1))
            Write-Host $helpText -ForegroundColor DarkGray

            $redraw = $false
            while (-not $redraw) {
                if ((Get-ConsoleWindowWidth) -ne $windowWidth) {
                    $redraw = $true
                    break
                }

                if (Test-ConsoleKeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    switch ($key.Key) {
                        'UpArrow' {
                            $selected = if ($selected -gt 0) { $selected - 1 } else { $Options.Count - 1 }
                            $redraw = $true
                        }
                        'DownArrow' {
                            $selected = if ($selected -lt $Options.Count - 1) { $selected + 1 } else { 0 }
                            $redraw = $true
                        }
                        'Enter'  { return $selected }
                        'Escape' { return -1 }
                    }
                } else {
                    Start-Sleep -Milliseconds 80
                }
            }
        }
    } finally {
        [Console]::CursorVisible = $cursorVisible
    }
}

function New-DirectoryIfMissing {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        [System.IO.Directory]::CreateDirectory($Path) | Out-Null
    }
}

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    try {
        return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\', '/')
    } catch {
        return $Path.TrimEnd('\', '/')
    }
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

function Test-IsUnderAnyPath {
    param(
        [Parameter(Mandatory)][string]$ChildPath,
        [string[]]$ParentPaths = @()
    )

    foreach ($parent in $ParentPaths) {
        if ($parent -and (Test-IsUnderPath -ChildPath $ChildPath -ParentPath $parent)) {
            return $true
        }
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
        $newLeaf = if ($item -is [System.IO.DirectoryInfo]) {
            "{0}__existing_{1}" -f $stem, $i
        } else {
            "{0}__existing_{1}{2}" -f $stem, $i, $ext
        }
        $candidate = Join-Path $parent $newLeaf
        if (-not (Test-Path -LiteralPath $candidate)) {
            Move-Item -LiteralPath $item.FullName -Destination $candidate -ErrorAction Stop
            Write-Host "  [RENAME] 目标冲突，已改名: $leaf -> $newLeaf" -ForegroundColor Yellow
            return $candidate
        }
    }

    throw "无法为冲突项生成唯一名称: $Path"
}

function Get-ProfileForName {
    param([Parameter(Mandatory)][string]$BaseName)

    if ($BaseName -match '(?i)doro') { return $Profiles.DORO }
    if ($BaseName -match '^\d{4}(__\d+)?$') { return $Profiles.PADIO }
    return $null
}

function Set-ManualProfileSelection {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][pscustomobject]$ArchiveProfile
    )

    $script:ManualProfileSelections[(Get-NormalizedPath -Path $Path)] = $ArchiveProfile.Key
}

function Get-ManualProfileSelection {
    param([Parameter(Mandatory)][string]$Path)

    $key = Get-NormalizedPath -Path $Path
    if (-not $script:ManualProfileSelections.ContainsKey($key)) { return $null }

    $profileKey = $script:ManualProfileSelections[$key]
    if ($Profiles.ContainsKey($profileKey)) { return $Profiles[$profileKey] }
    return $null
}

function Select-ProfileForUnknownArchive {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [string]$FullPath = ""
    )

    Write-Host "[ASK] 无法自动分类: $DisplayName" -ForegroundColor Yellow
    if ($FullPath) {
        Write-Host "      $FullPath" -ForegroundColor DarkGray
    }

    $choice = Show-Menu -Title "选择解压入口: $DisplayName" -Options @(
        "DORO - 密码 doro，三层解压",
        "PADIO - 密码 PADIO294，两层解压",
        "跳过 - 不处理这个文件"
    )

    switch ($choice) {
        0 { return $Profiles.DORO }
        1 { return $Profiles.PADIO }
        default { return $null }
    }
}

function Resolve-ArchiveProfile {
    param(
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][string]$DisplayName,
        [string]$FullPath = "",
        [switch]$PromptIfUnknown
    )

    $archiveProfile = Get-ProfileForName -BaseName $BaseName
    if ($null -ne $archiveProfile) { return $archiveProfile }

    if ($FullPath) {
        $archiveProfile = Get-ManualProfileSelection -Path $FullPath
        if ($null -ne $archiveProfile) { return $archiveProfile }
    }

    if ($PromptIfUnknown) {
        $archiveProfile = Select-ProfileForUnknownArchive -DisplayName $DisplayName -FullPath $FullPath
        if ($null -ne $archiveProfile -and $FullPath) {
            Set-ManualProfileSelection -Path $FullPath -ArchiveProfile $archiveProfile
        }
        return $archiveProfile
    }

    return $null
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
                $dir = $Entry.Dir
                $base = [regex]::Escape($Entry.Base)
                Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match "^$base\.z\d+$" } |
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
                Remove-Item -LiteralPath $Entry.Path -Force -ErrorAction SilentlyContinue
            }
            '^zip-z01$' {
                $dir = $Entry.Dir
                $base = [regex]::Escape($Entry.Base)
                Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match "^$base\.z\d+$" } |
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
                $zipPath = Join-Path $dir ($Entry.Base + '.zip')
                if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath $Entry.Path) { Remove-Item -LiteralPath $Entry.Path -Force -ErrorAction SilentlyContinue }
            }
            '^(zip|7z)-001$' {
                $dir = $Entry.Dir
                $stemEsc = [regex]::Escape($Entry.Base)
                $fmt = ($Entry.Type -split '-')[0]
                Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match "^$stemEsc\.$fmt\.\d+$" } |
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
            }
            '^rar-part$' {
                $dir = $Entry.Dir
                $stemEsc = [regex]::Escape($Entry.Base)
                Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match "^$stemEsc\.part\d+\.rar$" } |
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
            }
            '^rar-r00$' {
                $dir = $Entry.Dir
                $stemEsc = [regex]::Escape($Entry.Base)
                Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match "^$stemEsc\.r\d\d$" } |
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
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

# ==================== 解压包装（全部使用 WinRAR）====================
# 启动一个 WinRAR 解压进程（不等待）。返回任务句柄，由 Complete-WinRARExtract 收割。
# WinRAR.exe 是 GUI 程序，必须等进程退出才能拿到真实退出码；-or = 同名自动改名兜底；-inul = 禁错误弹窗，防无人值守卡死。
function Start-WinRARExtract {
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
    ) -PassThru -NoNewWindow

    return [pscustomobject]@{ Proc = $proc; ArchivePath = $ArchivePath; TargetDir = $TargetDir }
}

# 等待解压进程退出并校验结果（退出码 + 空解压防护）。
function Complete-WinRARExtract {
    param([Parameter(Mandatory)][pscustomobject]$ExtractJob)

    $proc = $ExtractJob.Proc
    if ($null -eq $proc) { return $false }
    $proc.WaitForExit()

    if ($proc.ExitCode -ne 0) {
        # 数据加密档退出码可靠：7z 档=3，zip 档=10，rar 档=非 0
        return $false
    }

    # 头加密 7z（-mhe=on）遇错误密码时 WinRAR 仍返回退出码 0 却什么都不解，
    # 单看退出码会误判成功并误删源文件。故追加校验：必须真的解出了内容。
    # 调用方传入的 TargetDir 是新建的隔离空目录，目录内任何条目都来自本次解压。
    $extracted = @(Get-ChildItem -LiteralPath $ExtractJob.TargetDir -Force -ErrorAction SilentlyContinue)
    if ($extracted.Count -eq 0) {
        Write-Host "  [FAIL] 退出码 0 但未解出任何文件（疑似密码错误或头加密包无法读取）: $(Split-Path -Leaf $ExtractJob.ArchivePath)" -ForegroundColor Red
        return $false
    }

    return $true
}

# 批量解压调度：窗口内最多 ThrottleLimit 个 WinRAR 并发，结果严格按提交顺序收割。
# ThrottleLimit=1 时退化为"启动→等待→下一个"，与逐个同步解压完全等价。
# 任务对象需含 Entry / TargetDir / ArchiveKey（TargetDir 必须是调用方预创建的唯一隔离目录），
# 返回 [{ Task; Success }]，顺序与输入一致。所有移动/删除等落位操作由调用方在收割后串行执行。
function Invoke-ExtractionBatch {
    param(
        [object[]]$Tasks = @(),
        [int]$ThrottleLimit = 1
    )

    if ($Tasks.Count -eq 0) { return @() }
    $limit = [Math]::Max(1, $ThrottleLimit)
    $results = New-Object 'System.Collections.Generic.List[object]'
    $inFlight = New-Object 'System.Collections.Generic.Queue[object]'

    foreach ($task in $Tasks) {
        while ($inFlight.Count -ge $limit) {
            $oldest = $inFlight.Dequeue()
            $ok = Complete-WinRARExtract -ExtractJob $oldest.ExtractJob
            $results.Add([pscustomobject]@{ Task = $oldest.Task; Success = $ok })
        }
        Write-Host "[EXTRACT] ($(Get-EntryLabel -Entry $task.Entry)) $(Split-Path -Leaf $task.Entry.Path) -> $($task.TargetDir)" -ForegroundColor Yellow
        $extractJob = Start-WinRARExtract -ArchivePath $task.Entry.Path -TargetDir $task.TargetDir -ArchiveKey $task.ArchiveKey
        $inFlight.Enqueue([pscustomobject]@{ Task = $task; ExtractJob = $extractJob })
    }
    while ($inFlight.Count -gt 0) {
        $oldest = $inFlight.Dequeue()
        $ok = Complete-WinRARExtract -ExtractJob $oldest.ExtractJob
        $results.Add([pscustomobject]@{ Task = $oldest.Task; Success = $ok })
    }

    return $results.ToArray()
}

# smart 落位（解压成功后）：tmp 顶层含文件夹则把各项铺到 OutputDir；全是文件则整体改名为同名目录。
# 目标冲突一律改名让位，绝不覆盖。必须在主线程串行调用（check-then-act 不可并发）。
function Move-SmartExtractedContent {
    param(
        [Parameter(Mandatory)][string]$TmpDir,
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][string]$BaseName
    )

    $items = @(Get-ChildItem -LiteralPath $TmpDir -Force -ErrorAction SilentlyContinue)
    $hasFolder = @($items | Where-Object { $_.PSIsContainer }).Count -gt 0

    if ($hasFolder) {
        Write-Host "  [SMART] 根目录含文件夹，直接铺到 output" -ForegroundColor DarkGray
        foreach ($item in $items) {
            $dest = Join-Path $OutputDir $item.Name
            if (Test-Path -LiteralPath $dest) { [void](Move-ExistingPathAside -Path $dest) }
            Move-Item -LiteralPath $item.FullName -Destination $dest -ErrorAction Stop
        }
        Remove-Item -LiteralPath $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        $dest = Get-UniqueDirectoryPath -DirectoryPath (Join-Path $OutputDir $BaseName)
        Write-Host "  [SMART] 根目录无文件夹，解压到同名目录: $(Split-Path -Leaf $dest)" -ForegroundColor DarkGray
        Move-Item -LiteralPath $TmpDir -Destination $dest -ErrorAction Stop
    }
}

# 解压失败的隔离临时目录：空则删除，有残留则保留供排查。
function Remove-FailedExtractionTemp {
    param([Parameter(Mandatory)][string]$TmpDir)

    if (-not (Test-Path -LiteralPath $TmpDir)) { return }
    $leftover = @(Get-ChildItem -LiteralPath $TmpDir -Force -ErrorAction SilentlyContinue)
    if ($leftover.Count -eq 0) { Remove-Item -LiteralPath $TmpDir -Force -ErrorAction SilentlyContinue }
    else { Write-Host "  [KEEP] 解压失败，保留临时目录: $(Split-Path -Leaf $TmpDir)" -ForegroundColor Yellow }
}

# ==================== 管线处理 ====================
function Convert-ClassifiedMp4ToZip {
    param([string[]]$ExcludeDirs)

    $mp4Files = @(Get-FilesWithPrunedDirs -RootDir $WorkDir -ExcludeDirs $ExcludeDirs |
        Where-Object { $_.Extension -ieq '.mp4' })

    foreach ($file in $mp4Files) {
        $archiveProfile = Resolve-ArchiveProfile -BaseName $file.BaseName -DisplayName $file.Name -FullPath $file.FullName -PromptIfUnknown
        if ($null -eq $archiveProfile) {
            Write-Host "[SKIP] 无法分类 MP4: $($file.Name)" -ForegroundColor DarkGray
            continue
        }

        $desiredZipPath = Join-Path $file.DirectoryName ($file.BaseName + ".zip")
        $zipPath = Get-UniqueFilePath -FilePath $desiredZipPath

        try {
            Rename-Item -LiteralPath $file.FullName -NewName (Split-Path -Leaf $zipPath) -ErrorAction Stop
            Set-ManualProfileSelection -Path $zipPath -ArchiveProfile $archiveProfile
            Write-Host "[RENAME] $($file.Name) -> $(Split-Path -Leaf $zipPath) [$($archiveProfile.Display)]" -ForegroundColor Green
        } catch {
            Write-Host "[ERROR] MP4 重命名失败: $($file.Name) - $_" -ForegroundColor Red
        }
    }
}

# 收集中间层任务：每个入口解到 TargetRoot\<相对路径>\<压缩包名>\（隔离目录，串行预分配）
function Get-IntermediateLayerTasks {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$ArchiveKey
    )

    $entries = @(Get-ArchiveEntrypoints -RootDir $SourceDir)
    if ($entries.Count -eq 0) { return @() }

    $tasks = @()
    foreach ($entry in $entries) {
        $relDir = Get-RelativeDirectory -RootDir $SourceDir -ChildDir $entry.Dir
        $archiveFolder = Get-SafeFolderName -Name $entry.Base
        $desired = if ($relDir) { Join-Path (Join-Path $TargetRoot $relDir) $archiveFolder } else { Join-Path $TargetRoot $archiveFolder }
        $targetDir = Get-UniqueDirectoryPath -DirectoryPath $desired
        if ($targetDir -ne $desired) {
            Write-Host "  [RENAME] 目标目录已存在，改用: $(Split-Path -Leaf $targetDir)" -ForegroundColor Yellow
        }
        New-DirectoryIfMissing -Path $targetDir
        $tasks += [pscustomobject]@{ Entry = $entry; TargetDir = $targetDir; ArchiveKey = $ArchiveKey }
    }
    return @($tasks)
}

# 收集一个源目录的最终层任务：每个内层入口对应一个预创建的隔离临时目录 output\.__unpack_<名>
function Get-FinalLayerTasks {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$ArchiveKey
    )

    $entries = @(Get-ArchiveEntrypoints -RootDir $SourceDir)
    if ($entries.Count -eq 0) { return @() }

    New-DirectoryIfMissing -Path $Output
    $tasks = @()
    foreach ($entry in $entries) {
        $baseName = Get-SafeFolderName -Name $entry.Base
        $tmpTarget = Get-UniqueDirectoryPath -DirectoryPath (Join-Path $Output (".__unpack_" + $baseName))
        New-DirectoryIfMissing -Path $tmpTarget
        $tasks += [pscustomobject]@{ Entry = $entry; TargetDir = $tmpTarget; ArchiveKey = $ArchiveKey; BaseName = $baseName }
    }
    return @($tasks)
}

# 最终层收割：成功 smart 落位、失败清理临时目录（串行，绝不并发）
function Complete-FinalLayerResult {
    param(
        [Parameter(Mandatory)][pscustomobject]$Result,
        [Parameter(Mandatory)][string]$LayerName
    )

    $leaf = Split-Path -Leaf $Result.Task.Entry.Path
    if ($Result.Success) {
        Move-SmartExtractedContent -TmpDir $Result.Task.TargetDir -OutputDir $Output -BaseName $Result.Task.BaseName
        Write-Host "  [OK] $LayerName 完成: $leaf" -ForegroundColor Green
    } else {
        Remove-FailedExtractionTemp -TmpDir $Result.Task.TargetDir
        Write-Host "  [FAIL] $LayerName 失败: $leaf" -ForegroundColor Red
    }
}

function Get-ResumableStage0Jobs {
    param([object[]]$ExistingJobs = @())

    if (-not (Test-Path -LiteralPath $Output0)) { return @() }

    $knownStage0Dirs = @{}
    foreach ($job in @($ExistingJobs | Where-Object { $_.Success })) {
        if ($job.Stage0Dir) {
            $knownStage0Dirs[(Get-NormalizedPath -Path $job.Stage0Dir)] = $true
        }
    }

    $resumedJobs = @()
    $stage0Dirs = @(Get-ChildItem -LiteralPath $Output0 -Directory -Force -ErrorAction SilentlyContinue)
    foreach ($dir in $stage0Dirs) {
        $dirKey = Get-NormalizedPath -Path $dir.FullName
        if ($knownStage0Dirs.ContainsKey($dirKey)) { continue }

        $hasArchives = @(Get-ArchiveEntrypoints -RootDir $dir.FullName).Count -gt 0
        if (-not $hasArchives) { continue }

        $archiveProfile = Resolve-ArchiveProfile -BaseName $dir.Name -DisplayName $dir.Name -FullPath $dir.FullName -PromptIfUnknown
        if ($null -eq $archiveProfile) {
            Write-Host "[SKIP] 无法分类已存在的 output0 目录: $($dir.Name)" -ForegroundColor DarkGray
            continue
        }

        Write-Host "[RESUME] output0\$($dir.Name) -> $($archiveProfile.Display), $($archiveProfile.Depth) 层" -ForegroundColor Cyan
        $resumedJobs += [pscustomobject]@{
            Success   = $true
            Profile   = $archiveProfile
            Source    = $null
            Stage0Dir = $dir.FullName
            Name      = $dir.Name
            CleanupEntries = @()
            Resumed   = $true
        }
    }

    return @($resumedJobs)
}

function Get-ArchiveEntryCleanupKey {
    param([Parameter(Mandatory)][pscustomobject]$Entry)

    return "{0}|{1}" -f $Entry.Type, (Get-NormalizedPath -Path $Entry.Path)
}

function Invoke-CompletedChainCleanup {
    param([object[]]$Chains)

    if (-not $DeleteFlag) {
        Write-Host "跳过链路源文件清理（KeepFiles 已启用）" -ForegroundColor Gray
        return
    }

    $completedChains = @($Chains | Where-Object { $_.Success })
    if ($completedChains.Count -eq 0) {
        Write-Host "没有完整成功的链路需要清理" -ForegroundColor Gray
        return
    }

    Write-Host "`n清理完整成功的解压链..." -ForegroundColor Yellow
    Write-Host "----------------------------------------"

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $deletedCount = 0
    foreach ($chain in $completedChains) {
        $entries = @($chain.CleanupEntries | Where-Object { $null -ne $_ })
        if ($entries.Count -eq 0) { continue }

        Write-Host "[CHAIN OK] $($chain.Name) -> 清理 $($entries.Count) 个压缩包入口" -ForegroundColor Green
        foreach ($entry in $entries) {
            $key = Get-ArchiveEntryCleanupKey -Entry $entry
            if (-not $seen.Add($key)) { continue }

            $leaf = Split-Path -Leaf $entry.Path
            if (Remove-ArchiveGroup -Entry $entry) {
                Write-Host "  [DELETE] $leaf" -ForegroundColor DarkGray
                $deletedCount++
            }
        }
    }

    Write-Host "  [OK] 已清理 $deletedCount 个链路压缩包入口" -ForegroundColor Green
}

function Remove-JunkFiles {
    param([object[]]$Jobs)

    $junkNames = @($Jobs |
        Where-Object { $_.Success } |
        ForEach-Object { $_.Profile.JunkFiles } |
        Where-Object { $_ } |
        Select-Object -Unique)

    if ($junkNames.Count -eq 0) { return }

    Write-Host "`n清理垃圾文件..." -ForegroundColor Yellow
    $deleted = 0
    Get-ChildItem -LiteralPath $Output -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $junkNames -contains $_.Name } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            Write-Host "  [DELETE] $($_.FullName)" -ForegroundColor DarkGray
            $deleted++
        }

    if ($deleted -gt 0) {
        Write-Host "  [OK] 已删除 $deleted 个垃圾文件" -ForegroundColor Green
    }
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

function Remove-IntermediateDirsIfEmpty {
    foreach ($dir in @($Output0, $Output1)) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $remainingFiles = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue)
        if ($remainingFiles.Count -eq 0) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  [OK] 已删除中间目录: $(Split-Path -Leaf $dir)" -ForegroundColor Green
        } else {
            Write-Host "  [KEEP] $(Split-Path -Leaf $dir) 仍有文件，保留以供排查" -ForegroundColor Yellow
        }
    }
}

# ==================== 主流程 ====================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "DORO/PADIO 自动分类融合解压脚本（WinRAR）" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path -LiteralPath $WinRarExe)) {
    Write-Host "错误: 未找到 WinRAR" -ForegroundColor Red
    Write-Host "路径: $WinRarExe" -ForegroundColor Red
    Read-Host "按回车键退出"
    exit 1
}
Write-Host "[OK] WinRAR: $WinRarExe" -ForegroundColor Green
if ($Parallel -gt 1) { Write-Host "并行度: $Parallel" -ForegroundColor Gray }
Write-Host ""

foreach ($dir in @($Output0, $Output1, $Output)) {
    New-DirectoryIfMissing -Path $dir
}

$excludeDirs = @($Output0, $Output1, $Output)

Write-Host "步骤 0: 分类并还原 .mp4 -> .zip" -ForegroundColor Yellow
Write-Host "----------------------------------------"
Convert-ClassifiedMp4ToZip -ExcludeDirs $excludeDirs

Write-Host "`n步骤 1: 初始入口 -> output0\<入口名>" -ForegroundColor Yellow
Write-Host "----------------------------------------"
$initialEntries = @(Get-ArchiveEntrypoints -RootDir $WorkDir -ExcludeDirs $excludeDirs)
$jobs = @()

if ($initialEntries.Count -eq 0) {
    Write-Host "未发现可处理的初始压缩包" -ForegroundColor Gray
} else {
    $stage0Tasks = @()
    foreach ($entry in $initialEntries) {
        $archiveProfile = Resolve-ArchiveProfile -BaseName $entry.Base -DisplayName (Split-Path -Leaf $entry.Path) -FullPath $entry.Path -PromptIfUnknown
        if ($null -eq $archiveProfile) {
            Write-Host "[SKIP] 无法分类: $(Split-Path -Leaf $entry.Path)" -ForegroundColor DarkGray
            continue
        }

        Write-Host "[CLASSIFY] $(Split-Path -Leaf $entry.Path) -> $($archiveProfile.Display), $($archiveProfile.Depth) 层" -ForegroundColor Cyan
        $targetName = Get-SafeFolderName -Name $entry.Base
        $targetDir = Get-UniqueDirectoryPath -DirectoryPath (Join-Path $Output0 $targetName)
        if ((Split-Path -Leaf $targetDir) -ne $targetName) {
            Write-Host "  [RENAME] 目标目录已存在，改用: $(Split-Path -Leaf $targetDir)" -ForegroundColor Yellow
        }
        New-DirectoryIfMissing -Path $targetDir
        $stage0Tasks += [pscustomobject]@{ Entry = $entry; TargetDir = $targetDir; ArchiveKey = $archiveProfile.Password; Name = $targetName; Profile = $archiveProfile }
    }

    foreach ($r in @(Invoke-ExtractionBatch -Tasks $stage0Tasks -ThrottleLimit $Parallel)) {
        $leaf = Split-Path -Leaf $r.Task.Entry.Path
        if ($r.Success) { Write-Host "  [OK] 第一层完成: $leaf" -ForegroundColor Green }
        else { Write-Host "  [FAIL] 第一层失败: $leaf" -ForegroundColor Red }
        $jobs += [pscustomobject]@{
            Success   = $r.Success
            Profile   = $r.Task.Profile
            Source    = $r.Task.Entry
            Stage0Dir = $r.Task.TargetDir
            Name      = $r.Task.Name
            CleanupEntries = if ($r.Success) { @($r.Task.Entry) } else { @() }
        }
    }
    Write-Host ""
}

$successfulJobs = @($jobs | Where-Object { $_.Success })
$resumedJobs = @(Get-ResumableStage0Jobs -ExistingJobs $successfulJobs)
if ($resumedJobs.Count -gt 0) {
    Write-Host "`n恢复已有 output0 中间任务: $($resumedJobs.Count) 个" -ForegroundColor Yellow
    $successfulJobs = @($successfulJobs + $resumedJobs)
}

Write-Host "`n步骤 2: PADIO 最终层 / DORO 中间层" -ForegroundColor Yellow
Write-Host "----------------------------------------"
$chainResults = @()
$stage2Tasks = @()
foreach ($job in $successfulJobs) {
    $cleanupEntries = @($job.CleanupEntries | Where-Object { $null -ne $_ })
    $chain = [pscustomobject]@{
        Name              = $job.Name
        Profile           = $job.Profile
        Job               = $job
        Success           = $false
        Stage2Success     = $false
        HasMiddleTasks    = $false
        MiddleFailedCount = 0
        HasFinalTasks     = $false
        FailedCount       = 0
        FailedStage       = ""
        Stage1Dir         = $null
        CleanupEntries    = @($cleanupEntries)
    }

    if ($job.Profile.Key -eq 'PADIO') {
        Write-Host "[PADIO] $($job.Name): output0\$($job.Name) -> output (smart)" -ForegroundColor Cyan
        $finalTasks = @(Get-FinalLayerTasks -SourceDir $job.Stage0Dir -ArchiveKey $job.Profile.Password)
        if ($finalTasks.Count -eq 0) {
            Write-Host "[PADIO 最终层] 未发现可解压的压缩包" -ForegroundColor Gray
        } else {
            $chain.HasFinalTasks = $true
            foreach ($t in $finalTasks) {
                $t | Add-Member -NotePropertyName Chain -NotePropertyValue $chain
                $t | Add-Member -NotePropertyName Kind -NotePropertyValue 'final'
            }
            $stage2Tasks += $finalTasks
        }
    } elseif ($job.Profile.Key -eq 'DORO') {
        $targetRoot = Join-Path $Output1 $job.Name
        New-DirectoryIfMissing -Path $targetRoot
        $chain.Stage1Dir = $targetRoot
        Write-Host "[DORO] $($job.Name): output0\$($job.Name) -> output1\$($job.Name)\<压缩包名>" -ForegroundColor Cyan
        $middleTasks = @(Get-IntermediateLayerTasks -SourceDir $job.Stage0Dir -TargetRoot $targetRoot -ArchiveKey $job.Profile.Password)
        if ($middleTasks.Count -eq 0) {
            Write-Host "[DORO 中间层] 未发现可解压的压缩包" -ForegroundColor Gray
        } else {
            $chain.HasMiddleTasks = $true
            foreach ($t in $middleTasks) {
                $t | Add-Member -NotePropertyName Chain -NotePropertyValue $chain
                $t | Add-Member -NotePropertyName Kind -NotePropertyValue 'middle'
            }
            $stage2Tasks += $middleTasks
        }
    }

    $chainResults += $chain
}

foreach ($r in @(Invoke-ExtractionBatch -Tasks $stage2Tasks -ThrottleLimit $Parallel)) {
    $chain = $r.Task.Chain
    if ($r.Task.Kind -eq 'final') {
        Complete-FinalLayerResult -Result $r -LayerName "PADIO 最终层"
        if (-not $r.Success) { $chain.FailedCount++ }
    } else {
        $leaf = Split-Path -Leaf $r.Task.Entry.Path
        if ($r.Success) { Write-Host "  [OK] DORO 中间层 完成: $leaf" -ForegroundColor Green }
        else { Write-Host "  [FAIL] DORO 中间层 失败: $leaf" -ForegroundColor Red }
        if (-not $r.Success) { $chain.MiddleFailedCount++ }
    }
    $chain.CleanupEntries = @($chain.CleanupEntries + $r.Task.Entry)
}

Write-Host ""
foreach ($chain in $chainResults) {
    if ($chain.Profile.Key -eq 'PADIO') {
        $chain.Success = $chain.HasFinalTasks -and ($chain.FailedCount -eq 0)
        if (-not $chain.Success) { $chain.FailedStage = "PADIO 最终层" }
        if ($chain.Success) { Write-Host "[CHAIN OK] $($chain.Name)" -ForegroundColor Green }
        else { Write-Host "[CHAIN FAIL] $($chain.Name): $($chain.FailedStage)" -ForegroundColor Red }
    } elseif ($chain.Profile.Key -eq 'DORO') {
        $chain.Stage2Success = $chain.HasMiddleTasks -and ($chain.MiddleFailedCount -eq 0)
        if (-not $chain.Stage2Success) { $chain.FailedStage = "DORO 中间层" }
    }
}
Write-Host ""

Write-Host "`n步骤 3: DORO 最终层" -ForegroundColor Yellow
Write-Host "----------------------------------------"
$doroChains = @($chainResults | Where-Object { $_.Profile.Key -eq 'DORO' })
if ($doroChains.Count -eq 0) {
    Write-Host "没有 DORO 任务需要第三层解压" -ForegroundColor Gray
} else {
    $allFinalTasks = @()
    foreach ($chain in $doroChains) {
        $job = $chain.Job
        if (-not $chain.Stage2Success) {
            Write-Host "[SKIP] DORO 最终层跳过: $($job.Name)（中间层未完整成功）" -ForegroundColor Yellow
            continue
        }

        $sourceDir = $chain.Stage1Dir
        if (-not (Test-Path -LiteralPath $sourceDir)) {
            Write-Host "[SKIP] DORO 中间目录不存在: $sourceDir" -ForegroundColor Yellow
            $chain.FailedStage = "DORO 最终层"
            continue
        }
        Write-Host "[DORO] $($job.Name): output1\$($job.Name) -> output (smart)" -ForegroundColor Cyan
        $finalTasks = @(Get-FinalLayerTasks -SourceDir $sourceDir -ArchiveKey $job.Profile.Password)
        if ($finalTasks.Count -eq 0) {
            Write-Host "[DORO 最终层] 未发现可解压的压缩包" -ForegroundColor Gray
        } else {
            $chain.HasFinalTasks = $true
            foreach ($t in $finalTasks) { $t | Add-Member -NotePropertyName Chain -NotePropertyValue $chain }
            $allFinalTasks += $finalTasks
        }
    }

    foreach ($r in @(Invoke-ExtractionBatch -Tasks $allFinalTasks -ThrottleLimit $Parallel)) {
        Complete-FinalLayerResult -Result $r -LayerName "DORO 最终层"
        $chain = $r.Task.Chain
        $chain.CleanupEntries = @($chain.CleanupEntries + $r.Task.Entry)
        if (-not $r.Success) { $chain.FailedCount++ }
    }

    Write-Host ""
    foreach ($chain in $doroChains) {
        if ($chain.Stage2Success -and -not $chain.FailedStage) {
            $chain.Success = $chain.HasFinalTasks -and ($chain.FailedCount -eq 0)
            if (-not $chain.Success) { $chain.FailedStage = "DORO 最终层" }
        }
        if ($chain.Success) { Write-Host "[CHAIN OK] $($chain.Name)" -ForegroundColor Green }
        else { Write-Host "[CHAIN FAIL] $($chain.Name): $($chain.FailedStage)" -ForegroundColor Red }
    }
    Write-Host ""
}

$completedJobs = @($chainResults | Where-Object { $_.Success } | ForEach-Object { $_.Job })

if ($DeleteFlag) {
    Invoke-CompletedChainCleanup -Chains $chainResults
}

Remove-JunkFiles -Jobs $completedJobs

if ($DeleteFlag) {
    Write-Host "`n清点空文件夹..." -ForegroundColor Yellow
    Write-Host "----------------------------------------"
    Remove-IntermediateDirsIfEmpty
    Remove-EmptyDirs -Root $WorkDir -ProtectDirs @($Output)
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "全部完成" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "按回车键退出"

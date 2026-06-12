#Requires -Version 5.1
<#
.SYNOPSIS
    FLYYZ/yecgaa 手动分类融合解压脚本（全 WinRAR 版）
.DESCRIPTION
    1. 扫描工作目录中的 .mp4，对每个文件弹出方向键菜单手动选择管线：
       FLYYZ（密码 FLYYZ）/ yecgaa（密码 yecgaa）/ 跳过。
       全部询问完毕后才开始处理（需先知道每组总数，才能确定编号补零宽度）。
    2. .mp4 -> .zip 还原的同时按组重命名：FLYYZ 组为 F_1.zip、F_2.zip…，
       yecgaa 组为 Y_1.zip…；组内数量达两位数时补零（F_01），三位数 F_001，以此类推。
    3. 第一层：F_xx.zip 解压到 output0\FLYYZ\F_xx\，Y_xx.zip 解压到 output0\yecgaa\Y_xx\。
    4. 最终层：把 output0\<来源>\<编号名>\ 中发现的压缩包全部解压到 output\<编号名>\
       （输出不再分来源，密码仍按组区分；不做 smart 判断，固定落到编号名目录）。
    5. 只有整条解压链全部成功后，才删除该链的源文件与中间压缩包；失败链保留以便排查。
.NOTES
    全部解压均使用 WinRAR，不再依赖 7-Zip。
    退出码 0 但未解出任何内容（头加密 7z 遇错误密码的典型表现）一律按失败处理，避免误删。
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
$Output  = Join-Path $WorkDir "output"

$Profiles = @{
    FLYYZ = [pscustomobject]@{
        Key      = "FLYYZ"
        Display  = "FLYYZ"
        Password = "FLYYZ"
        Prefix   = "F"
    }
    yecgaa = [pscustomobject]@{
        Key      = "yecgaa"
        Display  = "yecgaa"
        Password = "yecgaa"
        Prefix   = "Y"
    }
}

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

# ==================== 分类 ====================
function Get-ProfileForName {
    param([Parameter(Mandatory)][string]$BaseName)

    if ($BaseName -match '^F_\d+(__\d+)?$') { return $Profiles.FLYYZ }
    if ($BaseName -match '^Y_\d+(__\d+)?$') { return $Profiles.yecgaa }
    return $null
}

function Select-ProfileForFile {
    param([Parameter(Mandatory)][string]$DisplayName)

    $choice = Show-Menu -Title "选择管线: $DisplayName" -Options @(
        "FLYYZ - 密码 FLYYZ，重命名为 F_*",
        "yecgaa - 密码 yecgaa，重命名为 Y_*",
        "跳过 - 不处理这个文件"
    )

    switch ($choice) {
        0 { return $Profiles.FLYYZ }
        1 { return $Profiles.yecgaa }
        default { return $null }
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

# 最终层落位（串行）：把隔离临时目录的全部内容移入 output\<编号名>\；不做 smart 结构判断。
# 链内多个内层压缩包共用同一个编号名目录，条目冲突时把既有项改名让位。必须在主线程串行调用。
function Move-ExtractedContentIntoNamedDir {
    param(
        [Parameter(Mandatory)][string]$TmpDir,
        [Parameter(Mandatory)][string]$TargetDir
    )

    New-DirectoryIfMissing -Path $TargetDir
    foreach ($item in @(Get-ChildItem -LiteralPath $TmpDir -Force -ErrorAction SilentlyContinue)) {
        $dest = Join-Path $TargetDir $item.Name
        if (Test-Path -LiteralPath $dest) { [void](Move-ExistingPathAside -Path $dest) }
        Move-Item -LiteralPath $item.FullName -Destination $dest -ErrorAction Stop
    }
    Remove-Item -LiteralPath $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
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

    if ($mp4Files.Count -eq 0) {
        Write-Host "未发现待分类的 .mp4 文件" -ForegroundColor Gray
        return
    }

    # 先把所有文件逐个问完：补零宽度取决于每组总数，必须在改名前确定。
    $classified = @()
    $skipped = 0
    foreach ($file in $mp4Files) {
        $archiveProfile = Select-ProfileForFile -DisplayName $file.Name
        if ($null -eq $archiveProfile) {
            $skipped++
            continue
        }
        $classified += [pscustomobject]@{ File = $file; Profile = $archiveProfile }
    }

    $groupCounts = @{}
    foreach ($item in $classified) {
        if (-not $groupCounts.ContainsKey($item.Profile.Key)) { $groupCounts[$item.Profile.Key] = 0 }
        $groupCounts[$item.Profile.Key]++
    }

    $summary = @()
    foreach ($key in @($groupCounts.Keys | Sort-Object)) {
        $summary += "{0} x {1}" -f $Profiles[$key].Display, $groupCounts[$key]
    }
    if ($skipped -gt 0) { $summary += "跳过 x $skipped" }
    Write-Host "[CLASSIFY] $($summary -join '，')" -ForegroundColor Cyan

    # 组内数量决定补零宽度：1-9 个不补零，10-99 个两位（F_01），100+ 三位，以此类推。
    $counters = @{}
    foreach ($item in $classified) {
        $key = $item.Profile.Key
        if (-not $counters.ContainsKey($key)) { $counters[$key] = 0 }
        $counters[$key]++
        $width = ([string]$groupCounts[$key]).Length
        $newBase = "{0}_{1}" -f $item.Profile.Prefix, $counters[$key].ToString("D$width")

        $desiredZipPath = Join-Path $item.File.DirectoryName ($newBase + ".zip")
        $zipPath = Get-UniqueFilePath -FilePath $desiredZipPath
        try {
            Rename-Item -LiteralPath $item.File.FullName -NewName (Split-Path -Leaf $zipPath) -ErrorAction Stop
            Write-Host "[RENAME] $($item.File.Name) -> $(Split-Path -Leaf $zipPath) [$($item.Profile.Display)]" -ForegroundColor Green
        } catch {
            Write-Host "[ERROR] MP4 重命名失败: $($item.File.Name) - $_" -ForegroundColor Red
        }
    }
}

# 收集一个源目录的最终层任务：每个内层入口对应一个预创建的隔离临时目录 output\.__unpack_<编号名>_<档名>
function Get-FinalLayerTasks {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$FinalDir,
        [Parameter(Mandatory)][string]$ArchiveKey
    )

    $entries = @(Get-ArchiveEntrypoints -RootDir $SourceDir)
    if ($entries.Count -eq 0) { return @() }

    New-DirectoryIfMissing -Path $Output
    $tasks = @()
    foreach ($entry in $entries) {
        $baseName = Get-SafeFolderName -Name $entry.Base
        $tmpTarget = Get-UniqueDirectoryPath -DirectoryPath (Join-Path $Output (".__unpack_" + (Split-Path -Leaf $FinalDir) + "_" + $baseName))
        New-DirectoryIfMissing -Path $tmpTarget
        $tasks += [pscustomobject]@{ Entry = $entry; TargetDir = $tmpTarget; ArchiveKey = $ArchiveKey; FinalDir = $FinalDir }
    }
    return @($tasks)
}

# 最终层收割：成功把全部内容移入编号目录、失败清理临时目录（串行，绝不并发）
function Complete-FinalLayerResult {
    param(
        [Parameter(Mandatory)][pscustomobject]$Result,
        [Parameter(Mandatory)][string]$LayerName
    )

    $leaf = Split-Path -Leaf $Result.Task.Entry.Path
    if ($Result.Success) {
        Move-ExtractedContentIntoNamedDir -TmpDir $Result.Task.TargetDir -TargetDir $Result.Task.FinalDir
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
        if ($job.Stage0Dir) { $knownStage0Dirs[(Get-NormalizedPath -Path $job.Stage0Dir)] = $true }
    }

    $resumedJobs = @()
    foreach ($groupKey in @('FLYYZ', 'yecgaa')) {
        $groupRoot = Join-Path $Output0 $groupKey
        if (-not (Test-Path -LiteralPath $groupRoot)) { continue }

        foreach ($dir in @(Get-ChildItem -LiteralPath $groupRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            $dirKey = Get-NormalizedPath -Path $dir.FullName
            if ($knownStage0Dirs.ContainsKey($dirKey)) { continue }
            if (@(Get-ArchiveEntrypoints -RootDir $dir.FullName).Count -eq 0) { continue }

            Write-Host "[RESUME] output0\$groupKey\$($dir.Name)" -ForegroundColor Cyan
            $resumedJobs += [pscustomobject]@{
                Success   = $true
                Profile   = $Profiles[$groupKey]
                Source    = $null
                Stage0Dir = $dir.FullName
                Name      = $dir.Name
                CleanupEntries = @()
                Resumed   = $true
            }
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
    param([string[]]$Dirs)
    foreach ($dir in $Dirs) {
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
Write-Host "FLYYZ/yecgaa 手动分类融合解压脚本（WinRAR）" -ForegroundColor Cyan
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

foreach ($dir in @($Output0, $Output)) { New-DirectoryIfMissing -Path $dir }
$excludeDirs = @($Output0, $Output)

Write-Host "步骤 0: 手动分类并还原 .mp4 -> F_*.zip / Y_*.zip" -ForegroundColor Yellow
Write-Host "----------------------------------------"
Convert-ClassifiedMp4ToZip -ExcludeDirs $excludeDirs

Write-Host "`n步骤 1: 初始入口 -> output0\<来源>\<编号名>" -ForegroundColor Yellow
Write-Host "----------------------------------------"
$initialEntries = @(Get-ArchiveEntrypoints -RootDir $WorkDir -ExcludeDirs $excludeDirs)
$jobs = @()
if ($initialEntries.Count -eq 0) {
    Write-Host "未发现可处理的初始压缩包" -ForegroundColor Gray
} else {
    $stage0Tasks = @()
    foreach ($entry in $initialEntries) {
        $archiveProfile = Get-ProfileForName -BaseName $entry.Base
        if ($null -eq $archiveProfile) {
            Write-Host "[SKIP] 未分类入口（非 F_*/Y_* 编号名）: $(Split-Path -Leaf $entry.Path)" -ForegroundColor DarkGray
            continue
        }

        Write-Host "[ARCHIVE] $(Split-Path -Leaf $entry.Path) [$($archiveProfile.Display)]" -ForegroundColor Cyan
        $targetName = Get-SafeFolderName -Name $entry.Base
        $desired = Join-Path (Join-Path $Output0 $archiveProfile.Key) $targetName
        $targetDir = Get-UniqueDirectoryPath -DirectoryPath $desired
        if ($targetDir -ne $desired) {
            Write-Host "  [RENAME] 目标目录已存在，改用: $(Split-Path -Leaf $targetDir)" -ForegroundColor Yellow
        }
        New-DirectoryIfMissing -Path $targetDir
        $stage0Tasks += [pscustomobject]@{ Entry = $entry; TargetDir = $targetDir; ArchiveKey = $archiveProfile.Password; Name = (Split-Path -Leaf $targetDir); Profile = $archiveProfile }
    }

    foreach ($r in @(Invoke-ExtractionBatch -Tasks $stage0Tasks -ThrottleLimit $Parallel)) {
        $leaf = Split-Path -Leaf $r.Task.Entry.Path
        if ($r.Success) { Write-Host "  [OK] 第一层完成 [$($r.Task.Profile.Display)]: $leaf" -ForegroundColor Green }
        else { Write-Host "  [FAIL] 第一层失败 [$($r.Task.Profile.Display)]: $leaf" -ForegroundColor Red }
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

Write-Host "`n步骤 2: output0\<来源>\<编号名> -> output\<编号名>" -ForegroundColor Yellow
Write-Host "----------------------------------------"
$chainResults = @()
$allFinalTasks = @()
foreach ($job in $successfulJobs) {
    $chain = [pscustomobject]@{
        Name           = $job.Name
        Profile        = $job.Profile
        Job            = $job
        Success        = $false
        HasFinalTasks  = $false
        FailedCount    = 0
        FailedStage    = ""
        CleanupEntries = @($job.CleanupEntries | Where-Object { $null -ne $_ })
    }

    # 整条链共用一个最终目录；上一批遗留的同名目录自动避让（F_01 -> F_01__2）。
    $desiredFinalDir = Join-Path $Output $job.Name
    $finalDir = Get-UniqueDirectoryPath -DirectoryPath $desiredFinalDir
    if ($finalDir -ne $desiredFinalDir) {
        Write-Host "  [RENAME] output\$($job.Name) 已存在，本批改用: $(Split-Path -Leaf $finalDir)" -ForegroundColor Yellow
    }

    Write-Host "[$($job.Profile.Display)] $($job.Name): output0\$($job.Profile.Key)\$($job.Name) -> output\$(Split-Path -Leaf $finalDir)" -ForegroundColor Cyan
    $finalTasks = @(Get-FinalLayerTasks -SourceDir $job.Stage0Dir -FinalDir $finalDir -ArchiveKey $job.Profile.Password)
    if ($finalTasks.Count -eq 0) {
        Write-Host "[最终层] 未发现可解压的压缩包" -ForegroundColor Gray
    } else {
        $chain.HasFinalTasks = $true
        foreach ($t in $finalTasks) { $t | Add-Member -NotePropertyName Chain -NotePropertyValue $chain }
        $allFinalTasks += $finalTasks
    }
    $chainResults += $chain
}

foreach ($r in @(Invoke-ExtractionBatch -Tasks $allFinalTasks -ThrottleLimit $Parallel)) {
    Complete-FinalLayerResult -Result $r -LayerName "最终层"
    $chain = $r.Task.Chain
    $chain.CleanupEntries = @($chain.CleanupEntries + $r.Task.Entry)
    if (-not $r.Success) { $chain.FailedCount++ }
}

Write-Host ""
foreach ($chain in $chainResults) {
    $chain.Success = $chain.HasFinalTasks -and ($chain.FailedCount -eq 0)
    if (-not $chain.Success) { $chain.FailedStage = "最终层" }
    if ($chain.Success) { Write-Host "[CHAIN OK] $($chain.Name)" -ForegroundColor Green }
    else { Write-Host "[CHAIN FAIL] $($chain.Name): $($chain.FailedStage)" -ForegroundColor Red }
}
Write-Host ""

if ($DeleteFlag) { Invoke-CompletedChainCleanup -Chains $chainResults }

if ($DeleteFlag) {
    Write-Host "`n清点空文件夹..." -ForegroundColor Yellow
    Write-Host "----------------------------------------"
    Remove-IntermediateDirsIfEmpty -Dirs @($Output0)
    Remove-EmptyDirs -Root $WorkDir -ProtectDirs @($Output)
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "全部完成" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "按回车键退出"

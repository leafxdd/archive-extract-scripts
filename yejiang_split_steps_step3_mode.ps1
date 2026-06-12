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
    - $parallel = N 可让最多 N 个 WinRAR 同时解压（1 = 串行）；落位与删除始终串行。
      SSD 建议 2-4，机械硬盘建议保持 1（并行寻道反而更慢）。
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

# 并行解压数：最多 N 个 WinRAR 同时解压（1 = 串行；落位与删除始终串行）。
# SSD 建议 2-4，机械硬盘建议保持 1（并行寻道反而更慢）。
$parallel = 1
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
if ($parallel -gt 1) { Write-Host "并行度: $parallel" -ForegroundColor Gray }
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

# 源压缩包总字节数（分卷计全组，分组模式与 Remove-ArchiveGroup 一致），仅用于进度估算。
function Get-ArchiveGroupBytes {
    param([Parameter(Mandatory)][pscustomobject]$Entry)

    $total = [long]0
    try {
        $groupPattern = switch -Regex ($Entry.Type) {
            '^(zip-z|zip-z01)$' { '^{0}\.z\d+$' -f [regex]::Escape($Entry.Base) }
            '^(zip|7z)-001$'    { '^{0}\.{1}\.\d+$' -f [regex]::Escape($Entry.Base), (($Entry.Type -split '-')[0]) }
            '^rar-part$'        { '^{0}\.part\d+\.rar$' -f [regex]::Escape($Entry.Base) }
            '^rar-r00$'         { '^{0}\.r\d\d$' -f [regex]::Escape($Entry.Base) }
            default             { $null }
        }
        if ($groupPattern) {
            foreach ($f in @(Get-ChildItem -LiteralPath $Entry.Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $groupPattern })) { $total += $f.Length }
        }
        # 主卷不在组模式内时单独计入（zip-z 的 .zip 主卷、rar-r00 的 .rar 主卷、所有单文件档）
        if ((-not $groupPattern -or (Split-Path -Leaf $Entry.Path) -notmatch $groupPattern) -and (Test-Path -LiteralPath $Entry.Path)) {
            $total += (Get-Item -LiteralPath $Entry.Path -Force -ErrorAction SilentlyContinue).Length
        }
    } catch { }
    return $total
}

# 解压进度（仅估算显示）：已解出字节 ÷ 源压缩包字节。本仓库内容多为已压缩媒体（接近 store 存储），
# 估算接近真实；压缩比偏离 1 时仅供参考，上限钳 99%。成败判定与本函数无关，一律以退出码 + 空解压防护为准。
# "当前文件"取目标目录里创建时间最新的文件——WinRAR 解压完成会把修改时间恢复为档内时间戳，
# 创建时间才反映真实解压时刻。
function Show-ExtractionProgress {
    param([object[]]$InFlightItems = @())

    foreach ($item in $InFlightItems) {
        $done = [long]0
        $latest = $null
        $latestTime = [datetime]::MinValue
        try {
            $dirInfo = [System.IO.DirectoryInfo]::new($item.ExtractJob.TargetDir)
            foreach ($f in $dirInfo.EnumerateFiles('*', [System.IO.SearchOption]::AllDirectories)) {
                $done += $f.Length
                if ($f.CreationTimeUtc -gt $latestTime) { $latestTime = $f.CreationTimeUtc; $latest = $f.Name }
            }
        } catch { }
        $pct = if ($item.TotalBytes -gt 0) { [Math]::Min(99, [int](100 * $done / $item.TotalBytes)) } else { 0 }
        $status = "约 {0}%（{1:N1} / {2:N1} MB）" -f $pct, ($done / 1MB), ($item.TotalBytes / 1MB)
        if ($latest) { $status += " · $latest" }
        Write-Progress -Id $item.ProgressId -Activity $item.Label -Status $status -PercentComplete $pct
    }
}

# 收割在飞队列的队头任务：等待其进程退出（期间每 300ms 刷新全部在飞任务的进度条）并校验结果。
function Complete-OldestExtraction {
    param([Parameter(Mandatory)][System.Collections.Generic.Queue[object]]$InFlight)

    $oldest = $InFlight.Peek()
    $proc = $oldest.ExtractJob.Proc
    while ($null -ne $proc -and -not $proc.WaitForExit(300)) {
        Show-ExtractionProgress -InFlightItems $InFlight.ToArray()
    }
    [void]$InFlight.Dequeue()
    Write-Progress -Id $oldest.ProgressId -Activity $oldest.Label -Completed
    $ok = Complete-WinRARExtract -ExtractJob $oldest.ExtractJob
    return [pscustomobject]@{ Task = $oldest.Task; Success = $ok }
}

# 批量解压调度：窗口内最多 ThrottleLimit 个 WinRAR 并发，结果严格按提交顺序收割。
# ThrottleLimit=1 时退化为"启动→等待→下一个"，与逐个同步解压完全等价。
# 等待期间以 Write-Progress 显示各在飞任务的估算进度（百分比 + 当前解压文件）。
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
    $submitted = 0

    foreach ($task in $Tasks) {
        while ($inFlight.Count -ge $limit) {
            $results.Add((Complete-OldestExtraction -InFlight $inFlight))
        }
        $submitted++
        Write-Host "[EXTRACT] ($(Get-EntryLabel -Entry $task.Entry)) $(Split-Path -Leaf $task.Entry.Path) -> $($task.TargetDir)" -ForegroundColor Yellow
        $extractJob = Start-WinRARExtract -ArchivePath $task.Entry.Path -TargetDir $task.TargetDir -ArchiveKey $task.ArchiveKey
        $label = "解压 [{0}/{1}] {2}" -f $submitted, $Tasks.Count, (Split-Path -Leaf $task.Entry.Path)
        $totalBytes = Get-ArchiveGroupBytes -Entry $task.Entry
        $inFlight.Enqueue([pscustomobject]@{
            Task       = $task
            ExtractJob = $extractJob
            ProgressId = $submitted
            Label      = $label
            TotalBytes = $totalBytes
        })
    }
    while ($inFlight.Count -gt 0) {
        $results.Add((Complete-OldestExtraction -InFlight $inFlight))
    }

    return $results.ToArray()
}

# 落位（串行）：把隔离临时目录的全部内容移入目标目录，条目冲突时把既有项改名让位。
function Move-ExtractedContentIntoDir {
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

# ==================== 主流程 ====================
New-DirectoryIfMissing -Path $Output0
New-DirectoryIfMissing -Path $Output
$excludeDirs = @($Output0, $Output)

# STEP 1: mp4 -> zip
Write-Host "[STEP 1] 递归查找 .mp4 -> 重命名为 .zip（不在此步解压）" -ForegroundColor Cyan
Write-Host ""
$mp4Files = @(Get-FilesWithPrunedDirs -RootDir $scriptDir -ExcludeDirs $excludeDirs |
    Where-Object { $_.Extension -ieq '.mp4' })
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
$step2Tasks = @()
foreach ($source in $sources) {
    $chain = [pscustomobject]@{
        Name           = $source.Base
        Success        = $false
        HasStep3Tasks  = $false
        FailedCount    = 0
        FailedStage    = ""
        Stage2Dir      = $null
        CleanupEntries = @($source)
    }

    # Step 2: 源 -> output0\<相对路径>\<压缩包名>\（隔离，串行预分配唯一目录）
    $relDir = Get-RelativeDirectory -RootDir $scriptDir -ChildDir $source.Dir
    $stage2Base = if ($relDir) { Join-Path (Join-Path $Output0 $relDir) (Get-SafeFolderName -Name $source.Base) } else { Join-Path $Output0 (Get-SafeFolderName -Name $source.Base) }
    Write-Host "[CHAIN] $($source.Base)" -ForegroundColor Cyan
    $stage2Dir = Get-UniqueDirectoryPath -DirectoryPath $stage2Base
    if ($stage2Dir -ne $stage2Base) {
        Write-Host "  [RENAME] 目标目录已存在，改用: $(Split-Path -Leaf $stage2Dir)" -ForegroundColor Yellow
    }
    New-DirectoryIfMissing -Path $stage2Dir
    $chain.Stage2Dir = $stage2Dir
    $step2Tasks += [pscustomobject]@{ Entry = $source; TargetDir = $stage2Dir; ArchiveKey = $password; Chain = $chain }
    $chains += $chain
}

foreach ($r in @(Invoke-ExtractionBatch -Tasks $step2Tasks -ThrottleLimit $parallel)) {
    $leaf = Split-Path -Leaf $r.Task.Entry.Path
    if ($r.Success) { Write-Host "  [OK] Step2 完成: $leaf" -ForegroundColor Green }
    else {
        $r.Task.Chain.FailedStage = "Step2"
        Write-Host "  [FAIL] Step2 失败: $leaf" -ForegroundColor Red
    }
}
Write-Host ""

# Step 3: 各成功链 output0 子树内的压缩包 -> output（平铺 / 保留结构）
$step3Tasks = @()
foreach ($chain in $chains) {
    if ($chain.FailedStage) { continue }
    $step3Entries = @(Get-ArchiveEntrypoints -RootDir $chain.Stage2Dir)
    if ($step3Entries.Count -eq 0) {
        Write-Host "[STEP3] $($chain.Name): 未发现可解压的中间压缩包" -ForegroundColor Yellow
        continue
    }
    $chain.HasStep3Tasks = $true
    foreach ($a in $step3Entries) {
        $chain.CleanupEntries = @($chain.CleanupEntries + $a)
        if ($step3Flatten) {
            New-DirectoryIfMissing -Path $Output
            $tmp = Get-UniqueDirectoryPath -DirectoryPath (Join-Path $Output (".__unpack_" + (Get-SafeFolderName -Name $a.Base)))
            New-DirectoryIfMissing -Path $tmp
            $step3Tasks += [pscustomobject]@{ Entry = $a; TargetDir = $tmp; ArchiveKey = $password; Chain = $chain; Kind = 'flatten' }
        } else {
            $relDir2 = Get-RelativeDirectory -RootDir $Output0 -ChildDir $a.Dir
            $desired = if ($relDir2) { Join-Path (Join-Path $Output $relDir2) (Get-SafeFolderName -Name $a.Base) } else { Join-Path $Output (Get-SafeFolderName -Name $a.Base) }
            $target = Get-UniqueDirectoryPath -DirectoryPath $desired
            if ($target -ne $desired) {
                Write-Host "  [RENAME] 目标目录已存在，改用: $(Split-Path -Leaf $target)" -ForegroundColor Yellow
            }
            New-DirectoryIfMissing -Path $target
            $step3Tasks += [pscustomobject]@{ Entry = $a; TargetDir = $target; ArchiveKey = $password; Chain = $chain; Kind = 'named' }
        }
    }
}

foreach ($r in @(Invoke-ExtractionBatch -Tasks $step3Tasks -ThrottleLimit $parallel)) {
    $chain = $r.Task.Chain
    $leaf = Split-Path -Leaf $r.Task.Entry.Path
    if ($r.Task.Kind -eq 'flatten') {
        if ($r.Success) { Move-ExtractedContentIntoDir -TmpDir $r.Task.TargetDir -TargetDir $Output }
        else { Remove-FailedExtractionTemp -TmpDir $r.Task.TargetDir }
    }
    if ($r.Success) { Write-Host "  [OK] Step3 完成: $leaf" -ForegroundColor Green }
    else {
        $chain.FailedCount++
        Write-Host "  [FAIL] Step3 失败: $leaf" -ForegroundColor Red
    }
}

Write-Host ""
foreach ($chain in $chains) {
    if ($chain.FailedStage -eq "Step2") {
        Write-Host "[CHAIN FAIL] $($chain.Name): Step2（源文件保留）" -ForegroundColor Red
        continue
    }
    $chain.Success = $chain.HasStep3Tasks -and ($chain.FailedCount -eq 0)
    if ($chain.Success) {
        Write-Host "[CHAIN OK] $($chain.Name)" -ForegroundColor Green
    } else {
        $chain.FailedStage = "Step3"
        Write-Host "[CHAIN FAIL] $($chain.Name): Step3（源文件保留）" -ForegroundColor Red
    }
}
Write-Host ""

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

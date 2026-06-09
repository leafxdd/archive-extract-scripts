#Requires -Version 5.1
<#
.SYNOPSIS
    DORO/PADIO 自动分类融合解压脚本
.DESCRIPTION
    1. 在工作目录中查找初始 .mp4 / 压缩包入口并按文件名分类：
       - 文件名包含 doro：使用 DORO 密码 doro，执行三层管线
       - 文件基名为四位数字：使用 PADIO 密码 PADIO294，执行两层管线
       - 无法自动分类：弹出方向键菜单，手动选择 DORO / PADIO / 跳过
    2. 中间层解压到压缩包对应的隔离目录，避免 output0/output1 平铺混在一起
    3. 最后一层使用 smart extract：压缩包根目录有文件夹则直接解到 output；否则解到同名目录
    4. 每次解压前做目标冲突检查，发现重复文件/目录会自动改名，避免覆盖
#>

param(
    [string]$WorkDir = $PSScriptRoot,
    [switch]$KeepFiles = $false
)

# ==================== 初始化 ====================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

$SevenZipExe = Join-Path $env:ProgramFiles "7-Zip-Zstandard\7z.exe"
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

    function Pad-ToDisplayWidth {
        param([string]$Text, [int]$TargetWidth)

        $displayWidth = Get-DisplayWidth -Text $Text
        $pad = $TargetWidth - $displayWidth
        if ($pad -gt 0) { return $Text + (' ' * $pad) }
        return $Text
    }

    $allLines = @(" $Title ") + ($Options | ForEach-Object { "  > $_" })
    $maxWidth = ($allLines | ForEach-Object { Get-DisplayWidth -Text $_ } | Measure-Object -Maximum).Maximum
    $width = [Math]::Max($maxWidth + 2, 30)

    try {
        while ($true) {
            [Console]::Clear()
            $border = "$horizontal" * $width
            Write-Host "$topLeft$border$topRight" -ForegroundColor Cyan
            $titleText = Pad-ToDisplayWidth -Text " $Title " -TargetWidth $width
            Write-Host "$vertical$titleText$vertical" -ForegroundColor Cyan
            Write-Host "$middleLeft$border$middleRight" -ForegroundColor Cyan

            for ($i = 0; $i -lt $Options.Count; $i++) {
                $marker = if ($i -eq $selected) { '>' } else { ' ' }
                $text = Pad-ToDisplayWidth -Text "  $marker $($Options[$i])" -TargetWidth $width
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
            Write-Host "  Up/Down 选择，Enter 确认，Esc 跳过" -ForegroundColor DarkGray

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
function Get-ArchiveEntrypoints {
    param(
        [Parameter(Mandatory)][string]$RootDir,
        [string[]]$ExcludeDirs = @()
    )

    $excludeNorm = @($ExcludeDirs | ForEach-Object { Get-NormalizedPath $_ })
    $allFiles = @(Get-ChildItem -LiteralPath $RootDir -Recurse -File -Force -ErrorAction SilentlyContinue)
    if ($allFiles.Count -eq 0) { return @() }

    $entries = @()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($file in $allFiles) {
        $skip = $false
        foreach ($ex in $excludeNorm) {
            if ($ex -and (Test-IsUnderPath -ChildPath $file.FullName -ParentPath $ex)) {
                $skip = $true
                break
            }
        }
        if ($skip) { continue }

        $name = $file.Name
        $full = $file.FullName

        if ($file.Extension -ieq '.rar') {
            if ($name -match '^(?<stem>.+?)\.part(?<part>\d+)\.rar$') {
                $partNum = 0
                [void][int]::TryParse($Matches.part, [ref]$partNum)
                if ($partNum -ne 1) { continue }
                if ($seen.Add($full)) {
                    $entries += [pscustomobject]@{ Path = $full; Type = 'rar-part'; Dir = $file.DirectoryName; Base = $Matches.stem }
                }
                continue
            }

            $r00 = Join-Path $file.DirectoryName ($file.BaseName + '.r00')
            $type = if (Test-Path -LiteralPath $r00) { 'rar-r00' } else { 'rar' }
            if ($seen.Add($full)) {
                $entries += [pscustomobject]@{ Path = $full; Type = $type; Dir = $file.DirectoryName; Base = $file.BaseName }
            }
            continue
        }

        if ($file.Extension -ieq '.zip' -or $file.Extension -ieq '.7z') {
            $isZipSplitZ = $false
            if ($file.Extension -ieq '.zip') {
                $z01 = Join-Path $file.DirectoryName ($file.BaseName + '.z01')
                $isZipSplitZ = Test-Path -LiteralPath $z01
            }
            $type = if ($isZipSplitZ) { 'zip-z' } else { $file.Extension.TrimStart('.') }
            if ($seen.Add($full)) {
                $entries += [pscustomobject]@{ Path = $full; Type = $type; Dir = $file.DirectoryName; Base = $file.BaseName }
            }
            continue
        }

        if ($name -match '^(?<stem>.+?)\.(?<fmt>7z|zip)\.(?<part>\d+)$') {
            $partNum = 0
            [void][int]::TryParse($Matches.part, [ref]$partNum)
            if ($partNum -ne 1) { continue }
            $fmt = $Matches.fmt.ToLowerInvariant()
            $type = "$fmt-001"
            if ($seen.Add($full)) {
                $entries += [pscustomobject]@{ Path = $full; Type = $type; Dir = $file.DirectoryName; Base = $Matches.stem }
            }
            continue
        }

        if ($name -match '^(?<stem>.+?)\.z(?<part>\d+)$') {
            $partNum = 0
            [void][int]::TryParse($Matches.part, [ref]$partNum)
            if ($partNum -ne 1) { continue }
            $zipCandidate = Join-Path $file.DirectoryName ($Matches.stem + '.zip')
            if (Test-Path -LiteralPath $zipCandidate) {
                if ($seen.Add($zipCandidate)) {
                    $entries += [pscustomobject]@{ Path = $zipCandidate; Type = 'zip-z'; Dir = $file.DirectoryName; Base = $Matches.stem }
                }
            } else {
                if ($seen.Add($full)) {
                    $entries += [pscustomobject]@{ Path = $full; Type = 'zip-z01'; Dir = $file.DirectoryName; Base = $Matches.stem }
                }
            }
            continue
        }
    }

    return @($entries)
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

# ==================== 压缩包预读和冲突处理 ====================
function Get-ArchiveListing {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$ArchiveKey
    )

    try {
        $raw = & $SevenZipExe l "-p$ArchiveKey" -slt -- $ArchivePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [WARN] 无法预读压缩包结构: $(Split-Path -Leaf $ArchivePath)" -ForegroundColor Yellow
            return $null
        }

        $entries = @()
        $current = @{}
        foreach ($line in $raw) {
            if ($line -match '^Path = (.*)$') {
                if ($current.ContainsKey('Path')) {
                    $entries += [pscustomobject]$current
                }
                $current = @{ Path = $matches[1] }
            } elseif ($line -match '^Folder = (.*)$') {
                $current['Folder'] = $matches[1]
            } elseif ($line -match '^Attributes = (.*)$') {
                $current['Attributes'] = $matches[1]
            }
        }
        if ($current.ContainsKey('Path')) {
            $entries += [pscustomobject]$current
        }

        $archiveLeaf = Split-Path $ArchivePath -Leaf
        $archiveFull = Get-NormalizedPath -Path $ArchivePath
        $filteredEntries = @()
        foreach ($entry in $entries) {
            $entryPath = [string]$entry.Path
            if (-not $entryPath) { continue }
            if ($entryPath -eq $archiveLeaf) { continue }
            if ([System.IO.Path]::IsPathRooted($entryPath)) {
                if ((Get-NormalizedPath -Path $entryPath) -ieq $archiveFull) { continue }
            }
            $filteredEntries += $entry
        }
        return @($filteredEntries)
    } catch {
        Write-Host "  [WARN] 预读压缩包结构时出错: $_" -ForegroundColor Yellow
        return $null
    }
}

function Test-ArchiveRelativePathSafe {
    param([Parameter(Mandatory)][string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $false }
    if ([System.IO.Path]::IsPathRooted($RelativePath)) { return $false }

    $parts = $RelativePath -split '[/\\]+'
    foreach ($part in $parts) {
        if ($part -eq '..') { return $false }
    }
    return $true
}

function Assert-ArchiveListingSafe {
    param([Parameter(Mandatory)][object[]]$Listing)

    foreach ($entry in $Listing) {
        $rel = ([string]$entry.Path).TrimStart('\', '/')
        if (-not (Test-ArchiveRelativePathSafe -RelativePath $rel)) {
            throw "压缩包包含不安全路径: $($entry.Path)"
        }
    }
}

function Test-ArchiveHasRootFolderFromListing {
    param([object[]]$Listing)

    if ($null -eq $Listing) { return $false }

    foreach ($entry in $Listing) {
        $rel = ([string]$entry.Path).TrimStart('\', '/').TrimEnd('\', '/')
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        if (-not (Test-ArchiveRelativePathSafe -RelativePath $rel)) { continue }

        $parts = @($rel -split '[/\\]+')
        $isFolder = ($parts.Count -gt 1) -or
            ($entry.PSObject.Properties.Name -contains 'Folder' -and $entry.Folder -eq '+') -or
            ($entry.PSObject.Properties.Name -contains 'Attributes' -and $entry.Attributes -match '^D') -or
            ([string]$entry.Path).EndsWith('\') -or
            ([string]$entry.Path).EndsWith('/')

        if ($isFolder) { return $true }
    }

    return $false
}

function Get-ArchiveTopLevelNames {
    param([Parameter(Mandatory)][object[]]$Listing)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $names = @()

    foreach ($entry in $Listing) {
        $rel = ([string]$entry.Path).TrimStart('\', '/').TrimEnd('\', '/')
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        if (-not (Test-ArchiveRelativePathSafe -RelativePath $rel)) {
            throw "压缩包包含不安全路径: $($entry.Path)"
        }

        $top = @($rel -split '[/\\]+')[0]
        if ([string]::IsNullOrWhiteSpace($top)) { continue }
        if ($top -eq '.' -or $top -eq '..') {
            throw "压缩包包含不安全路径: $($entry.Path)"
        }

        if ($seen.Add($top)) {
            $names += $top
        }
    }

    return @($names)
}

function Resolve-FlatTargetConflicts {
    param(
        [Parameter(Mandatory)][object[]]$Listing,
        [Parameter(Mandatory)][string]$TargetDir
    )

    New-DirectoryIfMissing -Path $TargetDir
    $topNames = Get-ArchiveTopLevelNames -Listing $Listing
    foreach ($name in $topNames) {
        $targetPath = Join-Path $TargetDir $name
        if (Test-Path -LiteralPath $targetPath) {
            [void](Move-ExistingPathAside -Path $targetPath)
        }
    }
}

# ==================== 解压包装 ====================
function Invoke-7zExtract {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$TargetDir,
        [Parameter(Mandatory)][string]$ArchiveKey
    )

    & $SevenZipExe x "-p$ArchiveKey" -aot -y "-o$TargetDir" -- $ArchivePath | Out-Host
    return ($LASTEXITCODE -eq 0)
}

function Invoke-WinRARExtract {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$TargetDir,
        [Parameter(Mandatory)][string]$ArchiveKey
    )

    $proc = Start-Process -FilePath $WinRarExe -ArgumentList @(
        'x',
        "-p$ArchiveKey",
        '-ibck',
        '-y',
        '-or',
        "`"$ArchivePath`"",
        "`"$TargetDir\`""
    ) -Wait -PassThru -NoNewWindow

    return ($proc.ExitCode -eq 0)
}

function Invoke-PreparedExtraction {
    param(
        [Parameter(Mandatory)][pscustomobject]$Entry,
        [Parameter(Mandatory)][string]$TargetDir,
        [Parameter(Mandatory)][string]$ArchiveKey,
        [Parameter(Mandatory)][ValidateSet('7z', 'WinRAR')][string]$Tool,
        [Parameter(Mandatory)][ValidateSet('Isolated', 'Flat')][string]$TargetMode,
        [object[]]$Listing = $null
    )

    $needsListing = ($TargetMode -eq 'Flat')
    if ($null -eq $Listing -and $needsListing) {
        $Listing = Get-ArchiveListing -ArchivePath $Entry.Path -ArchiveKey $ArchiveKey
    }

    try {
        if ($null -ne $Listing) {
            Assert-ArchiveListingSafe -Listing $Listing
        }

        $actualTarget = $TargetDir
        if ($TargetMode -eq 'Isolated') {
            $actualTarget = Get-UniqueDirectoryPath -DirectoryPath $TargetDir
            if ($actualTarget -ne $TargetDir) {
                Write-Host "  [RENAME] 隔离目录已存在，改用: $(Split-Path -Leaf $actualTarget)" -ForegroundColor Yellow
            }
            New-DirectoryIfMissing -Path $actualTarget
        } else {
            New-DirectoryIfMissing -Path $actualTarget
            if ($null -ne $Listing) {
                Resolve-FlatTargetConflicts -Listing $Listing -TargetDir $actualTarget
            } else {
                Write-Host "  [WARN] 未能预读冲突，将依赖解压工具自动改名保护" -ForegroundColor Yellow
            }
        }

        Write-Host "[EXTRACT] ($(Get-EntryLabel -Entry $Entry)) $(Split-Path -Leaf $Entry.Path) -> $actualTarget" -ForegroundColor Yellow
        $success = if ($Tool -eq 'WinRAR') {
            Invoke-WinRARExtract -ArchivePath $Entry.Path -TargetDir $actualTarget -ArchiveKey $ArchiveKey
        } else {
            Invoke-7zExtract -ArchivePath $Entry.Path -TargetDir $actualTarget -ArchiveKey $ArchiveKey
        }

        return [pscustomobject]@{
            Success   = $success
            TargetDir = $actualTarget
        }
    } catch {
        Write-Host "  [ERROR] 解压前检查失败: $_" -ForegroundColor Red
        return [pscustomobject]@{
            Success   = $false
            TargetDir = $TargetDir
        }
    }
}

function Expand-ArchiveSmartFinal {
    param(
        [Parameter(Mandatory)][pscustomobject]$Entry,
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][string]$ArchiveKey
    )

    $listing = Get-ArchiveListing -ArchivePath $Entry.Path -ArchiveKey $ArchiveKey
    $hasRootFolder = Test-ArchiveHasRootFolderFromListing -Listing $listing

    if ($hasRootFolder) {
        Write-Host "  [SMART] 根目录含文件夹，直接解压到 output" -ForegroundColor DarkGray
        return Invoke-PreparedExtraction -Entry $Entry -TargetDir $OutputDir -ArchiveKey $ArchiveKey -Tool '7z' -TargetMode 'Flat' -Listing $listing
    }

    $folderName = Get-SafeFolderName -Name $Entry.Base
    $target = Join-Path $OutputDir $folderName
    Write-Host "  [SMART] 根目录无文件夹，解压到同名目录: $folderName" -ForegroundColor DarkGray
    return Invoke-PreparedExtraction -Entry $Entry -TargetDir $target -ArchiveKey $ArchiveKey -Tool '7z' -TargetMode 'Isolated' -Listing $listing
}

# ==================== 管线处理 ====================
function Convert-ClassifiedMp4ToZip {
    param([string[]]$ExcludeDirs)

    $mp4Files = @(Get-ChildItem -LiteralPath $WorkDir -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $candidate = $_.FullName
            $_.Extension -ieq '.mp4' -and
            -not (Test-IsUnderAnyPath -ChildPath $candidate -ParentPaths $ExcludeDirs)
        })

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

function Invoke-InitialStage {
    param(
        [Parameter(Mandatory)][pscustomobject]$Entry,
        [Parameter(Mandatory)][pscustomobject]$ArchiveProfile
    )

    $targetName = Get-SafeFolderName -Name $Entry.Base
    $targetDir = Join-Path $Output0 $targetName
    $result = Invoke-PreparedExtraction -Entry $Entry -TargetDir $targetDir -ArchiveKey $ArchiveProfile.Password -Tool 'WinRAR' -TargetMode 'Isolated'

    if ($result.Success) {
        Write-Host "  [OK] 第一层完成 [$($ArchiveProfile.Display)]" -ForegroundColor Green
        if ($DeleteFlag) {
            [void](Remove-ArchiveGroup -Entry $Entry)
            Write-Host "  [DELETE] 已删除源压缩包" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  [FAIL] 第一层失败 [$($ArchiveProfile.Display)]" -ForegroundColor Red
    }

    return [pscustomobject]@{
        Success   = $result.Success
        Profile   = $ArchiveProfile
        Source    = $Entry
        Stage0Dir = $result.TargetDir
        Name      = $targetName
    }
}

function Invoke-IntermediateLayer {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][pscustomobject]$ArchiveProfile,
        [Parameter(Mandatory)][string]$LayerName
    )

    $entries = @(Get-ArchiveEntrypoints -RootDir $SourceDir)
    if ($entries.Count -eq 0) {
        Write-Host "[$LayerName] 未发现可解压的压缩包" -ForegroundColor Gray
        return
    }

    foreach ($entry in $entries) {
        $relDir = Get-RelativeDirectory -RootDir $SourceDir -ChildDir $entry.Dir
        $archiveFolder = Get-SafeFolderName -Name $entry.Base
        $targetDir = if ($relDir) {
            Join-Path (Join-Path $TargetRoot $relDir) $archiveFolder
        } else {
            Join-Path $TargetRoot $archiveFolder
        }

        $result = Invoke-PreparedExtraction -Entry $entry -TargetDir $targetDir -ArchiveKey $ArchiveProfile.Password -Tool '7z' -TargetMode 'Isolated'
        if ($result.Success) {
            Write-Host "  [OK] $LayerName 完成" -ForegroundColor Green
            if ($DeleteFlag) {
                [void](Remove-ArchiveGroup -Entry $entry)
                Write-Host "  [DELETE] 已删除中间压缩包" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  [FAIL] $LayerName 失败" -ForegroundColor Red
        }
    }
}

function Invoke-FinalLayer {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][pscustomobject]$ArchiveProfile,
        [Parameter(Mandatory)][string]$LayerName
    )

    $entries = @(Get-ArchiveEntrypoints -RootDir $SourceDir)
    if ($entries.Count -eq 0) {
        Write-Host "[$LayerName] 未发现可解压的压缩包" -ForegroundColor Gray
        return
    }

    foreach ($entry in $entries) {
        $result = Expand-ArchiveSmartFinal -Entry $entry -OutputDir $Output -ArchiveKey $ArchiveProfile.Password
        if ($result.Success) {
            Write-Host "  [OK] $LayerName 完成" -ForegroundColor Green
            if ($DeleteFlag) {
                [void](Remove-ArchiveGroup -Entry $entry)
                Write-Host "  [DELETE] 已删除最终层源压缩包" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  [FAIL] $LayerName 失败" -ForegroundColor Red
        }
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
            Resumed   = $true
        }
    }

    return @($resumedJobs)
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

    $allDirs = @(Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $dir = $_.FullName
            -not ($ProtectDirs | Where-Object { Test-IsUnderPath -ChildPath $dir -ParentPath $_ })
        } |
        Sort-Object { $_.FullName.Split('\').Count } -Descending)

    $count = 0
    foreach ($dir in $allDirs) {
        $items = @(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue)
        if ($items.Count -eq 0) {
            try {
                Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop
                $count++
            } catch {
                Write-Verbose "删除空文件夹失败: $($dir.FullName) - $_"
            }
        }
    }

    if ($count -gt 0) {
        Write-Host "  [OK] 清理了 $count 个空文件夹" -ForegroundColor Green
    }
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
Write-Host "DORO/PADIO 自动分类融合解压脚本" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path -LiteralPath $SevenZipExe)) {
    Write-Host "错误: 未找到 7-Zip-Zstandard" -ForegroundColor Red
    Write-Host "路径: $SevenZipExe" -ForegroundColor Red
    Read-Host "按回车键退出"
    exit 1
}
Write-Host "[OK] 7-Zip-Zstandard: $SevenZipExe" -ForegroundColor Green

if (-not (Test-Path -LiteralPath $WinRarExe)) {
    Write-Host "错误: 未找到 WinRAR" -ForegroundColor Red
    Write-Host "路径: $WinRarExe" -ForegroundColor Red
    Read-Host "按回车键退出"
    exit 1
}
Write-Host "[OK] WinRAR: $WinRarExe" -ForegroundColor Green
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
    foreach ($entry in $initialEntries) {
        $archiveProfile = Resolve-ArchiveProfile -BaseName $entry.Base -DisplayName (Split-Path -Leaf $entry.Path) -FullPath $entry.Path -PromptIfUnknown
        if ($null -eq $archiveProfile) {
            Write-Host "[SKIP] 无法分类: $(Split-Path -Leaf $entry.Path)" -ForegroundColor DarkGray
            continue
        }

        Write-Host "[CLASSIFY] $(Split-Path -Leaf $entry.Path) -> $($archiveProfile.Display), $($archiveProfile.Depth) 层" -ForegroundColor Cyan
        $job = Invoke-InitialStage -Entry $entry -ArchiveProfile $archiveProfile
        $jobs += $job
        Write-Host ""
    }
}

$successfulJobs = @($jobs | Where-Object { $_.Success })
$resumedJobs = @(Get-ResumableStage0Jobs -ExistingJobs $successfulJobs)
if ($resumedJobs.Count -gt 0) {
    Write-Host "`n恢复已有 output0 中间任务: $($resumedJobs.Count) 个" -ForegroundColor Yellow
    $successfulJobs = @($successfulJobs + $resumedJobs)
}

Write-Host "`n步骤 2: PADIO 最终层 / DORO 中间层" -ForegroundColor Yellow
Write-Host "----------------------------------------"
foreach ($job in $successfulJobs) {
    if ($job.Profile.Key -eq 'PADIO') {
        Write-Host "[PADIO] $($job.Name): output0\$($job.Name) -> output (smart)" -ForegroundColor Cyan
        Invoke-FinalLayer -SourceDir $job.Stage0Dir -ArchiveProfile $job.Profile -LayerName "PADIO 最终层"
        Write-Host ""
    } elseif ($job.Profile.Key -eq 'DORO') {
        $targetRoot = Join-Path $Output1 $job.Name
        New-DirectoryIfMissing -Path $targetRoot
        Write-Host "[DORO] $($job.Name): output0\$($job.Name) -> output1\$($job.Name)\<压缩包名>" -ForegroundColor Cyan
        Invoke-IntermediateLayer -SourceDir $job.Stage0Dir -TargetRoot $targetRoot -ArchiveProfile $job.Profile -LayerName "DORO 中间层"
        Write-Host ""
    }
}

Write-Host "`n步骤 3: DORO 最终层" -ForegroundColor Yellow
Write-Host "----------------------------------------"
$doroJobs = @($successfulJobs | Where-Object { $_.Profile.Key -eq 'DORO' })
if ($doroJobs.Count -eq 0) {
    Write-Host "没有 DORO 任务需要第三层解压" -ForegroundColor Gray
} else {
    foreach ($job in $doroJobs) {
        $sourceDir = Join-Path $Output1 $job.Name
        if (-not (Test-Path -LiteralPath $sourceDir)) {
            Write-Host "[SKIP] DORO 中间目录不存在: $sourceDir" -ForegroundColor Yellow
            continue
        }
        Write-Host "[DORO] $($job.Name): output1\$($job.Name) -> output (smart)" -ForegroundColor Cyan
        Invoke-FinalLayer -SourceDir $sourceDir -ArchiveProfile $job.Profile -LayerName "DORO 最终层"
        Write-Host ""
    }
}

Remove-JunkFiles -Jobs $successfulJobs

if ($DeleteFlag) {
    Write-Host "`n清理中间目录和空文件夹..." -ForegroundColor Yellow
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

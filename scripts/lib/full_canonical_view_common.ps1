$ErrorActionPreference = "Stop"

function Get-FcvNativePathText {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path must not be empty."
    }

    $normalized = $Path.Trim().Replace('/', '\')
    if ($normalized.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = '\\' + $normalized.Substring(8)
    }
    elseif ($normalized.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(4)
    }

    $isDriveAbsolute = $false
    if ($normalized.Length -ge 3) {
        $drive = $normalized[0]
        $isLetter = (($drive -ge 'A' -and $drive -le 'Z') -or ($drive -ge 'a' -and $drive -le 'z'))
        $isDriveAbsolute = $isLetter -and $normalized[1] -eq ':' -and $normalized[2] -eq '\'
    }

    $isUncAbsolute = $false
    if ($normalized.StartsWith('\\', [System.StringComparison]::Ordinal)) {
        $uncRemainder = $normalized.Substring(2)
        $serverSeparator = $uncRemainder.IndexOf('\')
        if ($serverSeparator -gt 0 -and $serverSeparator -lt ($uncRemainder.Length - 1)) {
            $server = $uncRemainder.Substring(0, $serverSeparator)
            $shareAndRest = $uncRemainder.Substring($serverSeparator + 1)
            $shareSeparator = $shareAndRest.IndexOf('\')
            if ($shareSeparator -lt 0) {
                $share = $shareAndRest
            }
            else {
                $share = $shareAndRest.Substring(0, $shareSeparator)
            }
            $isUncAbsolute = -not [string]::IsNullOrWhiteSpace($server) -and -not [string]::IsNullOrWhiteSpace($share)
        }
    }

    if (-not $isDriveAbsolute -and -not $isUncAbsolute) {
        throw "Expected an absolute Windows path: $Path"
    }

    foreach ($segment in @($normalized -split '\\')) {
        if ($segment -eq '.' -or $segment -eq '..') {
            throw "Path must already be normalized and may not contain dot segments: $Path"
        }
    }

    return $normalized
}

function Get-FcvDirectoryPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = Get-FcvNativePathText -Path $Path
    $lastSeparator = $normalized.LastIndexOf('\')
    if ($lastSeparator -lt 0) {
        throw "Path has no directory separator: $Path"
    }
    if ($lastSeparator -eq 2 -and $normalized.Length -ge 3 -and $normalized[1] -eq ':') {
        return $normalized.Substring(0, 3)
    }
    return $normalized.Substring(0, $lastSeparator)
}

function Get-FcvFileNameText {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Replace('/', '\')
    $lastSeparator = $normalized.LastIndexOf('\')
    if ($lastSeparator -lt 0) { return $normalized }
    if ($lastSeparator -eq ($normalized.Length - 1)) { return "" }
    return $normalized.Substring($lastSeparator + 1)
}

function Join-FcvPathText {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Right)) {
        return $Left.TrimEnd([char[]]@('\', '/'))
    }
    return $Left.TrimEnd([char[]]@('\', '/')) + '\' + $Right.TrimStart([char[]]@('\', '/'))
}

function Get-FcvPathExtension {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $lastSlash = [Math]::Max($Path.LastIndexOf('\'), $Path.LastIndexOf('/'))
    $lastDot = $Path.LastIndexOf('.')
    if ($lastDot -lt 0 -or $lastDot -le $lastSlash -or $lastDot -eq ($Path.Length - 1)) {
        return ""
    }
    return $Path.Substring($lastDot).ToLowerInvariant()
}

function Test-FcvVideoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return Test-TvaVideoExtension -Path $Path
}

function Get-FcvFileStem {
    param([Parameter(Mandatory = $true)][string]$Path)

    $name = Get-FcvFileNameText -Path $Path
    $lastDot = $name.LastIndexOf('.')
    if ($lastDot -le 0) { return $name }
    return $name.Substring(0, $lastDot)
}

function Test-FcvPathUnderOrEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $pathKey = Get-CvPathKey -Path $Path
    $rootKey = Get-CvPathKey -Path $Root
    if ([string]::IsNullOrWhiteSpace($pathKey) -or [string]::IsNullOrWhiteSpace($rootKey)) {
        return $false
    }
    if ($pathKey -eq $rootKey) { return $true }
    return $pathKey.StartsWith($rootKey + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-FcvDisjointRoots {
    param(
        [Parameter(Mandatory = $true)][object[]]$SourceRoots,
        [Parameter(Mandatory = $true)][string]$ViewRoot
    )

    foreach ($sourceRoot in @($SourceRoots)) {
        $root = [string]$sourceRoot
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if ((Test-FcvPathUnderOrEqual -Path $ViewRoot -Root $root) -or
            (Test-FcvPathUnderOrEqual -Path $root -Root $ViewRoot)) {
            throw "Source root and View root must be disjoint: source=$root view=$ViewRoot"
        }
    }
}

function Test-FcvNativeFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    Initialize-CvNativeHardLink
    return [CvNativeFileSystem]::FileExists((Get-FcvNativePathText -Path $Path))
}

function Test-FcvNativeDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    Initialize-CvNativeHardLink
    return [CvNativeFileSystem]::DirectoryExists((Get-FcvNativePathText -Path $Path))
}

function Get-FcvNativeFileLength {
    param([Parameter(Mandatory = $true)][string]$Path)

    Initialize-CvNativeHardLink
    return [long][CvNativeFileSystem]::GetLength((Get-FcvNativePathText -Path $Path))
}

function New-FcvNativeDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    Initialize-CvNativeHardLink
    [CvNativeFileSystem]::CreateDirectoryOne((Get-FcvNativePathText -Path $Path))
}

function New-FcvNativeDirectoryTree {
    param([Parameter(Mandatory = $true)][string]$Path)

    $rawPath = Get-FcvNativePathText -Path $Path
    $root = Get-CvVolumeRoot -Path $rawPath
    $fullPath = $rawPath.TrimEnd([char[]]@('\', '/'))
    $rootTrimmed = $root.TrimEnd([char[]]@('\', '/'))
    if ([string]::Equals($fullPath, $rootTrimmed, [System.StringComparison]::OrdinalIgnoreCase)) {
        return @()
    }
    if (-not $fullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Directory path is outside its parsed volume root: $fullPath"
    }

    $relative = $fullPath.Substring($root.Length).TrimStart([char[]]@('\', '/'))
    if ([string]::IsNullOrWhiteSpace($relative)) { return @() }

    $current = $rootTrimmed
    $created = New-Object System.Collections.ArrayList
    foreach ($segment in @($relative -split '\\')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $current = Join-FcvPathText -Left $current -Right $segment
        if (-not (Test-FcvNativeDirectory -Path $current)) {
            New-FcvNativeDirectory -Path $current
            [void]$created.Add($current)
        }
    }
    return @($created)
}

function New-FcvNativeHardLink {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $newPath = Get-FcvNativePathText -Path $Path
    $existingPath = Get-FcvNativePathText -Path $Target
    if (-not (Test-FcvNativeFile -Path $existingPath)) {
        throw "Hardlink source does not exist: $existingPath"
    }
    if (Test-FcvNativeFile -Path $newPath) {
        throw "Hardlink destination already exists: $newPath"
    }

    $parent = Get-FcvDirectoryPath -Path $newPath
    if (-not (Test-FcvNativeDirectory -Path $parent)) {
        throw "Hardlink destination directory does not exist: $parent"
    }
    if ((Get-CvVolumeRoot -Path $existingPath) -ne (Get-CvVolumeRoot -Path $newPath)) {
        throw "Hardlink source and destination are on different volumes."
    }

    Initialize-CvNativeHardLink
    [CvNativeFileSystem]::CreateHardLink($newPath, $existingPath)
    if (-not (Test-FcvNativeFile -Path $newPath)) {
        throw "CreateHardLinkW returned success but destination is not visible: $newPath"
    }
    if ((Get-FcvNativeFileLength -Path $newPath) -ne (Get-FcvNativeFileLength -Path $existingPath)) {
        throw "Hardlink length mismatch: $newPath"
    }
}

function Copy-FcvNativeFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $sourcePath = Get-FcvNativePathText -Path $Source
    $destinationPath = Get-FcvNativePathText -Path $Destination
    if (-not (Test-FcvNativeFile -Path $sourcePath)) {
        throw "Copy source does not exist: $sourcePath"
    }
    if (Test-FcvNativeFile -Path $destinationPath) {
        throw "Copy destination already exists: $destinationPath"
    }

    Initialize-CvNativeHardLink
    [CvNativeFileSystem]::CopyFile($sourcePath, $destinationPath, $false)
    if (-not (Test-FcvNativeFile -Path $destinationPath)) {
        throw "Native copy returned success but destination is not visible: $destinationPath"
    }
}

function Remove-FcvNativeFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    Initialize-CvNativeHardLink
    [CvNativeFileSystem]::DeleteFileIfExists((Get-FcvNativePathText -Path $Path))
}

function Remove-FcvNativeDirectoryIfEmpty {
    param([Parameter(Mandatory = $true)][string]$Path)

    Initialize-CvNativeHardLink
    return [bool][CvNativeFileSystem]::RemoveDirectoryIfEmpty((Get-FcvNativePathText -Path $Path))
}

function Move-FcvNativeFileReplace {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Initialize-CvNativeHardLink
    [CvNativeFileSystem]::MoveReplace(
        (Get-FcvNativePathText -Path $Source),
        (Get-FcvNativePathText -Path $Destination))
}

function Get-FcvSourceFiles {
    param(
        [Parameter(Mandatory = $true)][string]$LibraryName,
        [Parameter(Mandatory = $true)][string]$LibraryRoot
    )

    Initialize-TvaNativeFileSystem
    $root = Get-FcvNativePathText -Path $LibraryRoot
    $result = @()
    foreach ($entry in @([TvaNativeFileSystem]::EnumerateFilesRecursive($root))) {
        $result += [pscustomobject]@{
            LibraryName = $LibraryName
            LibraryRoot = $root
            Path = [string]$entry.Path
            Length = [long]$entry.Length
            LastWriteTimeUtc = [datetime]$entry.LastWriteTimeUtc
        }
    }
    return @($result | Sort-Object Path)
}

function Get-FcvTargetIndex {
    param([object[]]$Targets = @())

    $index = @{}
    foreach ($target in @($Targets)) {
        $path = [string]$target.VideoPath
        if ([string]::IsNullOrWhiteSpace($path)) {
            throw "Correction target is missing VideoPath."
        }
        $key = Get-CvPathKey -Path $path
        if ($index.ContainsKey($key)) {
            throw "Duplicate correction target source path: $path"
        }
        $index[$key] = $target
    }
    return $index
}

function Get-FcvTargetForSidecar {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [object[]]$Targets = @()
    )

    if (Test-FcvVideoPath -Path $Path) { return $null }

    $sidecarDirectory = Get-FcvDirectoryPath -Path $Path
    $sidecarStem = Get-FcvFileStem -Path $Path
    $matches = @()

    foreach ($target in @($Targets)) {
        $targetPath = Get-FcvNativePathText -Path ([string]$target.VideoPath)
        $targetDirectory = Get-FcvDirectoryPath -Path $targetPath
        $targetStem = Get-FcvFileStem -Path $targetPath
        if ([string]::Equals($sidecarDirectory, $targetDirectory, [System.StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals($sidecarStem, $targetStem, [System.StringComparison]::OrdinalIgnoreCase)) {
            $matches += $target
        }
    }

    if ($matches.Count -gt 1) {
        throw "Sidecar matches multiple correction targets: $Path"
    }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Get-FcvOperation {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$IsVideo
    )

    if ($IsVideo) { return "HARDLINK" }
    $extension = Get-FcvPathExtension -Path $Path
    if (@('.ass', '.ssa', '.srt', '.vtt', '.sub', '.idx') -contains $extension) {
        return "HARDLINK"
    }
    return "COPY"
}

function Get-FcvRelativeFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $fullPath = Get-FcvNativePathText -Path $Path
    $fullRoot = (Get-FcvNativePathText -Path $Root).TrimEnd([char[]]@('\', '/'))
    $prefix = $fullRoot + '\'
    if (-not $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Source file is outside library root: source=$fullPath root=$fullRoot"
    }
    return $fullPath.Substring($prefix.Length)
}

function Get-FcvCanonicalPath {
    param(
        [Parameter(Mandatory = $true)][string]$ViewRoot,
        [Parameter(Mandatory = $true)][string]$LibraryName,
        [Parameter(Mandatory = $true)][string]$LibraryRoot,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [string]$ExpectedKey = ""
    )

    Assert-CvSafePathSegment -Value $LibraryName -Label "LibraryName"
    if (-not [string]::IsNullOrWhiteSpace($ExpectedKey) -and $ExpectedKey -notmatch '^S[0-9]+E[0-9]+$') {
        throw "Invalid correction episode key: $ExpectedKey"
    }

    $relative = Get-FcvRelativeFilePath -Path $SourcePath -Root $LibraryRoot
    $lastSeparator = $relative.LastIndexOf('\')
    $relativeDirectory = ""
    if ($lastSeparator -ge 0) { $relativeDirectory = $relative.Substring(0, $lastSeparator) }
    $sourceName = Get-FcvFileNameText -Path $SourcePath
    $targetName = $sourceName
    if (-not [string]::IsNullOrWhiteSpace($ExpectedKey)) {
        $targetName = "$ExpectedKey - $sourceName"
    }

    $directory = Join-FcvPathText -Left (Get-FcvNativePathText -Path $ViewRoot) -Right $LibraryName
    if (-not [string]::IsNullOrWhiteSpace($relativeDirectory)) {
        $directory = Join-FcvPathText -Left $directory -Right $relativeDirectory
    }
    return Join-FcvPathText -Left $directory -Right $targetName
}

function New-FcvPlan {
    param(
        [Parameter(Mandatory = $true)][object[]]$SourceFiles,
        [object[]]$Targets = @(),
        [Parameter(Mandatory = $true)][string]$ViewRoot
    )

    $targetIndex = Get-FcvTargetIndex -Targets $Targets
    $sourceIndex = @{}
    foreach ($source in @($SourceFiles)) {
        $sourcePath = [string]$source.Path
        if ([string]::IsNullOrWhiteSpace($sourcePath)) { throw "Source file row is missing Path." }
        $sourceKey = Get-CvPathKey -Path $sourcePath
        if ($sourceIndex.ContainsKey($sourceKey)) { throw "Duplicate source file path in inventory: $sourcePath" }
        $sourceIndex[$sourceKey] = $source
    }

    foreach ($target in @($Targets)) {
        $targetKey = Get-CvPathKey -Path ([string]$target.VideoPath)
        if (-not $sourceIndex.ContainsKey($targetKey)) {
            throw "Correction target is not present in source inventory: $($target.VideoPath)"
        }
        if (-not (Test-FcvVideoPath -Path ([string]$target.VideoPath))) {
            throw "Correction target is not a supported video file: $($target.VideoPath)"
        }
    }

    $plan = @()
    $canonicalOwners = @{}
    foreach ($source in @($SourceFiles | Sort-Object Path)) {
        $sourcePath = [string]$source.Path
        $sourceKey = Get-CvPathKey -Path $sourcePath
        $isVideo = [bool](Test-FcvVideoPath -Path $sourcePath)
        $role = ""
        $expectedKey = ""

        if ($targetIndex.ContainsKey($sourceKey)) {
            $target = $targetIndex[$sourceKey]
            $role = "CORRECTION_VIDEO"
            $expectedKey = [string]$target.ExpectedKey
        }
        elseif (-not $isVideo) {
            $target = Get-FcvTargetForSidecar -Path $sourcePath -Targets $Targets
            if ($null -ne $target) {
                $role = "CORRECTION_SIDECAR"
                $expectedKey = [string]$target.ExpectedKey
            }
        }

        if ([string]::IsNullOrWhiteSpace($role)) {
            if ($isVideo) { $role = "PASSTHROUGH_VIDEO" } else { $role = "PASSTHROUGH_FILE" }
        }

        $canonicalPath = Get-FcvCanonicalPath -ViewRoot $ViewRoot -LibraryName ([string]$source.LibraryName) -LibraryRoot ([string]$source.LibraryRoot) -SourcePath $sourcePath -ExpectedKey $expectedKey
        $canonicalKey = Get-CvPathKey -Path $canonicalPath
        if ($canonicalOwners.ContainsKey($canonicalKey)) {
            throw "Canonical path collision: $canonicalPath :: source1=$($canonicalOwners[$canonicalKey]) source2=$sourcePath"
        }
        $canonicalOwners[$canonicalKey] = $sourcePath

        $plan += [pscustomobject]@{
            SourcePath = $sourcePath
            CanonicalPath = $canonicalPath
            LibraryName = [string]$source.LibraryName
            LibraryRoot = [string]$source.LibraryRoot
            RelativePath = Get-FcvRelativeFilePath -Path $sourcePath -Root ([string]$source.LibraryRoot)
            Role = $role
            Operation = Get-FcvOperation -Path $sourcePath -IsVideo $isVideo
            SourceLength = [long]$source.Length
            ExpectedKey = $expectedKey
            State = "UNCLASSIFIED"
        }
    }
    return @($plan)
}

function Get-FcvManifestIndex {
    param([object[]]$Rows = @())

    $index = @{}
    foreach ($row in @($Rows)) {
        $path = [string]$row.CanonicalPath
        if ([string]::IsNullOrWhiteSpace($path)) { throw "Full manifest row is missing CanonicalPath." }
        $key = Get-CvPathKey -Path $path
        if ($index.ContainsKey($key)) { throw "Duplicate CanonicalPath in full manifest: $path" }
        $index[$key] = $row
    }
    return $index
}

function Test-FcvExistingTarget {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][long]$ExpectedLength,
        [Parameter(Mandatory = $true)]$ManifestIndex
    )

    if (-not (Test-FcvNativeFile -Path $TargetPath)) {
        return [pscustomobject]@{ State = "MISSING"; Reason = "target does not exist" }
    }
    $targetKey = Get-CvPathKey -Path $TargetPath
    if (-not $ManifestIndex.ContainsKey($targetKey)) {
        return [pscustomobject]@{ State = "CONFLICT"; Reason = "target exists but is not full-manifest-managed" }
    }
    $row = $ManifestIndex[$targetKey]
    if ((Get-CvPathKey -Path ([string]$row.SourcePath)) -ne (Get-CvPathKey -Path $SourcePath)) {
        return [pscustomobject]@{ State = "CONFLICT"; Reason = "manifest source does not match current source" }
    }
    $actualLength = Get-FcvNativeFileLength -Path $TargetPath
    if ([long]$actualLength -ne [long]$ExpectedLength) {
        return [pscustomobject]@{ State = "CONFLICT"; Reason = "target length does not match source length" }
    }
    return [pscustomobject]@{ State = "REUSABLE"; Reason = "full-manifest-managed same source" }
}

function Merge-FcvManifestRows {
    param([object[]]$ExistingRows = @(), [object[]]$NewRows = @())

    $byCanonical = @{}
    foreach ($row in @($ExistingRows)) {
        $path = [string]$row.CanonicalPath
        if ([string]::IsNullOrWhiteSpace($path)) { throw "Existing full manifest row is missing CanonicalPath." }
        $key = Get-CvPathKey -Path $path
        if ($byCanonical.ContainsKey($key)) { throw "Duplicate CanonicalPath in existing full manifest: $path" }
        $byCanonical[$key] = $row
    }
    foreach ($row in @($NewRows)) {
        $path = [string]$row.CanonicalPath
        if ([string]::IsNullOrWhiteSpace($path)) { throw "New full manifest row is missing CanonicalPath." }
        $key = Get-CvPathKey -Path $path
        if ($byCanonical.ContainsKey($key)) {
            $existing = $byCanonical[$key]
            if ((Get-CvPathKey -Path ([string]$existing.SourcePath)) -ne (Get-CvPathKey -Path ([string]$row.SourcePath))) {
                throw "Canonical path cannot change source ownership: $path"
            }
        }
        $byCanonical[$key] = $row
    }
    return @($byCanonical.Values | Sort-Object CanonicalPath)
}

function Get-FcvRollbackPaths {
    param([object[]]$BuildRows = @())

    $result = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($row in @($BuildRows)) {
        if ([string]$row.Status -ne "CREATED") { continue }
        $path = [string]$row.CanonicalPath
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $key = Get-CvPathKey -Path $path
        if (-not $seen.ContainsKey($key)) {
            [void]$result.Add($path)
            $seen[$key] = $true
        }
    }
    return @($result)
}

$ErrorActionPreference = "Stop"

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

    return [System.IO.Path]::GetFileNameWithoutExtension($Path)
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

function Get-FcvSourceFiles {
    param(
        [Parameter(Mandatory = $true)][string]$LibraryName,
        [Parameter(Mandatory = $true)][string]$LibraryRoot
    )

    Initialize-TvaNativeFileSystem
    $result = @()
    foreach ($entry in @([TvaNativeFileSystem]::EnumerateFilesRecursive($LibraryRoot))) {
        $result += [pscustomobject]@{
            LibraryName = $LibraryName
            LibraryRoot = $LibraryRoot
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

    $sidecarDirectory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
    $sidecarStem = Get-FcvFileStem -Path $Path
    $matches = @()

    foreach ($target in @($Targets)) {
        $targetPath = [System.IO.Path]::GetFullPath([string]$target.VideoPath)
        $targetDirectory = [System.IO.Path]::GetDirectoryName($targetPath)
        $targetStem = Get-FcvFileStem -Path $targetPath

        if ([string]::Equals($sidecarDirectory, $targetDirectory, [System.StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals($sidecarStem, $targetStem, [System.StringComparison]::OrdinalIgnoreCase)) {
            $matches += $target
        }
    }

    if ($matches.Count -gt 1) {
        throw "Sidecar matches multiple correction targets: $Path"
    }
    if ($matches.Count -eq 1) {
        return $matches[0]
    }
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

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = ([System.IO.Path]::GetFullPath($Root)).TrimEnd([char[]]@('\', '/'))
    if ([string]::Equals($fullPath, $fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Source file path cannot equal its library root: $fullPath"
    }
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
    $relativeDirectory = [System.IO.Path]::GetDirectoryName($relative)
    $sourceName = [System.IO.Path]::GetFileName($SourcePath)
    $targetName = $sourceName
    if (-not [string]::IsNullOrWhiteSpace($ExpectedKey)) {
        $targetName = "$ExpectedKey - $sourceName"
    }

    $directory = [System.IO.Path]::Combine([System.IO.Path]::GetFullPath($ViewRoot), $LibraryName)
    if (-not [string]::IsNullOrWhiteSpace($relativeDirectory)) {
        $directory = [System.IO.Path]::Combine($directory, $relativeDirectory)
    }
    return [System.IO.Path]::Combine($directory, $targetName)
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
        if ([string]::IsNullOrWhiteSpace($sourcePath)) {
            throw "Source file row is missing Path."
        }
        $sourceKey = Get-CvPathKey -Path $sourcePath
        if ($sourceIndex.ContainsKey($sourceKey)) {
            throw "Duplicate source file path in inventory: $sourcePath"
        }
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
        $target = $null
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
            if ($isVideo) {
                $role = "PASSTHROUGH_VIDEO"
            }
            else {
                $role = "PASSTHROUGH_FILE"
            }
        }

        $canonicalPath = Get-FcvCanonicalPath `
            -ViewRoot $ViewRoot `
            -LibraryName ([string]$source.LibraryName) `
            -LibraryRoot ([string]$source.LibraryRoot) `
            -SourcePath $sourcePath `
            -ExpectedKey $expectedKey

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
        if ([string]::IsNullOrWhiteSpace($path)) {
            throw "Full manifest row is missing CanonicalPath."
        }
        $key = Get-CvPathKey -Path $path
        if ($index.ContainsKey($key)) {
            throw "Duplicate CanonicalPath in full manifest: $path"
        }
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

    if (-not (Test-CvNativeFile -Path $TargetPath)) {
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

    $actualLength = Get-CvNativeFileLength -Path $TargetPath
    if ([long]$actualLength -ne [long]$ExpectedLength) {
        return [pscustomobject]@{ State = "CONFLICT"; Reason = "target length does not match source length" }
    }

    return [pscustomobject]@{ State = "REUSABLE"; Reason = "full-manifest-managed same source" }
}

function Merge-FcvManifestRows {
    param(
        [object[]]$ExistingRows = @(),
        [object[]]$NewRows = @()
    )

    $byCanonical = @{}
    foreach ($row in @($ExistingRows)) {
        $path = [string]$row.CanonicalPath
        if ([string]::IsNullOrWhiteSpace($path)) {
            throw "Existing full manifest row is missing CanonicalPath."
        }
        $key = Get-CvPathKey -Path $path
        if ($byCanonical.ContainsKey($key)) {
            throw "Duplicate CanonicalPath in existing full manifest: $path"
        }
        $byCanonical[$key] = $row
    }

    foreach ($row in @($NewRows)) {
        $path = [string]$row.CanonicalPath
        if ([string]::IsNullOrWhiteSpace($path)) {
            throw "New full manifest row is missing CanonicalPath."
        }
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

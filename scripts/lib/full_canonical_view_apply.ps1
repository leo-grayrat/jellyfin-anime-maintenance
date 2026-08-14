$ErrorActionPreference = "Stop"

function New-FcvApplyManifestRow {
    param(
        [Parameter(Mandatory = $true)]$PlanRow,
        [Parameter(Mandatory = $true)][string]$BuildId,
        [Parameter(Mandatory = $true)][string]$Status
    )

    return [pscustomobject]@{
        SourcePath = [string]$PlanRow.SourcePath
        CanonicalPath = [string]$PlanRow.CanonicalPath
        LibraryName = [string]$PlanRow.LibraryName
        Role = [string]$PlanRow.Role
        Operation = [string]$PlanRow.Operation
        SourceLength = [long]$PlanRow.SourceLength
        ExpectedKey = [string]$PlanRow.ExpectedKey
        BuildId = $BuildId
        Status = $Status
    }
}

function Invoke-FcvApplyBuild {
    param(
        [Parameter(Mandatory = $true)]$Preflight,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ViewRoot,
        [Parameter(Mandatory = $true)][string]$TempRoot,
        [Parameter(Mandatory = $true)][string]$LogsRoot,
        [Parameter(Mandatory = $true)][string]$FullManifestPath
    )

    $BuildId = Get-Date -Format "yyyyMMdd-HHmmssfff"
    $BuildTemp = Join-FcvPathText -Left $TempRoot -Right "full-build-$BuildId"
    $PlanPath = Join-FcvPathText -Left $BuildTemp -Right "plan.csv"
    $ManifestTempPath = Join-FcvPathText -Left $BuildTemp -Right "full-manifest-v2.csv"
    $BuildLogTempPath = Join-FcvPathText -Left $BuildTemp -Right "full-build.csv"
    $BuildLogPath = Join-FcvPathText -Left $LogsRoot -Right "full-build-$BuildId.csv"

    New-FcvNativeDirectoryTree -Path $Root | Out-Null
    New-FcvNativeDirectoryTree -Path $ViewRoot | Out-Null
    New-FcvNativeDirectoryTree -Path $TempRoot | Out-Null
    New-FcvNativeDirectoryTree -Path $LogsRoot | Out-Null
    New-FcvNativeDirectoryTree -Path $BuildTemp | Out-Null

    @($Preflight.Plan) | Export-Csv -LiteralPath $PlanPath -NoTypeInformation -Encoding UTF8

    $buildRows = New-Object System.Collections.ArrayList
    $createdViewDirectories = New-Object System.Collections.ArrayList
    $createdDirectoryKeys = @{}
    $manifestCommitted = $false
    $rollbackErrors = New-Object System.Collections.ArrayList

    try {
        $rowNumber = 0
        foreach ($row in @($Preflight.Plan)) {
            $rowNumber++
            $wasMissing = ([string]$row.State -eq "MISSING")

            try {
                $parent = Get-FcvDirectoryPath -Path ([string]$row.CanonicalPath)
                $newDirectories = @(New-FcvNativeDirectoryTree -Path $parent)
                foreach ($directory in $newDirectories) {
                    if (-not (Test-FcvPathUnderOrEqual -Path $directory -Root $ViewRoot)) { continue }
                    $directoryKey = Get-CvPathKey -Path $directory
                    if (-not $createdDirectoryKeys.ContainsKey($directoryKey)) {
                        [void]$createdViewDirectories.Add($directory)
                        $createdDirectoryKeys[$directoryKey] = $true
                    }
                }

                if ([string]$row.State -eq "REUSABLE") {
                    $status = "REUSED"
                }
                elseif ([string]$row.State -eq "MISSING") {
                    if ([string]$row.Operation -eq "HARDLINK") {
                        New-FcvNativeHardLink -Path ([string]$row.CanonicalPath) -Target ([string]$row.SourcePath) | Out-Null
                    }
                    elseif ([string]$row.Operation -eq "COPY") {
                        Copy-FcvNativeFile -Source ([string]$row.SourcePath) -Destination ([string]$row.CanonicalPath)
                    }
                    else {
                        throw "Unsupported full-view operation: $($row.Operation)"
                    }
                    $status = "CREATED"
                }
                else {
                    throw "Unexpected full-view plan state: $($row.State)"
                }

                if (-not (Test-FcvNativeFile -Path ([string]$row.CanonicalPath))) {
                    throw "Canonical file is not visible after build step: $($row.CanonicalPath)"
                }
                $actualLength = Get-FcvNativeFileLength -Path ([string]$row.CanonicalPath)
                if ([long]$actualLength -ne [long]$row.SourceLength) {
                    throw "Canonical file length mismatch after build step: $($row.CanonicalPath)"
                }

                [void]$buildRows.Add((New-FcvApplyManifestRow -PlanRow $row -BuildId $BuildId -Status $status))
            }
            catch {
                if ($wasMissing -and (Test-FcvNativeFile -Path ([string]$row.CanonicalPath))) {
                    [void]$buildRows.Add((New-FcvApplyManifestRow -PlanRow $row -BuildId $BuildId -Status "CREATED"))
                }
                throw
            }

            if (($rowNumber % 100) -eq 0 -or $rowNumber -eq @($Preflight.Plan).Count) {
                Write-Host ("Ready: {0} / {1}" -f $rowNumber, @($Preflight.Plan).Count)
            }
        }

        $mergedManifest = @(Merge-FcvManifestRows -ExistingRows @($Preflight.FullManifestRows) -NewRows @($buildRows))
        if ($mergedManifest.Count -ne @($Preflight.Plan).Count) {
            throw "Merged full manifest count mismatch: manifest=$($mergedManifest.Count) plan=$(@($Preflight.Plan).Count)"
        }

        $mergedManifest | Export-Csv -LiteralPath $ManifestTempPath -NoTypeInformation -Encoding UTF8
        @($buildRows) | Export-Csv -LiteralPath $BuildLogTempPath -NoTypeInformation -Encoding UTF8

        Move-FcvNativeFileReplace -Source $ManifestTempPath -Destination $FullManifestPath
        $manifestCommitted = $true

        try {
            Move-FcvNativeFileReplace -Source $BuildLogTempPath -Destination $BuildLogPath
        }
        catch {
            Write-Warning ("Full manifest committed, but build log move failed: {0}" -f $_.Exception.Message)
        }
    }
    catch {
        $failure = $_
        if (-not $manifestCommitted) {
            Write-Host ""
            Write-Host "Rollback: removing only files created by this build under View..."
            foreach ($path in @(Get-FcvRollbackPaths -BuildRows @($buildRows))) {
                try {
                    if (-not (Test-FcvPathUnderOrEqual -Path $path -Root $ViewRoot)) {
                        throw "Rollback destination escaped View root: $path"
                    }
                    Remove-FcvNativeFile -Path $path
                }
                catch {
                    [void]$rollbackErrors.Add("file $path :: $($_.Exception.Message)")
                }
            }

            foreach ($directory in @($createdViewDirectories | Sort-Object { $_.Length } -Descending)) {
                try {
                    if (-not (Test-FcvPathUnderOrEqual -Path $directory -Root $ViewRoot)) {
                        throw "Rollback directory escaped View root: $directory"
                    }
                    [void](Remove-FcvNativeDirectoryIfEmpty -Path $directory)
                }
                catch {
                    [void]$rollbackErrors.Add("directory $directory :: $($_.Exception.Message)")
                }
            }
        }

        if ($rollbackErrors.Count -gt 0) {
            Write-Warning ("Rollback had {0} error(s). Build temp is preserved at {1}" -f $rollbackErrors.Count, $BuildTemp)
            foreach ($rollbackError in $rollbackErrors) { Write-Warning $rollbackError }
        }
        throw $failure
    }

    return [pscustomobject]@{
        BuildId = $BuildId
        BuildTemp = $BuildTemp
        BuildLogPath = $BuildLogPath
        ManifestPath = $FullManifestPath
        PlanCount = @($Preflight.Plan).Count
        CreatedCount = @($buildRows | Where-Object { $_.Status -eq "CREATED" }).Count
        ReusedCount = @($buildRows | Where-Object { $_.Status -eq "REUSED" }).Count
    }
}

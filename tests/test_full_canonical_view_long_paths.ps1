$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT TRUE FAILED: $Message" }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "ASSERT EQUAL FAILED: $Message. Expected=[$Expected] Actual=[$Actual]"
    }
}

. (Join-Path $PSScriptRoot "..\scripts\lib\canonical_view_common.ps1")
. (Join-Path $PSScriptRoot "..\scripts\lib\tv_audit_common.ps1")
. (Join-Path $PSScriptRoot "..\scripts\lib\full_canonical_view_common.ps1")

$longRelativeDirectory = ('very-long-subtitle-group-folder\' * 12).TrimEnd('\')
$longSource = 'D:\Bangumi\' + $longRelativeDirectory + '\episode[02].mkv'
Assert-True ($longSource.Length -gt 260) "fixture exceeds legacy MAX_PATH"
Assert-Equal (Get-FcvNativePathText -Path $longSource) $longSource "long absolute path remains lexical"
Assert-Equal (Get-FcvFileNameText -Path $longSource) 'episode[02].mkv' "long path filename"
Assert-Equal (Get-FcvFileStem -Path $longSource) 'episode[02]' "long path stem"
Assert-Equal (Get-FcvDirectoryPath -Path $longSource) ('D:\Bangumi\' + $longRelativeDirectory) "long path directory"
Assert-Equal (Get-FcvRelativeFilePath -Path $longSource -Root 'D:\Bangumi') ($longRelativeDirectory + '\episode[02].mkv') "long relative path"

$sourceFiles = @(
    [pscustomobject]@{
        LibraryName = 'TV'
        LibraryRoot = 'D:\Bangumi'
        Path = $longSource
        Length = 123L
    }
)
$plan = @(New-FcvPlan -SourceFiles $sourceFiles -Targets @() -ViewRoot 'D:\Resource\BangumiLink\View')
Assert-Equal $plan.Count 1 "long source produces one plan row"
Assert-Equal $plan[0].Role 'PASSTHROUGH_VIDEO' "long non-target remains passthrough"
Assert-Equal $plan[0].CanonicalPath ('D:\Resource\BangumiLink\View\TV\' + $longRelativeDirectory + '\episode[02].mkv') "long canonical path preserves relative structure"
Assert-True ($plan[0].CanonicalPath.Length -gt 260) "canonical path also exceeds MAX_PATH"

Assert-Equal (Get-FcvNativePathText -Path '\\?\D:\Bangumi\Show\ep.mkv') 'D:\Bangumi\Show\ep.mkv' "extended drive path normalizes lexically"
Assert-Equal (Get-FcvNativePathText -Path '\\?\UNC\server\share\Show\ep.mkv') '\\server\share\Show\ep.mkv' "extended UNC path normalizes lexically"

Write-Host "PASS: full canonical view long-path planning contract"

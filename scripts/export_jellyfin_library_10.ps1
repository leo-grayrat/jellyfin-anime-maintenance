[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiKey,
    [string]$Server = "http://127.0.0.1:8096",
    [string]$Output = "$env:USERPROFILE\Desktop\jellyfin-library-export.json"
)

$ErrorActionPreference = "Stop"
$Server = $Server.TrimEnd('/')
$Headers = @{ "X-Emby-Token" = $ApiKey }

$StartIndex = 0
$Limit = 500
$AllItems = @()
$Fields = [uri]::EscapeDataString("Path,ProviderIds,Overview,PremiereDate,DateCreated,OriginalTitle,SortName")
$Types = [uri]::EscapeDataString("Series,Season,Episode,Movie")

do {
    $Uri = "$Server/Items" +
           "?Recursive=true" +
           "&StartIndex=$StartIndex" +
           "&Limit=$Limit" +
           "&IncludeItemTypes=$Types" +
           "&Fields=$Fields" +
           "&EnableImages=false" +
           "&EnableUserData=false"

    $Response = Invoke-RestMethod -Uri $Uri -Headers $Headers
    $PageItems = @($Response.Items)
    $AllItems += $PageItems
    $StartIndex += $PageItems.Count
    Write-Host "已导出 $StartIndex / $($Response.TotalRecordCount)"
} while ($PageItems.Count -gt 0 -and $StartIndex -lt $Response.TotalRecordCount)

$Libraries = Invoke-RestMethod -Uri "$Server/Library/VirtualFolders" -Headers $Headers

$Export = @{
    ExportedAt = (Get-Date).ToString("o")
    Libraries  = $Libraries
    Items      = $AllItems
}

$Export | ConvertTo-Json -Depth 20 | Set-Content -Path $Output -Encoding UTF8
Write-Host ""
Write-Host "完成：$Output"
<#
.SYNOPSIS
  Pipeline 1 - lists every restore point (backup) available for the source DWs. Read-only.

.DESCRIPTION
  Writes a table per database to the job summary with a copy-paste "Restore point ID"
  for the "DW | 2. Restore Backup to New Database" pipeline, and saves backups.csv / backups.json for download.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$ServerName,
    [Parameter(Mandatory)][string[]]$Databases,
    [string]$OutDir = '.'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DwCommon.psm1') -Force

Connect-DwAzure -Force
$all = [System.Collections.Generic.List[object]]::new()
$nowUtc = (Get-Date).ToUniversalTime()

Write-Summary "# DW backups available on ``$ServerName``"
Write-Summary ""
Write-Summary "Copy a **Restore point ID** into the **DW | 2. Restore Backup to New Database** pipeline. Backups are kept for about 7 days, so restore before the *Available until* time."

foreach ($db in ($Databases | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    $dbObj = Get-AzSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $ServerName -DatabaseName $db

    if ($dbObj.Edition -ne 'DataWarehouse') {
        Write-Summary ""
        Write-Summary "## $db - skipped: '$($dbObj.Edition)' is not a Synapse dedicated SQL pool"
        continue
    }
    if ($dbObj.Status -ne 'Online') { Write-Summary ""; Write-Summary "> ``$db`` is **$($dbObj.Status)** - its restore points are still listed and usable." }

    # ---------------- Synapse dedicated SQL pool / SQL DW: discrete restore points
    $points = @(Get-DwRestorePoints -ResourceGroupName $ResourceGroupName -ServerName $ServerName -DatabaseName $db)

    Write-Summary ""
    Write-Summary "## $db - $($points.Count) backup(s)"
    Write-Summary ""
    if (-not $points) { Write-Summary "_No restore points found._"; continue }

    Write-Summary "| # | Restore point ID (copy this) | Taken (IST) | Kind | Label | Available until (IST, approx.) |"
    Write-Summary "|---|---|---|---|---|---|"
    $i = 0
    foreach ($p in $points) {
        $i++
        $id      = Format-DwRestorePointId $p
        $kind    = if ($p.Label) { 'User' } else { 'Auto' }
        $expires = $p.CreatedUtc.AddDays(7)
        $hoursLeft = [math]::Floor(($expires - $nowUtc).TotalHours)
        $until   = '{0:dd-MMM-yyyy HH:mm} ({1}h left)' -f (ConvertTo-Ist $expires), [math]::Max(0, $hoursLeft)
        Write-Summary ("| {0} | ``{1}`` | {2:dd-MMM-yyyy HH:mm} | {3} | {4} | {5} |" -f $i, $id, (ConvertTo-Ist $p.CreatedUtc), $kind, $p.Label, $until)

        $all.Add([pscustomobject]@{
            RestorePointId = $id
            Database       = $db
            CreatedUtc     = $p.CreatedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
            CreatedIst     = (ConvertTo-Ist $p.CreatedUtc).ToString('yyyy-MM-dd HH:mm:ss')
            Kind           = $kind
            Label          = $p.Label
            ApproxExpiresUtc = $expires.ToString('yyyy-MM-ddTHH:mm:ssZ')
        })
    }
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$all | Export-Csv -Path (Join-Path $OutDir 'backups.csv') -NoTypeInformation -Encoding utf8
ConvertTo-Json -InputObject @($all) -Depth 3 | Set-Content -Path (Join-Path $OutDir 'backups.json') -Encoding utf8
Set-Output 'count' $all.Count
if ($all.Count -gt 0) { Set-Output 'latest_id' ($all | Sort-Object CreatedUtc -Descending | Select-Object -First 1).RestorePointId }
Write-Host "Listed $($all.Count) restore point(s)."

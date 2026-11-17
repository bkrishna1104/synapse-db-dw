<#
.SYNOPSIS
  Pipeline 2 - restores a Synapse dedicated SQL pool (DW) restore point into a NEW database.
  Non-destructive.

.PARAMETER RestorePoint
  - an ID copied from the "DW | 1. List Available Backups" run, e.g. ifrs17_dw_prd@2025-11-17T05:33:42Z
  - latest : newest restore point of -SourceDatabaseName
  - new    : take a fresh user-defined restore point (backup) first, then restore it
  - backup-only : take a fresh restore point and stop (no restore, no target needed)

.DESCRIPTION
  Guardrails: the target name must be new, must differ from the source and must start with
  "<source>_dc_". It's checked before anything runs and again just before the restore. The
  restore point must still exist in Azure. Backup and restore are each waited on for up to
  -TimeoutMinutes (default 6 h), with the Azure sign-in renewed every 30 minutes. Nothing is
  deleted, paused, resumed or overwritten.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RestorePoint,
    [string]$TargetDatabaseName = '',       # required unless -RestorePoint backup-only
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$ServerName,
    [string]$SourceDatabaseName = '',       # used for 'latest' / 'new'; or to confirm an ID's DB
    [ValidatePattern('^(same-as-source|DW\d+c)$')]
    [string]$ServiceObjective = 'same-as-source',
    [string]$NewBackupLabel = '',
    [string[]]$AllowedSourceDatabases = @(),
    [ValidateRange(5, 7200)][int]$TimeoutMinutes = 360,
    [ValidateRange(15, 600)][int]$PollSeconds = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DwCommon.psm1') -Force

$Tag      = '_dc_'
$started  = Get-Date
$deadline = $started.AddMinutes($TimeoutMinutes)
$mode     = switch -Regex ($RestorePoint.Trim()) { '^(?i)latest$' { 'latest' } '^(?i)new$' { 'new' } '^(?i)backup-only$' { 'backup-only' } default { 'id' } }

function Get-DbOrNull([string]$Name) {
    try { Get-AzSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $ServerName -DatabaseName $Name -ErrorAction Stop }
    catch { if ($_.Exception.Message -match 'not found|ResourceNotFound|was not found') { $null } else { throw } }
}
function Get-Points { Get-DwRestorePoints -ResourceGroupName $ResourceGroupName -ServerName $ServerName -DatabaseName $SourceDatabaseName }
function Elapsed { '{0:N0} min' -f ((Get-Date) - $started).TotalMinutes }

Connect-DwAzure -Force
Write-Host "Mode=$mode  timeout=$TimeoutMinutes min (deadline $($deadline.ToUniversalTime().ToString('u')))"

# ---------------------------------------------------------------- Work out the source DB
$selected = $null
if ($mode -eq 'id') {
    $selected = ConvertFrom-DwRestorePointId $RestorePoint
    if ($selected.Database) { $SourceDatabaseName = $selected.Database }   # the ID names its own database
}
if (-not $SourceDatabaseName) { throw "Can't tell which database to restore. Use an ID like ifrs17_dw_prd@2025-11-17T05:33:42Z or set source_database." }
if ($AllowedSourceDatabases.Count -gt 0 -and ($AllowedSourceDatabases -inotcontains $SourceDatabaseName)) {
    throw "'$SourceDatabaseName' is not an allowed source. Allowed: $($AllowedSourceDatabases -join ', ')"
}

# ---------------------------------------------------------------- Source checks
$source = Get-DbOrNull $SourceDatabaseName
if (-not $source) { throw "Source database '$SourceDatabaseName' not found on $ServerName." }
if ($source.Edition -ne 'DataWarehouse') {
    throw "'$SourceDatabaseName' is '$($source.Edition)'. This pipeline is for Synapse dedicated SQL pools (DataWarehouse) only."
}
Write-Host "Source: $SourceDatabaseName  status=$($source.Status)  sku=$($source.CurrentServiceObjectiveName)"
if ($ServiceObjective -eq 'same-as-source') { $ServiceObjective = $source.CurrentServiceObjectiveName }

# ---------------------------------------------------------------- Target name guards (fail fast)
$TargetDatabaseName = $TargetDatabaseName.Trim()
if ($mode -eq 'backup-only') {
    if ($TargetDatabaseName) { Write-Warning "target_database_name is ignored for backup-only." }
} else {
if (-not $TargetDatabaseName) { throw "target_database_name is required." }
if ($TargetDatabaseName -notmatch '^[A-Za-z0-9_]{1,128}$') { throw "Target name may contain only letters, digits and underscore." }
if ($TargetDatabaseName -ieq $SourceDatabaseName)          { throw "Target cannot be the source database." }
if (-not $TargetDatabaseName.StartsWith("$SourceDatabaseName$Tag", [StringComparison]::OrdinalIgnoreCase)) {
    throw "Target must start with '$SourceDatabaseName$Tag' (e.g. $SourceDatabaseName${Tag}17_11_25) so restored copies are always distinguishable from production."
}
if (Get-DbOrNull $TargetDatabaseName) {
    throw "Target '$TargetDatabaseName' already exists on $ServerName. This pipeline never overwrites; choose a new name."
}
Write-Host "Target name '$TargetDatabaseName' is valid and free."
}

# ---------------------------------------------------------------- Resolve restore point
$pit = $null
if ($mode -notin 'new', 'backup-only') {
    $points = Get-Points
    if (-not $points) { throw "No restore points found for '$SourceDatabaseName'." }
    if ($mode -eq 'latest') {
        $pit = $points[0].CreatedUtc
    } else {
        $match = $points | Where-Object { [math]::Abs(($_.CreatedUtc - $selected.CreatedUtc).TotalSeconds) -lt 1 } | Select-Object -First 1
        if (-not $match) {
            throw "Restore point $($selected.CreatedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')) for $SourceDatabaseName is not available (backups expire after ~7 days). Run 'DW | 1. List Available Backups' and copy a current ID."
        }
        $pit = $match.CreatedUtc
    }
}
else {
    # ------------------------------------------------------------ Take a fresh backup, up to 6 h
    if ($source.Status -ne 'Online') { throw "Source must be Online to take a backup (current: $($source.Status))." }
    $label = if ($NewBackupLabel) { $NewBackupLabel.Trim() } else {
        "gha-run$($env:GITHUB_RUN_ID)-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmm'))"
    }
    if ($label.Length -gt 63) { $label = $label.Substring(0, 63) }
    if (Get-Points | Where-Object { $_.Label -eq $label }) { throw "A restore point labelled '$label' already exists. Use a different label." }

    Write-Host "Taking backup (user-defined restore point) '$label'"
    try {
        $null = New-AzSqlDatabaseRestorePoint -ResourceGroupName $ResourceGroupName -ServerName $ServerName `
                    -DatabaseName $SourceDatabaseName -RestorePointLabel $label
    } catch {
        Write-Warning "Backup call returned an error; it may still complete in Azure, polling: $($_.Exception.Message)"
    }
    $rp = Wait-DwCondition -What 'backup' -Deadline $deadline -PollSeconds $PollSeconds -Check {
        $p = Get-Points | Where-Object { $_.Label -eq $label } | Select-Object -First 1
        if (-not $p) { Write-Host "[$(Elapsed)] waiting for backup '$label'..." }
        $p
    }
    if (-not $rp) {
        Write-Summary "## Timed out after $TimeoutMinutes min waiting for backup '$label'"
        Write-Summary "Azure may still finish it; check with **DW | 1. List Available Backups**. Nothing was restored."
        throw "Timed out taking backup."
    }
    $pit = $rp.CreatedUtc
    Write-Summary "Backup **$label** taken at $($pit.ToString('yyyy-MM-ddTHH:mm:ssZ')) (IST $((ConvertTo-Ist $pit).ToString('dd-MMM-yyyy HH:mm'))) in $(Elapsed)."

    if ($mode -eq 'backup-only') {
        $id = Format-DwRestorePointId ([pscustomobject]@{ Database = $SourceDatabaseName; CreatedUtc = $pit })
        Set-Output 'restore_point_id' $id
        Write-Summary ""
        Write-Summary "## Backup taken - nothing restored"
        Write-Summary ""
        Write-Summary "| Item | Value |"
        Write-Summary "|---|---|"
        Write-Summary "| Restore point ID | ``$id`` |"
        Write-Summary "| Label | $label |"
        Write-Summary "| Taken (IST) | $((ConvertTo-Ist $pit).ToString('dd-MMM-yyyy HH:mm:ss')) |"
        Write-Summary "| Available until (approx.) | $((ConvertTo-Ist $pit.AddDays(7)).ToString('dd-MMM-yyyy HH:mm')) IST |"
        Write-Summary ""
        Write-Summary "To restore it later, run this pipeline with ``restore_point`` = ``$id`` and a new target name."
        return
    }
}

$pointId = Format-DwRestorePointId ([pscustomobject]@{ Database = $SourceDatabaseName; CreatedUtc = $pit })
Write-Host "Restore point: $pointId"

# ---------------------------------------------------------------- Restore into NEW database, up to 6 h
if (Get-DbOrNull $TargetDatabaseName) {
    throw "Target '$TargetDatabaseName' was created by someone else during this run. Aborting; nothing restored."
}

Write-Host "Restoring $pointId -> $TargetDatabaseName ($ServiceObjective)"
Connect-DwAzure -Force
$restoreArgs = @{
    FromPointInTimeBackup = $true
    PointInTime           = $pit
    ResourceGroupName     = $ResourceGroupName
    ServerName            = $ServerName
    TargetDatabaseName    = $TargetDatabaseName
    ResourceId            = $source.ResourceId
    ServiceObjectiveName  = $ServiceObjective
}

$job = $null
if ((Get-Command Restore-AzSqlDatabase).Parameters.ContainsKey('AsJob')) {
    # Submit in the background so we can poll with our own deadline and renew the sign-in.
    $job = Restore-AzSqlDatabase @restoreArgs -AsJob
    $sub = Wait-DwCondition -What 'restore submission' -Deadline $deadline -PollSeconds 20 -Check {
        if (Get-DbOrNull $TargetDatabaseName) { return 'submitted' }
        if ($job.State -eq 'Failed')    { return 'failed' }
        if ($job.State -eq 'Completed') { return 'submitted' }
        $null
    }
    if ($sub -eq 'failed' -and -not (Get-DbOrNull $TargetDatabaseName)) {
        $err = (@($job.JobStateInfo.Reason) + @($job.ChildJobs | ForEach-Object { $_.JobStateInfo.Reason; $_.Error })) |
               Where-Object { $_ } | Out-String
        throw "Restore request was rejected: $err"
    }
}
else {
    try { $null = Restore-AzSqlDatabase @restoreArgs }
    catch {
        if (-not (Get-DbOrNull $TargetDatabaseName)) { throw }
        Write-Warning "Restore call dropped but the database exists; polling. $($_.Exception.Message)"
    }
}

$restored = Wait-DwCondition -What 'restore' -Deadline $deadline -PollSeconds $PollSeconds -Check {
    $db = Get-DbOrNull $TargetDatabaseName
    $state = if ($db) { $db.Status } else { 'not visible yet' }
    Write-Host "[$(Elapsed)] $TargetDatabaseName : $state"
    if ($db -and $db.Status -eq 'Online') { $db } else { $null }
}
if ($job) { Remove-Job $job -Force -ErrorAction SilentlyContinue }   # client-side only; never cancels Azure work

if (-not $restored) {
    Write-Summary "## Timed out after $TimeoutMinutes min - restore still running in Azure"
    Write-Summary ""
    Write-Summary "``$TargetDatabaseName`` is not Online yet. Azure keeps restoring; this pipeline does not cancel it."
    throw "Timed out waiting for restore."
}

Set-Output 'target_database' $TargetDatabaseName
Set-Output 'restore_point_id' $pointId

Write-Summary "## Restore complete"
Write-Summary ""
Write-Summary "| Item | Value |"
Write-Summary "|---|---|"
Write-Summary "| Restore point | ``$pointId`` (IST $((ConvertTo-Ist $pit).ToString('dd-MMM-yyyy HH:mm'))) |"
Write-Summary "| New database | ``$TargetDatabaseName`` |"
Write-Summary "| Service objective | $ServiceObjective |"
Write-Summary "| Server | $ServerName.database.windows.net |"
Write-Summary "| Duration | $(Elapsed) |"
Write-Summary ""
Write-Summary "> The restored pool is billed while Online. Pause or drop it manually when done - this pipeline's SPN cannot."

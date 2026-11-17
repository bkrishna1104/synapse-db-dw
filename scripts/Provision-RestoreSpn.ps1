<#
.SYNOPSIS
  Creates (idempotently) a SECRETLESS service principal for the DW restore pipeline.

.DESCRIPTION
  - App registration + service principal, no client secret, no certificate
  - GitHub OIDC federated credential bound to ONE repo + ONE GitHub environment
  - Custom role "SQL DW Restore Operator (Non-Destructive)" scoped to ONE SQL server
  - Custom read-only role for async operation polling at subscription scope
  - Fails if the SPN ends up holding ANY other role assignment

  Run by an admin identity (see README) from the provision workflow or Cloud Shell.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DisplayName,
    [Parameter(Mandatory)][string]$GitHubRepository,     # org/repo
    [Parameter(Mandatory)][string]$GitHubEnvironment,    # e.g. dw-restore
    # Newer repos send an ID-based subject: repo:<owner>@<ownerId>/<repo>@<repoId>:environment:<env>.
    # Pass both IDs to trust that format as well (the workflow passes them automatically).
    [string]$GitHubOwnerId = '',
    [string]$GitHubRepositoryId = '',
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$ServerName,
    # operator = backup + restore (used by dw-backup-restore.yml, reviewers required)
    # reader   = list restore points only (used by the hourly dropdown refresh)
    [ValidateSet('operator', 'reader')][string]$Access = 'operator',
    [string]$InfraDir = (Join-Path $PSScriptRoot '../infra')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Summary([string]$Text) {
    Write-Host $Text
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Text }
}
function Set-Output([string]$Name, [string]$Value) {
    if ($env:GITHUB_OUTPUT) { Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value" }
}

if ($GitHubRepository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "GitHubRepository must be 'org/repo'." }
if ($GitHubEnvironment -notmatch '^[A-Za-z0-9_.-]+$')               { throw "Invalid GitHub environment name." }

Set-AzContext -Subscription $SubscriptionId | Out-Null
$subScope    = "/subscriptions/$SubscriptionId"
$serverScope = "$subScope/resourceGroups/$ResourceGroupName/providers/Microsoft.Sql/servers/$ServerName"

# Make sure the server exists before granting anything on it
$null = Get-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $ServerName

# ---------------------------------------------------------------- 1. Role definitions
# Every action must exist in Azure's own operation list; otherwise role creation fails with
# InvalidActionOrNotAction. Check up front so a wrong name gives a clear message.
$script:SqlOps = $null
function Assert-ActionsExist([string[]]$Actions, [string]$RoleName) {
    if (-not $script:SqlOps) {
        $script:SqlOps = @(Get-AzProviderOperation -OperationSearchString 'Microsoft.Sql/*' | ForEach-Object { $_.Operation.ToLowerInvariant() })
    }
    $missing = @()
    foreach ($a in $Actions) {
        if ($a.Contains('*')) {
            $rx = '^' + [regex]::Escape($a.ToLowerInvariant()).Replace('\*', '.*') + '$'
            if (-not ($script:SqlOps -match $rx)) { $missing += $a }
        } elseif ($script:SqlOps -notcontains $a.ToLowerInvariant()) { $missing += $a }
    }
    if ($missing) {
        $hint = ($script:SqlOps | Where-Object { $_ -like 'microsoft.sql/servers/databases/restorepoints*' -or $_ -like 'microsoft.sql/servers/databases/*operation*' }) -join "`n  "
        throw "Role '$RoleName' lists actions Azure doesn't know: $($missing -join ', ').`nRelated actions Azure does know:`n  $hint"
    }
}

function Ensure-RoleDefinition([string]$File) {
    $json    = (Get-Content -Raw $File) -replace '__SUBSCRIPTION_ID__', $SubscriptionId
    $desired = $json | ConvertFrom-Json
    Assert-ActionsExist @($desired.Actions) $desired.Name
    $existing = Get-AzRoleDefinition -Name $desired.Name -Scope $subScope -ErrorAction SilentlyContinue

    if (-not $existing) {
        $tmp = New-TemporaryFile
        Set-Content -Path $tmp -Value $json
        Write-Host "Creating custom role '$($desired.Name)'"
        $existing = New-AzRoleDefinition -InputFile $tmp
        Remove-Item $tmp
        return $existing
    }

    # Never silently widen a role: drift must be fixed deliberately by an owner.
    $have = @($existing.Actions | Sort-Object) -join ','
    $want = @($desired.Actions  | Sort-Object) -join ','
    if ($have -ne $want -or @($existing.DataActions).Count -gt 0 -or @($existing.NotActions).Count -gt 0) {
        throw "Role '$($desired.Name)' exists but differs from $File. Have: [$have] Want: [$want]. Fix it deliberately; this script will not change it."
    }
    Write-Host "Custom role '$($desired.Name)' already exists and matches."
    return $existing
}

if ($Access -eq 'operator') {
    $serverRole = Ensure-RoleDefinition (Join-Path $InfraDir 'role-dw-restore-operator.json')
    $statusRole = Ensure-RoleDefinition (Join-Path $InfraDir 'role-dw-restore-status-reader.json')
} else {
    $serverRole = Ensure-RoleDefinition (Join-Path $InfraDir 'role-dw-restore-point-reader.json')
    $statusRole = $null
}

# ---------------------------------------------------------------- 2. App + SPN (no secret)
$apps = @(Get-AzADApplication -DisplayName $DisplayName)
if ($apps.Count -gt 1) { throw "More than one app registration is named '$DisplayName'. Resolve manually." }
$app = if ($apps.Count -eq 1) { $apps[0] } else {
    Write-Host "Creating app registration '$DisplayName'"
    New-AzADApplication -DisplayName $DisplayName -SignInAudience AzureADMyOrg
}

$sp = Get-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction SilentlyContinue
if (-not $sp) {
    # A brand-new app takes a little while to replicate in Entra; until then Graph rejects the
    # service principal ("backing application ... must be in the local tenant"). Retry.
    for ($i = 1; $i -le 12; $i++) {
        try {
            Write-Host "Creating service principal (attempt $i)"
            $sp = New-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction Stop
            break
        } catch {
            $sp = Get-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction SilentlyContinue
            if ($sp) { break }
            if ($i -eq 12) { throw }
            Write-Host "Not ready yet: $($_.Exception.Message.Split([Environment]::NewLine)[0]). Waiting 15 s..."
            Start-Sleep -Seconds 15
        }
    }
}

# Some Az versions add a password when creating an SPN. This identity must be secretless.
foreach ($cred in @(Get-AzADAppCredential -ObjectId $app.Id -ErrorAction SilentlyContinue)) {
    Write-Host "Removing credential $($cred.KeyId) (SPN must use OIDC only)"
    Remove-AzADAppCredential -ObjectId $app.Id -KeyId $cred.KeyId
}

# ---------------------------------------------------------------- 3. Federated credentials
$issuer   = 'https://token.actions.githubusercontent.com'
$subjects = [ordered]@{ 'name' = "repo:${GitHubRepository}:environment:${GitHubEnvironment}" }
if ($GitHubOwnerId -and $GitHubRepositoryId) {
    $owner, $repoName = $GitHubRepository.Split('/')
    $subjects['ids'] = "repo:${owner}@${GitHubOwnerId}/${repoName}@${GitHubRepositoryId}:environment:${GitHubEnvironment}"
}
$existingFed = @(Get-AzADAppFederatedCredential -ApplicationObjectId $app.Id)
foreach ($kind in $subjects.Keys) {
    $subject = $subjects[$kind]
    if ($existingFed | Where-Object { $_.Subject -eq $subject -and $_.Issuer -eq $issuer }) { continue }
    $fedName = ('gha-' + $GitHubEnvironment + '-' + $kind + '-' + ($GitHubRepository -replace '[^A-Za-z0-9-]', '-'))
    if ($fedName.Length -gt 120) { $fedName = $fedName.Substring(0, 120) }
    Write-Host "Adding federated credential for $subject"
    $null = New-AzADAppFederatedCredential -ApplicationObjectId $app.Id -Name $fedName `
        -Issuer $issuer -Subject $subject -Audience 'api://AzureADTokenExchange'
}
$subject = ($subjects.Values -join '<br>')

# ---------------------------------------------------------------- 4. Role assignments
function Ensure-Assignment($RoleDef, [string]$Scope) {
    $has = Get-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionId $RoleDef.Id -Scope $Scope -ErrorAction SilentlyContinue |
           Where-Object { $_.Scope -eq $Scope }
    if ($has) { Write-Host "Assignment exists: $($RoleDef.Name) @ $Scope"; return }

    for ($i = 1; $i -le 10; $i++) {   # new SPNs take time to replicate
        try {
            $null = New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionId $RoleDef.Id -Scope $Scope
            Write-Host "Assigned: $($RoleDef.Name) @ $Scope"
            return
        } catch {
            if ($i -eq 10) { throw }
            Write-Host "Waiting for SPN replication (attempt $i): $($_.Exception.Message)"
            Start-Sleep -Seconds 15
        }
    }
}

Ensure-Assignment $serverRole $serverScope
if ($statusRole) { Ensure-Assignment $statusRole $subScope }

# ---------------------------------------------------------------- 5. Verify least privilege
$all = @(Get-AzRoleAssignment -ObjectId $sp.Id)
$allowed = @("$($serverRole.Id)|$serverScope")
if ($statusRole) { $allowed += "$($statusRole.Id)|$subScope" }
$unexpected = $all | Where-Object { "$($_.RoleDefinitionId)|$($_.Scope)" -notin $allowed }
if ($unexpected) {
    $list = ($unexpected | ForEach-Object { "$($_.RoleDefinitionName) @ $($_.Scope)" }) -join '; '
    throw "SPN has extra role assignments, which break the non-destructive guarantee: $list"
}
if (@(Get-AzADAppCredential -ObjectId $app.Id -ErrorAction SilentlyContinue).Count -gt 0) {
    throw "SPN still has a secret or certificate."
}

Set-Output 'client_id' $app.AppId
Write-Summary "## Restore SPN ready ($Access)"
Write-Summary ""
Write-Summary "| Item | Value |"
Write-Summary "|---|---|"
Write-Summary "| Display name | $DisplayName |"
Write-Summary "| Client ID | $($app.AppId) |"
Write-Summary "| Secrets | none (GitHub OIDC only) |"
Write-Summary "| Trusted subjects | $subject |"
Write-Summary "| Role | $($serverRole.Name) @ server $ServerName |"
if ($statusRole) { Write-Summary "| Role | $($statusRole.Name) @ subscription (read-only) |" }

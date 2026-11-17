# Shared helpers for the DW backup/restore scripts.
Set-StrictMode -Version Latest

function Write-Summary {
    param([string]$Text)
    Write-Host $Text
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Text }
}

function Set-Output {
    param([string]$Name, [string]$Value)
    if ($env:GITHUB_OUTPUT) { Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value" }
}

function ConvertTo-Utc {
    param([datetime]$Value)
    switch ($Value.Kind) {
        'Utc'   { return $Value }
        'Local' { return $Value.ToUniversalTime() }
        default { return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc) }   # API values are UTC
    }
}

function ConvertTo-Ist {
    param([datetime]$Utc)
    $tz = $null
    foreach ($id in 'Asia/Kolkata', 'India Standard Time') {
        try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch { }
    }
    if (-not $tz) { return $Utc.AddHours(5.5) }
    return [TimeZoneInfo]::ConvertTimeFromUtc($Utc, $tz)
}

# ------------------------------------------------------------------ Login
# GitHub OIDC tokens are short-lived and Azure access tokens last about 1 hour, so a
# 6-hour wait needs a fresh login. This asks GitHub for a new OIDC token every 30 minutes.
$script:LastLogin = [datetime]::MinValue
$script:LoginChecked = $false

function Connect-DwAzure {
    param([switch]$Force)
    if (-not $Force -and ((Get-Date) - $script:LastLogin).TotalMinutes -lt 30) { return }

    if ($env:ACTIONS_ID_TOKEN_REQUEST_URL) {
        foreach ($v in 'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID') {
            if (-not [Environment]::GetEnvironmentVariable($v)) { throw "Environment variable $v is not set." }
        }
        $uri = $env:ACTIONS_ID_TOKEN_REQUEST_URL + '&audience=api://AzureADTokenExchange'
        $jwt = (Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)" }).value

        if (-not $script:LoginChecked) {
            # Az PowerShell hides the real Entra error behind "Could not find tenant id". Exchange the
            # token directly once so a failure shows the AADSTS code and the subject GitHub sent.
            $payload = $jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
            $payload += '=' * ((4 - $payload.Length % 4) % 4)
            $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
            Write-Host "GitHub OIDC subject: $($claims.sub)"
            try {
                $null = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($env:AZURE_TENANT_ID)/oauth2/v2.0/token" -Body @{
                    client_id             = $env:AZURE_CLIENT_ID
                    client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
                    client_assertion      = $jwt
                    scope                 = 'https://management.azure.com/.default'
                    grant_type            = 'client_credentials'
                }
                Write-Host "Entra token exchange OK for client $($env:AZURE_CLIENT_ID)"
            } catch {
                $detail = $_.ErrorDetails.Message
                try { $detail = ($detail | ConvertFrom-Json).error_description } catch { }
                throw "Entra sign-in failed for client $($env:AZURE_CLIENT_ID) in tenant $($env:AZURE_TENANT_ID). GitHub subject was '$($claims.sub)'. Entra says: $detail"
            }
            $script:LoginChecked = $true
        }

        $null = Connect-AzAccount -ServicePrincipal -ApplicationId $env:AZURE_CLIENT_ID -Tenant $env:AZURE_TENANT_ID `
            -FederatedToken $jwt -Subscription $env:AZURE_SUBSCRIPTION_ID -Scope Process -WarningAction SilentlyContinue
        Write-Host "[$((Get-Date).ToUniversalTime().ToString('HH:mm:ss'))Z] Azure login refreshed"
    }
    elseif (-not (Get-AzContext)) {
        throw "Not running in GitHub Actions and no Az context. Run Connect-AzAccount first."
    }
    $script:LastLogin = Get-Date
}

# ------------------------------------------------------------------ Polling with deadline
function Wait-DwCondition {
    param(
        [Parameter(Mandatory)][scriptblock]$Check,   # return non-null/true when done
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][datetime]$Deadline,
        [int]$PollSeconds = 60
    )
    while ($true) {
        try {
            Connect-DwAzure
            $result = & $Check
            if ($result) { return $result }
        }
        catch {
            Write-Warning "Polling '$What' hit an error, re-authenticating: $($_.Exception.Message)"
            try { Connect-DwAzure -Force } catch { Write-Warning "Re-login failed: $($_.Exception.Message)" }
        }
        if ((Get-Date) -ge $Deadline) { return $null }
        Start-Sleep -Seconds $PollSeconds
    }
}

# ------------------------------------------------------------------ Restore points
function Get-DwRestorePoints {
    param([string]$ResourceGroupName, [string]$ServerName, [string]$DatabaseName)
    @(Get-AzSqlDatabaseRestorePoint -ResourceGroupName $ResourceGroupName -ServerName $ServerName -DatabaseName $DatabaseName |
        Where-Object { $_.RestorePointCreationDate } |
        ForEach-Object {
            [pscustomobject]@{
                Database   = $DatabaseName
                Type       = [string]$_.RestorePointType
                CreatedUtc = ConvertTo-Utc $_.RestorePointCreationDate
                Label      = [string]$_.RestorePointLabel
            }
        } | Sort-Object CreatedUtc -Descending)
}

# Restore point ID that the list pipeline prints and the restore pipeline accepts:
#   <database>@<yyyy-MM-ddTHH:mm:ssZ>     e.g. ifrs17_dw_prd@2025-11-17T05:33:42Z
function Format-DwRestorePointId {
    param([Parameter(Mandatory)]$Point)
    '{0}@{1}' -f $Point.Database, $Point.CreatedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

# Accepts "<db>@<utc>" or just "<utc>" (then Database is $null).
function ConvertFrom-DwRestorePointId {
    param([Parameter(Mandatory)][string]$Id)
    $Id = $Id.Trim().Trim('`', '"', "'")
    $db = $null; $ts = $Id
    if ($Id -match '^(?<db>[A-Za-z0-9_]+)@(?<ts>.+)$') { $db = $Matches.db; $ts = $Matches.ts }
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    $parsed = [datetime]::MinValue
    if (-not [DateTime]::TryParse($ts, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        throw "Cannot read restore point '$Id'. Copy the ID column from the 'DW | 1. List Available Backups' run, e.g. ifrs17_dw_prd@2025-11-17T05:33:42Z"
    }
    [pscustomobject]@{ Database = $db; CreatedUtc = $parsed }
}

Export-ModuleMember -Function *

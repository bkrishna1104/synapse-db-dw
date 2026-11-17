<#
.SYNOPSIS
  TEST ONLY. Builds a Synapse dedicated SQL pool with sample data, makes transactions,
  verifies restored copies, and pauses pools to save money.
  Refuses to run against a resource group or server named prd/prod.

.PARAMETER Action
  create-and-load   RG (if needed) + SQL server + dedicated pool + sample tables + batch A
  add-transactions  another batch; with -SimulateBadChange, afterwards delete half the sales
                    and zero all prices (to practise recovery)
  verify            compare a restored pool with the source
  pause-all         pause every Online dedicated pool on the test server (stops compute billing)
  resume            resume -DatabaseName
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('create-and-load', 'add-transactions', 'verify', 'pause-all', 'resume')][string]$Action,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$ServerName,
    [Parameter(Mandatory)][string]$DatabaseName,
    [string]$Location = 'centralindia',
    [ValidateSet('DW100c', 'DW200c')][string]$Sku = 'DW100c',
    [string]$SqlAdminLogin = 'sqladminuser',
    [string]$BatchName = '',
    [switch]$SimulateBadChange,
    [string]$VerifyDatabaseName = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../DwCommon.psm1') -Force

# ------------------------------------------------------------------ Safety: test resources only
foreach ($n in $ResourceGroupName, $ServerName) {
    if ($n -match '(?i)(^|[-_])(prd|prod|production)([-_\d]|$)') {
        throw "Refusing to run the TEST harness against '$n' (looks like production)."
    }
}
$fqdn = "$ServerName.database.windows.net"
Connect-DwAzure -Force

function Get-Db([string]$Name) {
    Get-AzSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $ServerName -DatabaseName $Name -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------ pause / resume (no SQL needed)
if ($Action -eq 'pause-all') {
    $pools = @(Get-AzSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $ServerName |
               Where-Object { $_.Edition -eq 'DataWarehouse' })
    Write-Summary "## Pausing dedicated pools on ``$ServerName``"
    Write-Summary ""
    Write-Summary "| Pool | Before | After |"
    Write-Summary "|---|---|---|"
    foreach ($p in $pools) {
        $before = $p.Status
        if ($before -eq 'Online') { $null = Suspend-AzSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $ServerName -DatabaseName $p.DatabaseName }
        Write-Summary "| ``$($p.DatabaseName)`` | $before | $((Get-Db $p.DatabaseName).Status) |"
    }
    Write-Summary ""
    Write-Summary "Paused pools cost storage only. Restore points stay usable while paused."
    return
}
if ($Action -eq 'resume') {
    $db = Get-Db $DatabaseName
    if (-not $db) { throw "'$DatabaseName' not found." }
    if ($db.Status -ne 'Online') { $null = Resume-AzSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $ServerName -DatabaseName $DatabaseName }
    Write-Summary "``$DatabaseName`` is $((Get-Db $DatabaseName).Status)."
    return
}

# ------------------------------------------------------------------ SQL helpers
$SqlAdminPassword = $env:TEST_SQL_ADMIN_PASSWORD
if (-not $SqlAdminPassword) { throw "Secret TEST_SQL_ADMIN_PASSWORD is not set." }
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Install-Module SqlServer -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
}
Import-Module SqlServer

function Invoke-Sql([string]$Db, [string]$Query) {
    for ($i = 1; $i -le 6; $i++) {
        try {
            return Invoke-Sqlcmd -ServerInstance "tcp:$fqdn,1433" -Database $Db -Username $SqlAdminLogin -Password $SqlAdminPassword `
                -Query $Query -QueryTimeout 1800 -ConnectionTimeout 60 -Encrypt Mandatory -ErrorAction Stop
        } catch {
            # firewall rules and freshly created pools can take a minute to accept logins
            if ($i -eq 6 -or $_.Exception.Message -notmatch 'firewall|Cannot open server|not currently available|login failed|timeout|transport|paused') { throw }
            Write-Host "SQL not reachable yet (attempt $i): $($_.Exception.Message.Split([Environment]::NewLine)[0])"
            Start-Sleep -Seconds 20
        }
    }
}

function Assert-Online([string]$Db) {
    $d = Get-Db $Db
    if (-not $d) { throw "'$Db' not found on $ServerName." }
    if ($d.Status -ne 'Online') { throw "'$Db' is $($d.Status). Run this pipeline with action 'resume' and database_name '$Db' first." }
}

function Get-Snapshot([string]$Db) {
    $exists = (Invoke-Sql $Db "SELECT CASE WHEN OBJECT_ID('dbo.RestoreTestLog') IS NULL THEN 0 ELSE 1 END AS x").x
    $batches = ''
    $logRows = 0
    if ($exists) {
        $rows = @(Invoke-Sql $Db "SELECT Batch, COUNT_BIG(*) AS c FROM dbo.RestoreTestLog GROUP BY Batch ORDER BY Batch")
        $batches = ($rows | ForEach-Object { "$($_.Batch)=$($_.c)" }) -join ', '
        $logRows = ($rows | Measure-Object -Property c -Sum).Sum
    }
    $now    = (Invoke-Sql $Db "SELECT SYSUTCDATETIME() AS t").t
    $price  = (Invoke-Sql $Db "SELECT CAST(SUM(ListPrice) AS decimal(18,2)) AS v FROM dbo.DimProduct").v
    $sales  = Invoke-Sql $Db "SELECT COUNT_BIG(*) AS n, CAST(SUM(Amount) AS decimal(18,2)) AS amt FROM dbo.FactSales"
    [pscustomobject]@{
        Database          = $Db
        SnapshotUtc       = [datetime]::SpecifyKind([datetime]$now, 'Utc')
        LogRows           = [long]$logRows
        Batches           = if ($batches) { $batches } else { '(none)' }
        ProductPriceTotal = [decimal]$price
        SalesRows         = [long]$sales.n
        SalesAmount       = [decimal]$sales.amt
    }
}

function Write-SnapshotTable([object[]]$Rows, [string]$Title) {
    Write-Summary ""
    Write-Summary "### $Title"
    Write-Summary ""
    Write-Summary "| Pool | Taken (UTC) | Test-log rows | Batches | Product price total | Sales rows | Sales amount |"
    Write-Summary "|---|---|---|---|---|---|---|"
    foreach ($s in $Rows) {
        Write-Summary ("| ``{0}`` | {1:yyyy-MM-ddTHH:mm:ssZ} | {2} | {3} | {4} | {5} | {6} |" -f $s.Database, $s.SnapshotUtc, $s.LogRows, $s.Batches, $s.ProductPriceTotal, $s.SalesRows, $s.SalesAmount)
    }
}

function Initialize-SampleData {
    Write-Host "Creating sample tables (DimProduct 200 rows, FactSales 100,000 rows, RestoreTestLog)"
    Invoke-Sql $DatabaseName @"
IF OBJECT_ID('dbo.DimProduct') IS NULL
    CREATE TABLE dbo.DimProduct (ProductKey int NOT NULL, ProductName nvarchar(50) NOT NULL, ListPrice decimal(18,2) NOT NULL)
    WITH (DISTRIBUTION = REPLICATE, CLUSTERED INDEX (ProductKey));
"@ | Out-Null
    Invoke-Sql $DatabaseName @"
IF OBJECT_ID('dbo.FactSales') IS NULL
    CREATE TABLE dbo.FactSales (SaleKey bigint NOT NULL, ProductKey int NOT NULL, Quantity int NOT NULL,
                                Amount decimal(18,2) NOT NULL, SaleDateUtc datetime2(0) NOT NULL)
    WITH (DISTRIBUTION = HASH(SaleKey), CLUSTERED COLUMNSTORE INDEX);
"@ | Out-Null
    Invoke-Sql $DatabaseName @"
IF OBJECT_ID('dbo.RestoreTestLog') IS NULL
    CREATE TABLE dbo.RestoreTestLog (Batch nvarchar(50) NOT NULL, RowNo int NOT NULL, CreatedUtc datetime2(0) NOT NULL)
    WITH (DISTRIBUTION = ROUND_ROBIN, HEAP);
"@ | Out-Null
    Invoke-Sql $DatabaseName @"
IF OBJECT_ID('dbo.Digits') IS NULL
    CREATE TABLE dbo.Digits (d int NOT NULL) WITH (DISTRIBUTION = REPLICATE, HEAP);
"@ | Out-Null
    if ([int](Invoke-Sql $DatabaseName "SELECT COUNT(*) AS n FROM dbo.Digits").n -ne 10) {
        Invoke-Sql $DatabaseName ("TRUNCATE TABLE dbo.Digits; " + ((0..9 | ForEach-Object { "INSERT INTO dbo.Digits (d) VALUES ($_);" }) -join ' ')) | Out-Null
    }
    Invoke-Sql $DatabaseName @"
IF NOT EXISTS (SELECT 1 FROM dbo.DimProduct)
    INSERT INTO dbo.DimProduct (ProductKey, ProductName, ListPrice)
    SELECT n, CONCAT(N'Product ', n), CAST(10 + (n % 90) AS decimal(18,2))
    FROM (SELECT a.d + 10 * b.d + 100 * c.d + 1 AS n
          FROM dbo.Digits a CROSS JOIN dbo.Digits b CROSS JOIN dbo.Digits c) x
    WHERE n <= 200;
"@ | Out-Null
    Invoke-Sql $DatabaseName @"
IF NOT EXISTS (SELECT 1 FROM dbo.FactSales)
    INSERT INTO dbo.FactSales (SaleKey, ProductKey, Quantity, Amount, SaleDateUtc)
    SELECT n, CAST(1 + n % 200 AS int), CAST(1 + n % 5 AS int),
           CAST((1 + n % 5) * (10 + n % 90) AS decimal(18,2)),
           DATEADD(minute, -CAST(n % 525600 AS int), SYSUTCDATETIME())
    FROM (SELECT CAST(a.d + 10 * b.d + 100 * c.d + 1000 * e.d + 10000 * f.d + 1 AS bigint) AS n
          FROM dbo.Digits a CROSS JOIN dbo.Digits b CROSS JOIN dbo.Digits c
          CROSS JOIN dbo.Digits e CROSS JOIN dbo.Digits f) x;
"@ | Out-Null
}

function Invoke-Batch([string]$Name) {
    Invoke-Sql $DatabaseName @"
DECLARE @maxKey bigint;
SET @maxKey = (SELECT ISNULL(MAX(SaleKey), 0) FROM dbo.FactSales);
BEGIN TRAN;
    INSERT INTO dbo.RestoreTestLog (Batch, RowNo, CreatedUtc)
    SELECT N'$Name', a.d + 10 * b.d + 1, SYSUTCDATETIME()
    FROM dbo.Digits a CROSS JOIN dbo.Digits b;

    INSERT INTO dbo.FactSales (SaleKey, ProductKey, Quantity, Amount, SaleDateUtc)
    SELECT @maxKey + n, CAST(1 + n % 200 AS int), 1, CAST(25 AS decimal(18,2)), SYSUTCDATETIME()
    FROM (SELECT CAST(a.d + 10 * b.d + 100 * c.d + 1 AS bigint) AS n
          FROM dbo.Digits a CROSS JOIN dbo.Digits b CROSS JOIN dbo.Digits c) x;

    UPDATE dbo.DimProduct SET ListPrice = ListPrice + 1 WHERE ProductKey <= 10;
COMMIT;
"@ | Out-Null
    Write-Host "Committed batch '$Name': +100 test-log rows, +1000 sales rows, +1 price on 10 products"
}

function Write-NextStep($Snap, [string]$Why) {
    Write-Summary ""
    Write-Summary "### Next: take a backup and restore it ($Why)"
    Write-Summary ""
    Write-Summary "Run **DW | 2. Restore Backup to New Database** with ``restore_point`` = ``new`` and a target such as ``$($DatabaseName)_dc_test1``."
    Write-Summary "It takes a restore point now and restores it. Expected in that copy: test-log rows **$($Snap.LogRows)** ($($Snap.Batches)), price total **$($Snap.ProductPriceTotal)**, sales rows **$($Snap.SalesRows)**, sales amount **$($Snap.SalesAmount)**."
}

# ------------------------------------------------------------------ Firewall: open for this runner only
$ruleName = "gha-test-$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)"
$ruleOpen = $false
try {
    if ($Action -eq 'create-and-load') {
        if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
            Write-Host "Creating resource group $ResourceGroupName in $Location"
            $null = New-AzResourceGroup -Name $ResourceGroupName -Location $Location
        }
        if (-not (Get-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $ServerName -ErrorAction SilentlyContinue)) {
            Write-Host "Creating SQL server $ServerName"
            $cred = [pscredential]::new($SqlAdminLogin, (ConvertTo-SecureString $SqlAdminPassword -AsPlainText -Force))
            $null = New-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $ServerName -Location $Location `
                        -SqlAdministratorCredentials $cred -ServerVersion '12.0' -MinimalTlsVersion '1.2'
        }
        if (Get-Db $DatabaseName) {
            Write-Summary "> Pool ``$DatabaseName`` already exists - not recreated; adding a batch to it."
        } else {
            Write-Host "Creating dedicated SQL pool $DatabaseName ($Sku) - takes about 5-10 minutes"
            $null = New-AzSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $ServerName -DatabaseName $DatabaseName `
                        -Edition DataWarehouse -RequestedServiceObjectiveName $Sku
        }
    }

    Assert-Online $DatabaseName
    if ($Action -eq 'verify') {
        if (-not $VerifyDatabaseName) { throw "verify_database_name is required for 'verify'." }
        Assert-Online $VerifyDatabaseName
    }

    $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json').ip
    Write-Host "Opening firewall rule $ruleName for runner IP $ip"
    $null = New-AzSqlServerFirewallRule -ResourceGroupName $ResourceGroupName -ServerName $ServerName `
                -FirewallRuleName $ruleName -StartIpAddress $ip -EndIpAddress $ip
    $ruleOpen = $true

    switch ($Action) {
        'create-and-load' {
            Initialize-SampleData
            $name = if ($BatchName) { $BatchName } else { 'A' }
            Invoke-Batch $name
            $snap = Get-Snapshot $DatabaseName
            Write-Summary "## Test pool ready: ``$DatabaseName`` ($Sku) on ``$ServerName``"
            Write-SnapshotTable @($snap) "State after batch '$name'"
            Write-NextStep $snap "state after batch '$name'"
            Write-Summary ""
            Write-Summary "> A $Sku pool is billed per hour while Online. Run this pipeline with **pause-all** when you stop testing."
        }
        'add-transactions' {
            $name = if ($BatchName) { $BatchName } else { 'B-' + (Get-Date).ToUniversalTime().ToString('HHmm') }
            Invoke-Batch $name
            $good = Get-Snapshot $DatabaseName
            Write-Summary "## Added batch '$name' to ``$DatabaseName``"
            Write-SnapshotTable @($good) "State after batch '$name'"
            if ($SimulateBadChange) {
                Invoke-Sql $DatabaseName "BEGIN TRAN; DELETE FROM dbo.FactSales WHERE SaleKey % 2 = 0; UPDATE dbo.DimProduct SET ListPrice = 0; COMMIT;" | Out-Null
                $bad = Get-Snapshot $DatabaseName
                Write-SnapshotTable @($bad) "After simulated accident (half the sales deleted, all prices zeroed)"
                Write-Summary ""
                Write-Summary "### Next: recover"
                Write-Summary ""
                Write-Summary "Run **DW | 1. List Available Backups** and copy the ID of the restore point taken **before** this run (e.g. from your earlier ``new`` restore), then **DW | 2** with that ID."
                Write-Summary "The restored copy should match the state at that restore point, with **no** zeroed prices."
            } else {
                Write-NextStep $good "state after batch '$name'"
            }
        }
        'verify' {
            $restored = Get-Snapshot $VerifyDatabaseName
            $current  = Get-Snapshot $DatabaseName
            Write-Summary "## Restore check"
            Write-SnapshotTable @($restored, $current) "Restored copy vs source as it is now"
            Write-Summary ""
            Write-Summary "Compare the restored row with the **Expected** values from the test run made just before that restore point was taken."
        }
    }
}
finally {
    if ($ruleOpen) {
        try {
            Connect-DwAzure
            Remove-AzSqlServerFirewallRule -ResourceGroupName $ResourceGroupName -ServerName $ServerName -FirewallRuleName $ruleName -Force | Out-Null
            Write-Host "Removed firewall rule $ruleName"
        } catch { Write-Warning "Could not remove firewall rule ${ruleName}: $($_.Exception.Message)" }
    }
}

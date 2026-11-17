# Testing the pipelines on your own GitHub + Azure (Synapse DW)

You'll build a **Synapse dedicated SQL pool** named like production (`ifrs17_dw_prd`) on a
**test** server in a **test** resource group, load sample tables, make transactions, **take a
backup** (user-defined restore point), **restore** it to a new pool, and check the data. Then
you'll practise recovering from a bad change.

**Cost:** a DW100c pool costs roughly USD 1-2 per hour while Online, and each restored copy is
another pool. Run **DW | 9 → pause-all** whenever you stop, and delete the resource group at the
end. Paused pools only cost storage.

---

## 0. Pick names

| Thing | Example | Note |
|---|---|---|
| Subscription | `<SUB_ID>` | a test/dev subscription |
| Resource group | `rg-dwrestore-test` | must **not** contain `prd`/`prod` |
| SQL server | `sql-dwrestore-test-<yourinitials>` | globally unique, lowercase, no `prd`/`prod` |
| Location | `centralindia` | |
| Repo | `<you>/<repo>` | where you push this code |

## 1. Bootstrap the test admin identity (Cloud Shell, once)

This identity is used only by **DW | 0** (creates the restore SPNs) and **DW | 9** (test harness).

```bash
SUB=<SUB_ID>; RG=rg-dwrestore-test; LOC=centralindia; REPO=<you>/<repo>
az account set -s $SUB
az group create -n $RG -l $LOC

APP=$(az ad app create --display-name gha-dwrestore-test-admin --query appId -o tsv)
az ad sp create --id $APP
OBJ=$(az ad app show --id $APP --query id -o tsv)

for ENV in azure-admin test-harness; do
  az ad app federated-credential create --id $OBJ --parameters "{
    \"name\": \"gha-$ENV\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:$REPO:environment:$ENV\",
    \"audiences\": [\"api://AzureADTokenExchange\"] }"
done

# Azure rights (TEST ONLY): build/pause pools in the RG; create custom roles + assignments
az role assignment create --assignee $APP --role Contributor --scope /subscriptions/$SUB/resourceGroups/$RG
az role assignment create --assignee $APP --role "User Access Administrator" --scope /subscriptions/$SUB

# Entra right: create app registrations it owns (Graph Application.ReadWrite.OwnedBy)
az ad app permission add --id $APP --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions 18a4783c-866b-4cc7-a460-3d5e5662c884=Role
az ad app permission admin-consent --id $APP      # needs a tenant admin

echo "Client ID: $APP"
echo "Tenant ID: $(az account show --query tenantId -o tsv)"
```

No tenant admin to consent? Skip that line and use step 4b.

## 2. GitHub setup

Push everything (`.github/`, `scripts/`, `infra/`) to the default branch.

**Settings → Environments**

| Environment | Required reviewers | Add |
|---|---|---|
| `azure-admin` | you | variable `AZURE_ADMIN_CLIENT_ID` = client ID |
| `test-harness` | none | variable `AZURE_TEST_ADMIN_CLIENT_ID` = client ID; **secret** `TEST_SQL_ADMIN_PASSWORD` (strong, 12+ chars) |
| `dw-restore` | you (practise approving) | step 4 fills it |
| `dw-restore-read` | none | step 4 fills it |

**Settings → Secrets and variables → Actions → Variables** (repository)

| Variable | Value |
|---|---|
| `AZURE_TENANT_ID` | tenant ID |
| `AZURE_SUBSCRIPTION_ID` | `<SUB_ID>` |
| `DW_RESOURCE_GROUP` | `rg-dwrestore-test` |
| `DW_SERVER_NAME` | `sql-dwrestore-test-<yourinitials>` |
| `DW_SOURCE_DATABASES` | `ifrs17_dw_prd` |
| `TEST_LOCATION` | `centralindia` |

## 3. Create the test DW + first transactions

Actions → **DW | 9. TEST - Sample DW, Transactions & Verify** → `create-and-load` (DW100c).

It takes about 10-15 minutes and creates:
- the SQL server and dedicated pool `ifrs17_dw_prd`
- `dbo.DimProduct` (200 rows), `dbo.FactSales` (100,000 rows) and `dbo.RestoreTestLog`
- **batch A** in one transaction: +100 log rows, +1,000 sales, +1 on 10 prices

The summary shows a state table and an **Expected** line (log rows, price total, sales rows and
amount). Keep it handy.

## 4. Create the restore SPNs

**4a.** **DW | 0. One-time Setup - Restore SPNs (Admin)** → approve. Copy the two client IDs from
the summary into `AZURE_RESTORE_CLIENT_ID` (environment `dw-restore`) and
`AZURE_READER_CLIENT_ID` (environment `dw-restore-read`).

**4b.** Or run the same script as yourself in Cloud Shell (PowerShell):
```powershell
git clone https://github.com/<you>/<repo>; cd <repo>
foreach ($a in 'operator','reader') {
  $envName = if ($a -eq 'operator') { 'dw-restore' } else { 'dw-restore-read' }
  ./scripts/Provision-RestoreSpn.ps1 -DisplayName "spn-gha-dw-restore-$a" -Access $a `
    -GitHubRepository '<you>/<repo>' -GitHubEnvironment $envName -SubscriptionId '<SUB_ID>' `
    -ResourceGroupName rg-dwrestore-test -ServerName sql-dwrestore-test-<yourinitials>
}
```

## 5. Take a backup and restore it

**DW | 2. Restore Backup to New Database** → approve:

| Input | Value |
|---|---|
| `restore_point` | `new` |
| `target_database_name` | `ifrs17_dw_prd_dc_test1` |
| `service_objective` | `same-as-source` |
| `new_backup_label` | `after-batch-A` |

It creates restore point `after-batch-A` (the backup), then restores it into
`ifrs17_dw_prd_dc_test1`. The summary shows the restore point ID, e.g.
`ifrs17_dw_prd@2026-11-17T09:12:40Z`.

## 6. Verify the copy

**DW | 9** → `verify`, `verify_database_name` = `ifrs17_dw_prd_dc_test1`.
The restored row must equal the **Expected** line from step 3.

## 7. Recovery drill: bad change → restore the earlier backup

1. **DW | 9** → `add-transactions`, `simulate_bad_change` ✔. It adds batch B, then deletes half
   the sales and zeroes every price in the source.
2. **DW | 1. List Available Backups** → you'll see `after-batch-A` (Kind *User*) with its
   **Restore point ID**, plus any automatic snapshots.
3. **DW | 2** → `restore_point` = that ID, target `ifrs17_dw_prd_dc_test2`.
4. **DW | 9** → `verify` with `ifrs17_dw_prd_dc_test2`. You should see batch **A only**, prices
   intact and 101,000 sales, while the source row shows the damage.

## 8. Try the guardrails

Each of these should fail **before** anything is created:

| Try | Expected message |
|---|---|
| target `ifrs17_dw_prd_dc_test1` again | already exists |
| target `mycopy` | must start with `ifrs17_dw_prd_dc_` |
| `restore_point` = `ifrs17_dw_prd@2020-01-01T00:00:00Z` | not available |
| `restore_point` = `hello` | cannot read restore point |
| a DB not in `DW_SOURCE_DATABASES` | not an allowed source |

## 9. Pause and clean up

- Done for the day: **DW | 9 → pause-all** (pauses source and copies). To continue later:
  **DW | 9 → resume** with `database_name` set to each pool you need.
- Finished: the pipelines can't delete anything by design, so do it yourself:
  ```bash
  az group delete -n rg-dwrestore-test --yes
  az ad app delete --id <test admin client ID>
  az ad app delete --id <restore operator client ID>
  az ad app delete --id <restore reader client ID>
  ```
  The custom roles stay at subscription level and are harmless. To remove them, run
  `az role definition delete --name "<role name>"`.

## Going to production later

Point the variables at the real RG/server, use the least-privilege admin identity from the
README (no Contributor or User Access Administrator), and don't create the `test-harness`
environment there. The harness also refuses RG/server names containing `prd`/`prod`.

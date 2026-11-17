# DW backup list & restore pipelines (non-destructive)

Two GitHub Actions pipelines that replace the manual `DBRESTORE.txt` runbook for
`ifrs17_dw_prd` / `ifrs17_dw_prd_plai` on `sdb-sgrass-prd-az1-sql002`.

| Pipeline | What it does | Identity | Approval |
|---|---|---|---|
| **DW \| 1. List Available Backups** | Shows every available restore point with a copy-paste ID, plus CSV/JSON download | read-only SPN | none |
| **DW \| 2. Restore Backup to New Database** | Takes that ID and a new DB name, and creates the new database | restore SPN | required reviewer |
| **DW \| 0. One-time Setup - Restore SPNs (Admin)** | One-time admin setup of both SPNs | admin identity | required reviewer |

## How to use

**Step 1 - Actions → "DW | 1. List Available Backups" → Run** (choose `all` or one DW). The run summary shows:

| # | Restore point ID (copy this) | Taken (IST) | Kind | Label | Available until (IST, approx.) |
|---|---|---|---|---|---|
| 1 | `ifrs17_dw_prd@2025-11-17T05:33:42Z` | 17-Nov-2025 11:03 | Auto | | 24-Nov-2025 11:03 (165h left) |
| 2 | `ifrs17_dw_prd@2025-11-16T21:33:42Z` | 17-Nov-2025 03:03 | User | before-close | 24-Nov-2025 03:03 (157h left) |

`Auto` = Azure's automatic snapshot (about every 8 h). `User` = a backup someone took, with its
label. Both are kept for about 7 days.

**Step 2 - Actions → "DW | 2. Restore Backup to New Database" → Run**

| Input | Notes |
|---|---|
| `restore_point` | **Required.** Paste an ID from step 1, e.g. `ifrs17_dw_prd@2025-11-17T05:33:42Z`. Or `latest`, or `new` to take a fresh backup first and restore that. |
| `target_database_name` | **Required.** E.g. `ifrs17_dw_prd_dc_17_11_25`. Must start with `<source>_dc_`, differ from the source and not exist. Checked before anything runs and again just before the restore. |
| `source_database` | Only used with `latest` / `new`. An ID already names its database. |
| `service_objective` | Default `same-as-source` (the source's DWU), or pick a DWU. |
| `new_backup_label` | Only with `new`. |

A reviewer approves, then the summary shows the restore point used, the new database and how long
it took. If the ID has expired since the list was run, the restore fails up front and nothing is
created.

## 6-hour timeout

- Taking a backup (`new`) and the restore each wait up to **360 min** (`DW_OP_TIMEOUT_MINUTES`),
  logging progress every minute.
- The Azure sign-in is renewed every 30 min from GitHub OIDC, so long restores don't fail when the
  1-hour token expires.
- GitHub-hosted runners stop any job at 6 h *in total*. For the full 6 h wait, set `DW_RUNNER`
  to a self-hosted runner label (job timeout defaults to 390 min via `DW_JOB_TIMEOUT_MINUTES`).
- On timeout the job fails with a clear summary. Azure keeps going, and nothing is cancelled.

## Why it is non-destructive

| Layer | Control |
|---|---|
| Credentials | No secrets or certificates. Each SPN trusts exactly one GitHub environment in this repo (OIDC). |
| Read-only SPN | Read DBs and restore points only, on the one server. |
| Restore SPN | Custom role, 7 actions: read server/DBs, create DB, read/create restore points, poll operations. **No** delete, pause, resume, export, firewall, AAD admin or `Microsoft.Authorization/*`. Scoped to the one SQL server (plus read-only operation status at subscription). |
| Pipeline | Target name is typed by the operator and must be new. Source DBs are allow-listed. No delete/drop anywhere. |
| Process | Required reviewers on `dw-restore` and `azure-admin`. One run per target name at a time. |
| Self-check | Provisioning fails if an SPN has any extra role assignment or any secret. |

**Known limit:** Azure RBAC can't split "create database" from "update database"
(`databases/write`). The pipeline blocks updates to existing DBs, but the restore SPN could still
change an existing DB's settings outside the pipeline. It can't delete or pause one. As
belt-and-braces, lock the production DBs:

```powershell
New-AzResourceLock -LockName nodelete -LockLevel CanNotDelete -ResourceGroupName rsg-sgrass-prd-az1-xd6ggb `
  -ResourceName "sdb-sgrass-prd-az1-sql002/ifrs17_dw_prd" -ResourceType Microsoft.Sql/servers/databases
```

## One-time setup

1. **Custom roles** (subscription Owner). The provision script creates them if the admin identity
   is allowed to. Otherwise:
   ```bash
   for f in infra/*.json; do
     sed "s/__SUBSCRIPTION_ID__/<sub-id>/" "$f" > /tmp/role.json
     az role definition create --role-definition /tmp/role.json
   done
   ```
2. **Admin identity** for the provision workflow (OIDC subject
   `repo:<org/repo>:environment:azure-admin`): Entra *Application Developer*, plus *Role Based
   Access Control Administrator* on the subscription with a condition that only allows assigning
   the three custom roles.
3. **GitHub environments**
   - `azure-admin`: reviewers = platform/IAM. Variable `AZURE_ADMIN_CLIENT_ID`.
   - `dw-restore`: reviewers = DBA lead. Deployment branch: default branch only.
   - `dw-restore-read`: no reviewers. Deployment branch: default branch only.
4. **Repository variables:** `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`,
   `DW_RESOURCE_GROUP=rsg-sgrass-prd-az1-xd6ggb`, `DW_SERVER_NAME=sdb-sgrass-prd-az1-sql002`.
   Optional: `DW_SOURCE_DATABASES` (allow-list, default both), `DW_RUNNER`,
   `DW_JOB_TIMEOUT_MINUTES` (390), `DW_OP_TIMEOUT_MINUTES` (360).
5. Optional secret `GH_ADMIN_TOKEN` (fine-grained PAT, *Environments* write). With it, provisioning
   sets `AZURE_RESTORE_CLIENT_ID` and `AZURE_READER_CLIENT_ID` itself. Otherwise, copy them from
   the provisioning summary.
6. Run **DW | 0. One-time Setup - Restore SPNs (Admin)** once.

## Files

```
.github/workflows/dw-0-setup-restore-spns.yml              one-time SPN setup (admin)
.github/workflows/dw-1-list-available-backups.yml          pipeline 1
.github/workflows/dw-2-restore-backup-to-new-database.yml  pipeline 2
.github/workflows/dw-9-test-sample-db.yml                  TEST ONLY: sample DW, transactions, verify, pause
scripts/Get-DwBackups.ps1                    list logic
scripts/Invoke-DwRestore.ps1                 restore logic (guards, 6 h waits)
scripts/DwCommon.psm1                        login renewal, polling, time zones, IDs
scripts/Provision-RestoreSpn.ps1             secretless SPN + roles + self-check
scripts/test/Invoke-TestHarness.ps1          test harness logic (refuses prd/prod names)
TESTING.md                                   step-by-step test on your own GitHub + Azure
infra/*.json                                 the three custom roles
```

Restored pools keep billing while Online. By design, neither pipeline can pause or drop them.
=======
# synapse-db-dw
synapse-db
>>>>>>> e25c9014309c94bda4da882013528dfa3a838192

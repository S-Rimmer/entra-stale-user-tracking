# Microsoft Entra Stale User Tracking

Daily, report-only monitoring of Microsoft Entra ID member accounts that have **not signed in successfully within a configurable window** (default 30 days). Results land in a Log Analytics table with an Azure Monitor workbook and alerts.

> **Safe by default.** Phase 1 is read-only: the managed identity receives only `User.Read.All`, `AuditLog.Read.All`, and `GroupMember.Read.All`. Nothing is notified or disabled. Notification (Phase 2) and enforcement (Phase 3) require separate approval and additional permissions that this deployment does not grant.

## Deploy

Deployment has two steps because the Azure portal cannot create Microsoft Entra objects or grant Microsoft Graph permissions.

### Step 1: Azure resources (Owner, or Contributor plus User Access Administrator, on the resource group)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FS-Rimmer%2Fentra-stale-user-tracking%2Fmain%2Fazuredeploy.json)

Or with the Azure CLI:

```bash
az group create -n rg-stale-user-tracking -l eastus
az deployment group create -g rg-stale-user-tracking --template-file infra/main.bicep -p alertEmail=secops@contoso.com
```

### Step 2: Entra groups and read-only Graph permissions (Privileged Role Administrator or Global Administrator)

Run in [Azure Cloud Shell](https://shell.azure.com) (Bash) or any shell with Azure CLI 2.70+:

```bash
git clone https://github.com/S-Rimmer/entra-stale-user-tracking.git
cd entra-stale-user-tracking
az deployment group create -g rg-stale-user-tracking \
  --template-file infra/identity.bicep \
  -p automationAccountName=aa-stale-user \
     exclusionMemberObjectIds='["<break-glass-account-object-id>"]'
```

`identity.bicep` uses the [Microsoft Graph Bicep extension](https://learn.microsoft.com/graph/templates/bicep/overview-bicep-templates-for-graph) to:

1. Create `StaleUser-Exclusions`, `StaleUser-ManualReview`, `StaleUser-Pilot`, and `StaleUser-ReportRecipients` security groups. Group membership uses append semantics, so redeploying never removes members you added.
2. Grant the Automation managed identity the three read-only Graph application permissions.
3. Store the group object IDs in Automation variables.
4. Link the daily schedule to the runbook in report-only mode.

PowerShell alternative: `./scripts/Initialize-Identity.ps1 -ResourceGroup rg-stale-user-tracking -ExclusionMemberUpns breakglass@contoso.com`

### Step 3: Verify

Wait about 10 minutes for the new Graph permissions to reach the managed identity, then:

```powershell
./scripts/Test-Deployment.ps1 -ResourceGroup rg-stale-user-tracking
```

Open **Azure Monitor > Workbooks > Entra Stale User Tracking**. The `missing-daily-run` alert fires until the first run completes; that is expected.

## Architecture

```text
Azure Automation (PowerShell 7.4 runtime, system-assigned managed identity)
  └─ StaleUser-Monitor runbook, daily, ReportOnly=true
       ├─ Microsoft Graph (read-only): users + signInActivity, StaleUser-* group members
       └─ Logs Ingestion API ─> Data collection rule ─> EntraStaleUser_CL (Log Analytics)
                                                          ├─ Azure Monitor workbook
                                                          └─ Alert rules (+ optional email action group)
```

| Resource | Name |
|---|---|
| Log Analytics workspace and custom table | `law-<prefix>`, `EntraStaleUser_CL` |
| Data collection rule (kind Direct) | `dcr-<prefix>` |
| Automation account, runtime environment, runbook, schedule | `aa-<prefix>`, `PowerShell-74`, `StaleUser-Monitor`, `StaleUser-Daily` |
| Role assignment | Managed identity: **Monitoring Metrics Publisher** on the DCR |
| Workbook | `Entra Stale User Tracking` |
| Alerts | `<prefix>-missing-daily-run`, `-run-failed`, `-control-defect`, `-automation-job-failed` |

The runbook calls REST APIs with managed-identity tokens; no Microsoft Graph or Az PowerShell modules are required.

## Requirements

- Microsoft Entra ID **P1 or P2** (required to read `signInActivity`).
- Azure subscription, commercial cloud.
- Step 1 deployer: Owner, or Contributor plus User Access Administrator, on the target resource group.
- Step 2 deployer: Privileged Role Administrator or Global Administrator, plus Contributor on the Automation account.

## How users are classified

Gates are evaluated in this order. The first match wins.

| Gate | Disposition / Reason |
|---|---|
| Account disabled | `Skipped / AlreadyDisabled` |
| `userType` is not Member | `Skipped / OutOfScopeUserType` |
| Member of `StaleUser-Exclusions` (including nested groups) | `Skipped / ApprovedExclusion` |
| Member of `StaleUser-ManualReview` | `ManualReview / ManualReviewGroup` |
| `onPremisesSyncEnabled = true` | `ManualReview / SynchronizedIdentity` |
| `employeeType` is ServiceAccount, SharedAccount, or EmergencyAccess | `Skipped / AccountClassification` |
| No `lastSuccessfulSignInDateTime` | `ManualReview / NullLastSuccessfulSignIn` |
| Last successful sign-in at or before the cutoff | `CandidateReportOnly / InactiveThresholdReached` |
| 25-29 / 20-24 / 15-19 days | `ReviewTicket` / `NotifyUserAndManager` / `NotifyUser` (labels only in Phase 1) |
| Otherwise | `WithinPolicy` |

Notes:

- `lastSuccessfulSignInDateTime` became available on December 1, 2023 and is not backfilled; it can take up to 24 hours to update.
- Hybrid users are routed to manual review because cloud sign-in activity alone does not reflect on-premises activity.
- Any failure to read a control group or the user list fails the run (fail closed) and records `RunFailed`.

## Phase 2 and Phase 3

The runbook contains a Phase 3 enforcement skeleton (final revalidation, maximum-disable count, disable, revoke sessions, verify) that is **off by default** and covered only by mocked tests. It needs `User.EnableDisableAccount.All` and `User.RevokeSessions.All`, which this repository never grants. Treat enabling it as a separate project with its own security review, pilot, and rollback plan.

## Repository layout

| Path | Purpose |
|---|---|
| `azuredeploy.json` | Compiled from `infra/main.bicep`; used by the Deploy to Azure button. |
| `infra/main.bicep` | Step 1 Azure resources. |
| `infra/identity.bicep`, `infra/bicepconfig.json` | Step 2 Entra groups, Graph permissions, variables, schedule link. |
| `infra/workbook.json` | Workbook definition (generated by `scripts/dev/Build-Workbook.ps1`). |
| `src/StaleUser-Monitor.ps1` | Runbook. Also runs locally: `-AuthMode AzureCli`. |
| `tests/StaleUser-Monitor.Tests.ps1` | 51 Pester tests with mocked Graph and ingestion. |
| `scripts/` | PowerShell identity alternative, smoke test, and removal. |
| `.github/workflows/` | CI (Pester and template drift check) and an optional OIDC deployment workflow. |

## Development

```powershell
Invoke-Pester ./tests                                                   # unit tests
./scripts/dev/Build-Workbook.ps1                                        # after changing workbook queries
az bicep build --file infra/main.bicep --outfile azuredeploy.json       # after changing main.bicep
```

Forks: change `runbookContentUri` in `infra/main.bicep` and the button URL in this README to point at your repository, or pin both to a release tag.

## Remove

```powershell
./scripts/Remove-Deployment.ps1 -ResourceGroup rg-stale-user-tracking -RemoveGroups
```

## Disclaimer

This is a sample solution provided as-is, without warranty, and is not an official Microsoft product. Review the code, permissions, and data handling against your organization's policies before deploying to production.

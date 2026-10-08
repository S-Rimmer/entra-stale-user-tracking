<#
.SYNOPSIS
    Post-deployment smoke test: starts one report-only runbook job, waits for completion,
    and confirms evidence arrived in EntraStaleUser_CL.

.NOTES
    Run after step 2 (identity). Allow about 10 minutes after granting Graph permissions for
    the managed identity token to pick up the new roles. First ingestion can take 5-15 minutes.
#>
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$AutomationAccountName,
    [int]$IngestionWaitMinutes = 20
)
$ErrorActionPreference = 'Stop'
$sub = az account show --query id -o tsv
$ah = @{ Authorization = "Bearer $(az account get-access-token --query accessToken -o tsv)" }
if (-not $AutomationAccountName) {
    $AutomationAccountName = az resource list -g $ResourceGroup --resource-type Microsoft.Automation/automationAccounts --query '[0].name' -o tsv
}
$aaPath = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName"

$jobId = [guid]::NewGuid().ToString()
$body = @{ properties = @{ runbook = @{ name = 'StaleUser-Monitor' }; parameters = @{ ReportOnly = 'true'; PilotMode = 'true'; AuthMode = 'ManagedIdentity' } } } | ConvertTo-Json -Depth 5
Invoke-RestMethod -Method PUT -Uri "$aaPath/jobs/$jobId`?api-version=2024-10-23" -Headers $ah -ContentType 'application/json' -Body $body | Out-Null
Write-Host "Started job $jobId"
do {
    Start-Sleep -Seconds 15
    $job = Invoke-RestMethod -Uri "$aaPath/jobs/$jobId`?api-version=2024-10-23" -Headers $ah
    Write-Host "  $(Get-Date -Format HH:mm:ss) $($job.properties.status)"
} while ($job.properties.status -notin 'Completed', 'Failed', 'Stopped', 'Suspended')

$output = Invoke-RestMethod -Uri "$aaPath/jobs/$jobId/output?api-version=2024-10-23" -Headers $ah
Write-Host "Job output: $output"
if ($job.properties.status -ne 'Completed') { throw "Job ended with status $($job.properties.status): $($job.properties.exception)" }

$workspaceId = az resource list -g $ResourceGroup --resource-type Microsoft.OperationalInsights/workspaces --query '[0].id' -o tsv
$customerId = az monitor log-analytics workspace show --ids $workspaceId --query customerId -o tsv 2>$null
$lh = @{ Authorization = "Bearer $(az account get-access-token --resource https://api.loganalytics.io --query accessToken -o tsv)" }
$runId = ([regex]::Match("$output", 'RunId=([0-9a-f-]+)')).Groups[1].Value
$query = "EntraStaleUser_CL | where RunId == '$runId' | summarize Records=count() by RecordType"
$deadline = (Get-Date).AddMinutes($IngestionWaitMinutes)
do {
    $r = Invoke-RestMethod -Method POST -Uri "https://api.loganalytics.io/v1/workspaces/$customerId/query" -Headers $lh -ContentType 'application/json' -Body (@{ query = $query; timespan = 'P1D' } | ConvertTo-Json)
    $rows = $r.tables[0].rows
    if ($rows.Count -gt 0) { break }
    Write-Host '  Waiting for ingestion...'; Start-Sleep -Seconds 30
} while ((Get-Date) -lt $deadline)
if ($rows.Count -eq 0) { throw "No evidence for RunId $runId after $IngestionWaitMinutes minutes." }
$rows | ForEach-Object { [pscustomobject]@{ RecordType = $_[0]; Records = $_[1] } } | Format-Table -AutoSize
Write-Host "Smoke test passed for RunId $runId." -ForegroundColor Green

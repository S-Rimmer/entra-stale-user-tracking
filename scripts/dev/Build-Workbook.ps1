<#
.SYNOPSIS
    Maintainer script: regenerates infra/workbook.json (Azure Monitor Workbook definition).
    The template replaces __WORKSPACE_ID__ with the deployed Log Analytics workspace resource ID.
#>
$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot '..\..\infra\workbook.json'
$ws = '__WORKSPACE_ID__'

# Evaluation records only, latest per user, honouring the Engine and Mode parameters.
$latest = @'
let Latest = EntraStaleUser_CL
| where TimeGenerated {TimeRange}
| where RecordType == 'Evaluation'
| where '{Engine}' == 'All' or Engine == '{Engine}'
| where '{Mode}' == 'All' or Mode == '{Mode}'
| summarize arg_max(TimeGenerated, *) by UserId;
'@
$filtered = @'
EntraStaleUser_CL
| where TimeGenerated {TimeRange}
| where '{Engine}' == 'All' or Engine == '{Engine}'
| where '{Mode}' == 'All' or Mode == '{Mode}'
'@

$panels = @(
    @{ title = 'Current status'; viz = 'tiles'; query = $latest + @'
union
  (Latest | summarize Value=count() | extend Metric='Evaluated users', Order=1),
  (Latest | where Disposition in ('CandidateReportOnly','PendingSafetyBuffer','DisableCandidate') | summarize Value=count() | extend Metric='Inactive 30+ days', Order=2),
  (Latest | where Disposition in ('NotifyUser','NotifyUserAndManager','ReviewTicket') | summarize Value=count() | extend Metric='Approaching (15-29 days)', Order=3),
  (Latest | where Disposition == 'ManualReview' | summarize Value=count() | extend Metric='Manual review', Order=4),
  (Latest | where Excluded == true | summarize Value=count() | extend Metric='Approved exclusions', Order=5),
  (Latest | where ActionStatus in ('Failed','Blocked','PartialSuccess') or Disposition in ('Failed','BlockedRemediation') | summarize Value=count() | extend Metric='Failures or blocked', Order=6)
| order by Order asc | project Metric, Value
'@ }
    @{ title = 'Inactive 30+ days (threshold reached)'; viz = 'table'; query = $latest + @'
Latest
| where Disposition in ('CandidateReportOnly','PendingSafetyBuffer','DisableCandidate')
| project UserPrincipalName, DisplayName, EmployeeType, LastSuccessfulSignInDateTime, DaysInactive, Disposition, Reason, PilotMember
| order by DaysInactive desc
'@ }
    @{ title = 'Inactivity bands'; viz = 'barchart'; query = $latest + @'
Latest
| extend Band = case(isnull(DaysInactive) or DaysInactive < 0, 'Unknown', DaysInactive < 15, '0-14', DaysInactive < 20, '15-19',
                     DaysInactive < 25, '20-24', DaysInactive < 30, '25-29', '30+')
| summarize Users=count() by Band
| extend SortOrder=case(Band=='0-14',1,Band=='15-19',2,Band=='20-24',3,Band=='25-29',4,Band=='30+',5,6)
| order by SortOrder asc | project Band, Users
'@ }
    @{ title = 'Disposition summary'; viz = 'piechart'; query = $latest + "Latest | summarize Users=count() by Disposition | order by Users desc" }
    @{ title = 'Daily trend'; viz = 'timechart'; query = $filtered + @'
| where RecordType == 'Evaluation'
| summarize Inactive30Plus=dcountif(UserId, Disposition in ('CandidateReportOnly','PendingSafetyBuffer','DisableCandidate')),
            Approaching=dcountif(UserId, Disposition in ('NotifyUser','NotifyUserAndManager','ReviewTicket')),
            ManualReview=dcountif(UserId, ManualReview == true), Exclusions=dcountif(UserId, Excluded == true)
  by bin(TimeGenerated, 1d)
'@ }
    @{ title = 'Exceptions and manual review'; viz = 'table'; query = $latest + @'
Latest | where Excluded == true or ManualReview == true
| project UserPrincipalName, DisplayName, EmployeeType, DaysInactive, Excluded, ManualReview, Reason, Details, TimeGenerated
| order by ManualReview desc, DaysInactive desc
'@ }
    @{ title = 'Run health'; viz = 'table'; query = $filtered + @'
| summarize Evaluated=dcountif(UserId, RecordType == 'Evaluation'),
            RunStarted=countif(RecordType == 'RunStarted'), RunCompleted=countif(RecordType == 'RunCompleted'),
            RunFailed=countif(RecordType == 'RunFailed'), Blocked=countif(RecordType == 'Blocked'),
            FirstRecord=min(TimeGenerated), LastRecord=max(TimeGenerated), Error=take_anyif(ErrorDetails, RecordType == 'RunFailed')
  by RunId, Engine, Mode
| extend Complete = RunStarted == 1 and RunCompleted == 1 and RunFailed == 0
| order by LastRecord desc
'@ }
    @{ title = 'Data quality (non-zero safety rows must be investigated)'; viz = 'table'; query = $latest + @'
union
  (Latest | where isempty(UserId) | summarize Value=count() | extend Check='Missing UserId'),
  (Latest | where isempty(UserPrincipalName) | summarize Value=count() | extend Check='Missing UPN'),
  (Latest | where isnull(LastSuccessfulSignInDateTime) and Disposition != 'Skipped' | summarize Value=count() | extend Check='Null successful sign-in (in scope)'),
  (Latest | where DaysInactive < -1 | summarize Value=count() | extend Check='Invalid DaysInactive'),
  (Latest | where Excluded == true and Disposition in ('DisableCandidate','CandidateReportOnly') | summarize Value=count() | extend Check='SAFETY: Excluded but candidate'),
  (Latest | where ManualReview == true and Disposition in ('DisableCandidate','CandidateReportOnly') | summarize Value=count() | extend Check='SAFETY: Manual review but candidate')
| project Check, Value
'@ }
)

$items = [System.Collections.Generic.List[object]]::new()
$items.Add([ordered]@{ type = 1; name = 'header'; content = @{ json = "## Microsoft Entra Stale User Tracking`nPhase 1 monitor-and-report evidence from ``EntraStaleUser_CL``. Threshold: no successful sign-in (``signInActivity.lastSuccessfulSignInDateTime``) within the configured inactivity window. This workbook does not notify or disable accounts." } })
$items.Add([ordered]@{
        type = 9; name = 'parameters'
        content = [ordered]@{
            version = 'KqlParameterItem/1.0'; style = 'pills'; queryType = 0; resourceType = 'microsoft.operationalinsights/workspaces'
            parameters = @(
                [ordered]@{ id = '6a3b7f0e-1d52-4b8f-9a61-3c2f6e1d0a01'; version = 'KqlParameterItem/1.0'; name = 'TimeRange'; type = 4; isRequired = $true; value = @{ durationMs = 604800000 }
                    typeSettings = @{ selectableValues = @(@{ durationMs = 86400000 }, @{ durationMs = 604800000 }, @{ durationMs = 2592000000 }, @{ durationMs = 7776000000 }) } }
                [ordered]@{ id = '6a3b7f0e-1d52-4b8f-9a61-3c2f6e1d0a02'; version = 'KqlParameterItem/1.0'; name = 'Engine'; type = 2; isRequired = $true; value = 'All'
                    jsonData = '["All","AzureAutomation","LogicApps","LocalAzureCli"]'; typeSettings = @{ showDefault = $false } }
                [ordered]@{ id = '6a3b7f0e-1d52-4b8f-9a61-3c2f6e1d0a03'; version = 'KqlParameterItem/1.0'; name = 'Mode'; type = 2; isRequired = $true; value = 'All'
                    jsonData = '["All","ReportOnly","NotificationPilot","DisablePilot","Production"]'; typeSettings = @{ showDefault = $false } }
            )
        }
    })
$i = 0
foreach ($p in $panels) {
    $i++
    $content = [ordered]@{
        version = 'KqlItem/1.0'; query = $p.query; size = 0; title = $p.title; queryType = 0
        resourceType = 'microsoft.operationalinsights/workspaces'; crossComponentResources = @($ws); visualization = $p.viz
    }
    if ($p.viz -eq 'tiles') {
        $content.size = 4
        $content.tileSettings = @{ titleContent = @{ columnMatch = 'Metric' }; leftContent = @{ columnMatch = 'Value'; formatter = 12 }; showBorder = $true }
    }
    $items.Add([ordered]@{ type = 3; name = "panel$i"; content = $content })
}
[ordered]@{ version = 'Notebook/1.0'; items = $items; fallbackResourceIds = @($ws) } | ConvertTo-Json -Depth 30 | Set-Content -Path $out -Encoding utf8
Write-Host "Wrote $out"

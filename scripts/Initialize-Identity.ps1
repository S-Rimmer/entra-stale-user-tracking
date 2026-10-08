<#
.SYNOPSIS
    PowerShell alternative to infra/identity.bicep (step 2). Idempotent.

.DESCRIPTION
    Run as an Entra admin (Privileged Role Administrator or Global Administrator) after the Azure
    resources are deployed. Uses the Azure CLI session (az login / Cloud Shell) for tokens.
    1. Creates the StaleUser-* security groups.
    2. Grants read-only Microsoft Graph application permissions to the Automation managed identity:
       User.Read.All, AuditLog.Read.All, GroupMember.Read.All. No write permissions are granted.
    3. Stores the group object IDs in Automation variables.
    4. Links the daily schedule to the runbook in report-only mode.
#>
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$AutomationAccountName,
    [string]$GroupNamePrefix = 'StaleUser',
    [string[]]$ExclusionMemberUpns = @(),
    [ValidateRange(1, 365)][int]$InactivityDays = 30,
    [switch]$SkipScheduleLink
)
$ErrorActionPreference = 'Stop'
$graph = 'https://graph.microsoft.com'
$arm = 'https://management.azure.com'

function Get-Token([string]$Resource) {
    $t = az account get-access-token --resource $Resource --query accessToken -o tsv
    if (-not $t) { throw 'Run az login first.' }
    $t
}
$gh = @{ Authorization = "Bearer $(Get-Token $graph)" }
$ah = @{ Authorization = "Bearer $(Get-Token $arm)" }
function Invoke-Graph([string]$Method = 'GET', [string]$Path, [object]$Body) {
    $p = @{ Method = $Method; Uri = "$graph$Path"; Headers = $gh; ContentType = 'application/json' }
    if ($null -ne $Body) { $p.Body = $Body | ConvertTo-Json -Depth 10 }
    Invoke-RestMethod @p
}
function Invoke-Arm([string]$Method, [string]$Path, [object]$Body) {
    $p = @{ Method = $Method; Uri = "$arm$Path"; Headers = $ah; ContentType = 'application/json' }
    if ($null -ne $Body) { $p.Body = $Body | ConvertTo-Json -Depth 10 }
    Invoke-RestMethod @p
}

$sub = az account show --query id -o tsv
if (-not $AutomationAccountName) {
    $AutomationAccountName = az resource list -g $ResourceGroup --resource-type Microsoft.Automation/automationAccounts --query '[0].name' -o tsv
    if (-not $AutomationAccountName) { throw "No Automation account found in $ResourceGroup." }
}
$aaPath = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName"
$aa = Invoke-Arm GET "$aaPath`?api-version=2024-10-23"
$miId = $aa.identity.principalId
if (-not $miId) { throw 'The Automation account has no system-assigned managed identity.' }
Write-Host "Automation account: $AutomationAccountName (managed identity $miId)"

function Set-Group([string]$Suffix, [string]$Description) {
    $name = "$GroupNamePrefix-$Suffix"
    $f = [uri]::EscapeDataString("displayName eq '$name'")
    $existing = @((Invoke-Graph -Path "/v1.0/groups?`$filter=$f&`$select=id").value)
    if ($existing.Count -gt 1) { throw "Multiple groups named $name exist; resolve manually." }
    if ($existing.Count -eq 1) { Write-Host "Group exists: $name"; return $existing[0].id }
    $g = Invoke-Graph -Method POST -Path '/v1.0/groups' -Body @{
        displayName = $name; description = $Description; mailEnabled = $false; mailNickname = ($name -replace '[^A-Za-z0-9]', ''); securityEnabled = $true
    }
    Write-Host "Created group: $name"; $g.id
}
$groups = [ordered]@{
    Exclusion    = Set-Group 'Exclusions' 'Approved exceptions. Membership blocks stale-user automation.'
    ManualReview = Set-Group 'ManualReview' 'Accounts requiring human disposition. Never auto-disabled.'
    Pilot        = Set-Group 'Pilot' 'Accounts approved for a controlled Phase 3 pilot.'
    Reports      = Set-Group 'ReportRecipients' 'Recipients of summarized stale-user reports. No effect on eligibility.'
}

foreach ($upn in $ExclusionMemberUpns) {
    $u = Invoke-Graph -Path "/v1.0/users/$([uri]::EscapeDataString($upn))?`$select=id"
    $members = @((Invoke-Graph -Path "/v1.0/groups/$($groups.Exclusion)/members?`$select=id").value.id)
    if ($members -notcontains $u.id) {
        Invoke-Graph -Method POST -Path "/v1.0/groups/$($groups.Exclusion)/members/`$ref" -Body @{ '@odata.id' = "$graph/v1.0/directoryObjects/$($u.id)" } | Out-Null
    }
    Write-Host "Exclusion member: $upn"
}

$graphSp = @((Invoke-Graph -Path "/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appRoles").value)
if ($graphSp.Count -ne 1) { throw 'Expected exactly one Microsoft Graph service principal.' }
$assigned = @((Invoke-Graph -Path "/v1.0/servicePrincipals/$miId/appRoleAssignments").value.appRoleId)
foreach ($roleName in 'User.Read.All', 'AuditLog.Read.All', 'GroupMember.Read.All') {
    $role = @($graphSp[0].appRoles | Where-Object { $_.value -eq $roleName -and $_.allowedMemberTypes -contains 'Application' })
    if ($role.Count -ne 1) { throw "Expected exactly one Graph app role for $roleName." }
    if ($assigned -contains $role[0].id) { Write-Host "Already granted: $roleName"; continue }
    Invoke-Graph -Method POST -Path "/v1.0/servicePrincipals/$miId/appRoleAssignments" -Body @{ principalId = $miId; resourceId = $graphSp[0].id; appRoleId = $role[0].id } | Out-Null
    Write-Host "Granted: $roleName"
}

$vars = @{ 'StaleUser-ExclusionGroupId' = $groups.Exclusion; 'StaleUser-ManualReviewGroupId' = $groups.ManualReview; 'StaleUser-PilotGroupId' = $groups.Pilot }
foreach ($k in $vars.Keys) {
    Invoke-Arm PUT "$aaPath/variables/$k`?api-version=2024-10-23" @{ name = $k; properties = @{ value = ('"{0}"' -f $vars[$k]); isEncrypted = $false } } | Out-Null
    Write-Host "Automation variable set: $k"
}

if (-not $SkipScheduleLink) {
    $links = (Invoke-Arm GET "$aaPath/jobSchedules?api-version=2024-10-23").value
    if ($links | Where-Object { $_.properties.runbook.name -eq 'StaleUser-Monitor' -and $_.properties.schedule.name -eq 'StaleUser-Daily' }) {
        Write-Host 'Schedule already linked.'
    }
    else {
        Invoke-Arm PUT "$aaPath/jobSchedules/$([guid]::NewGuid())?api-version=2024-10-23" @{
            properties = @{
                runbook    = @{ name = 'StaleUser-Monitor' }
                schedule   = @{ name = 'StaleUser-Daily' }
                parameters = @{ ReportOnly = 'true'; PilotMode = 'true'; GraphEnvironment = 'Global'; AuthMode = 'ManagedIdentity'; InactivityDays = "$InactivityDays" }
            }
        } | Out-Null
        Write-Host 'Daily schedule linked (report-only).'
    }
}
[pscustomobject]$groups

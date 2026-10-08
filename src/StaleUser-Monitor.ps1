<#
.SYNOPSIS
    Microsoft Entra stale (inactive) user monitor. Phase 1 (report-only) by default, with the
    separately approved Phase 3 enforcement skeleton.

.DESCRIPTION
    - Reads signInActivity.lastSuccessfulSignInDateTime for member users via Microsoft Graph.
    - Applies ordered safety gates: disabled, guest, exclusion, manual review, synced, employeeType, null activity, then date bands.
    - Publishes normalized evidence to a DCR-based custom table
      through the Azure Monitor Logs Ingestion API.
    - Uses REST + managed identity tokens. No Microsoft Graph PowerShell modules are required.

    Run locally with -AuthMode AzureCli (uses `az account get-access-token`).
    In Azure Automation use -AuthMode ManagedIdentity (default).

.NOTES
    Phase 1 permissions: User.Read.All, AuditLog.Read.All, GroupMember.Read.All (application).
    Phase 3 additionally requires User.EnableDisableAccount.All and User.RevokeSessions.All and
    separate organizational approval. Without those permissions any write fails closed.
#>
param(
    [bool]$ReportOnly = $true,
    [bool]$PilotMode = $true,
    [ValidateRange(1, 365)][int]$InactivityDays = 30,
    [ValidateRange(0, 72)][int]$SignInActivitySafetyHours = 24,
    [ValidateRange(1, 1000)][int]$MaxDisableCount = 2,
    [ValidateSet('Global', 'USGov', 'USGovDoD')][string]$GraphEnvironment = 'Global',
    [ValidateSet('ManagedIdentity', 'AzureCli')][string]$AuthMode = 'ManagedIdentity',
    [string]$ExclusionGroupId,
    [string]$ManualReviewGroupId,
    [string]$PilotGroupId,
    [string]$IngestionEndpoint,
    [string]$DcrImmutableId,
    [string]$StreamName = 'Custom-EntraStaleUser_CL',
    [string]$Engine = 'AzureAutomation',
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:SUCloud = @{
    Global   = @{ Graph = 'https://graph.microsoft.com';    Monitor = 'https://monitor.azure.com' }
    USGov    = @{ Graph = 'https://graph.microsoft.us';     Monitor = 'https://monitor.azure.us' }
    USGovDoD = @{ Graph = 'https://dod-graph.microsoft.us'; Monitor = 'https://monitor.azure.us' }
}
$script:SUExcludedEmployeeTypes = @('ServiceAccount', 'SharedAccount', 'EmergencyAccess')
$script:SUUserSelect = 'id,displayName,userPrincipalName,userType,accountEnabled,createdDateTime,employeeType,onPremisesSyncEnabled,signInActivity'
$script:SUContext = @{ AuthMode = 'AzureCli'; GraphBase = 'https://graph.microsoft.com'; MonitorResource = 'https://monitor.azure.com'; TokenCache = @{} }

#region Helpers

function Assert-SUObjectId {
    param([Parameter(Mandatory)][string]$Name, [AllowEmptyString()][AllowNull()][string]$Value)
    $parsed = [guid]::Empty
    if ([string]::IsNullOrWhiteSpace($Value) -or -not [guid]::TryParse($Value, [ref]$parsed)) {
        throw "$Name must contain a valid Microsoft Entra object ID."
    }
}

function ConvertTo-SUUtc {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetime]) {
        $dt = if ($Value.Kind -eq [DateTimeKind]::Unspecified) { [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc) } else { $Value.ToUniversalTime() }
        return [DateTimeOffset]::new($dt.ToUniversalTime(), [TimeSpan]::Zero)
    }
    return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
}

function Get-SUCutoffs {
    param(
        [Parameter(Mandatory)][DateTimeOffset]$EvaluationUtc,
        [Parameter(Mandatory)][int]$InactivityDays,
        [Parameter(Mandatory)][int]$SignInActivitySafetyHours
    )
    $policy = $EvaluationUtc.AddDays(-$InactivityDays)
    [pscustomobject]@{
        EvaluationUtc   = $EvaluationUtc
        PolicyCutoffUtc = $policy
        ActionCutoffUtc = $policy.AddHours(-$SignInActivitySafetyHours)
    }
}

function New-SUIdSet {
    param([object[]]$Members)
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in @($Members)) {
        $id = Get-SUProp $m 'id'
        if ($id) { [void]$set.Add([string]$id) }
    }
    return , $set
}

function Get-SUProp {
    # Safe property read under StrictMode for Graph objects that omit null properties.
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $null }
}

#endregion

#region Authentication and REST

function Get-SUAccessToken {
    param([Parameter(Mandatory)][string]$Resource)
    $cache = $script:SUContext.TokenCache
    $cached = $cache[$Resource]
    if ($cached -and $cached.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) { return $cached.Token }

    switch ($script:SUContext.AuthMode) {
        'ManagedIdentity' {
            if (-not $env:IDENTITY_ENDPOINT -or -not $env:IDENTITY_HEADER) {
                throw 'Managed identity endpoint is unavailable. Run in Azure Automation with a system-assigned identity, or use -AuthMode AzureCli.'
            }
            $uri = '{0}?resource={1}' -f $env:IDENTITY_ENDPOINT, [uri]::EscapeDataString($Resource)
            $r = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; Metadata = 'True' }
            $token = $r.access_token
            $expiresRaw = Get-SUProp $r 'expires_on'
        }
        'AzureCli' {
            $json = az account get-access-token --resource $Resource -o json 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $json) { throw "az account get-access-token failed for resource $Resource. Run az login." }
            $r = ($json -join '') | ConvertFrom-Json
            $token = $r.accessToken
            $expiresRaw = Get-SUProp $r 'expires_on'
        }
    }
    $expires = [DateTimeOffset]::UtcNow.AddMinutes(30)
    $seconds = 0L
    if ($expiresRaw -and [long]::TryParse([string]$expiresRaw, [ref]$seconds)) { $expires = [DateTimeOffset]::FromUnixTimeSeconds($seconds) }
    $cache[$Resource] = @{ Token = $token; ExpiresOn = $expires }
    return $token
}

function Get-SUHttpStatus {
    param([object]$ErrorRecord)
    $resp = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($resp -and $resp.Value) { return [int]$resp.Value.StatusCode }
    return $null
}

function Get-SURetryDelaySeconds {
    param([object]$ErrorRecord, [int]$Attempt)
    $resp = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($resp -and $resp.Value -and $resp.Value.PSObject.Properties['Headers'] -and $resp.Value.Headers.RetryAfter) {
        $ra = $resp.Value.Headers.RetryAfter
        if ($ra.Delta) { return [math]::Max(1, [int]$ra.Delta.TotalSeconds) }
    }
    return [int][math]::Min(60, [math]::Pow(2, $Attempt))
}

function Invoke-SURest {
    param(
        [ValidateSet('GET', 'POST', 'PATCH')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Resource,
        [object]$Body,
        [int]$MaxRetries = 5
    )
    $attempt = 0
    while ($true) {
        $attempt++
        $params = @{
            Method      = $Method
            Uri         = $Uri
            Headers     = @{ Authorization = "Bearer $(Get-SUAccessToken -Resource $Resource)" }
            ErrorAction = 'Stop'
        }
        if ($PSBoundParameters.ContainsKey('Body')) {
            $params.Body = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 10 -Compress }
            $params.ContentType = 'application/json'
        }
        try {
            return Invoke-RestMethod @params
        }
        catch {
            $status = Get-SUHttpStatus $_
            if ($status -in 429, 500, 502, 503, 504 -and $attempt -le $MaxRetries) {
                Start-Sleep -Seconds (Get-SURetryDelaySeconds -ErrorRecord $_ -Attempt $attempt)
                continue
            }
            throw "HTTP $Method $Uri failed (status $status): $($_.Exception.Message)"
        }
    }
}

function Get-SUGraphCollection {
    param([Parameter(Mandatory)][string]$RelativeUri)
    $uri = if ($RelativeUri -match '^https://') { $RelativeUri } else { "$($script:SUContext.GraphBase)$RelativeUri" }
    $items = [System.Collections.Generic.List[object]]::new()
    $pages = 0
    do {
        $response = Invoke-SURest -Method GET -Uri $uri -Resource $script:SUContext.GraphBase
        $pages++
        $value = Get-SUProp $response 'value'
        if ($null -ne $value) { foreach ($i in @($value)) { $items.Add($i) } }
        $uri = Get-SUProp $response '@odata.nextLink'
    } while ($uri)
    [pscustomobject]@{ Items = $items.ToArray(); Pages = $pages; Complete = $true }
}

#endregion

#region Control state and classification

function Get-SUControlState {
    param([string]$ExclusionGroupId, [string]$ManualReviewGroupId, [string]$PilotGroupId)
    # Any failure throws: fail closed before evaluation or remediation.
    $state = @{
        ExclusionIds = (New-SUIdSet @())
        ManualIds    = (New-SUIdSet @())
        PilotIds     = (New-SUIdSet @())
        GroupPages   = @{}
    }
    $map = [ordered]@{ ExclusionIds = $ExclusionGroupId; ManualIds = $ManualReviewGroupId; PilotIds = $PilotGroupId }
    foreach ($key in @($map.Keys)) {
        $groupId = $map[$key]
        if ([string]::IsNullOrWhiteSpace($groupId)) { continue }
        $result = Get-SUGraphCollection -RelativeUri "/v1.0/groups/$groupId/transitiveMembers/microsoft.graph.user?`$select=id&`$top=999"
        $state[$key] = New-SUIdSet $result.Items
        $state.GroupPages[$key] = $result.Pages
    }
    return $state
}

function Get-SUDisposition {
    param(
        [Parameter(Mandatory)][object]$User,
        [Parameter(Mandatory)][hashtable]$ControlState,
        [Parameter(Mandatory)][object]$Cutoffs,
        [bool]$ReportOnly = $true,
        [bool]$PilotMode = $true,
        [string[]]$ExcludedEmployeeTypes = $script:SUExcludedEmployeeTypes
    )
    $id = [string](Get-SUProp $User 'id')
    $signIn = Get-SUProp $User 'signInActivity'
    $last = ConvertTo-SUUtc (Get-SUProp $signIn 'lastSuccessfulSignInDateTime')
    $daysInactive = -1
    if ($last) { $daysInactive = [int][math]::Floor(($Cutoffs.EvaluationUtc - $last).TotalDays) }
    $accountEnabled = Get-SUProp $User 'accountEnabled'
    $userType = [string](Get-SUProp $User 'userType')
    $syncEnabled = Get-SUProp $User 'onPremisesSyncEnabled'
    $employeeType = [string](Get-SUProp $User 'employeeType')
    $details = $null

    if ($accountEnabled -eq $false) { $d = 'Skipped'; $r = 'AlreadyDisabled' }
    elseif ($null -eq $accountEnabled) { $d = 'ManualReview'; $r = 'UnknownAccountState' }
    elseif ($userType -ne 'Member') { $d = 'Skipped'; $r = 'OutOfScopeUserType' }
    elseif ($ControlState.ExclusionIds.Contains($id)) { $d = 'Skipped'; $r = 'ApprovedExclusion' }
    elseif ($ControlState.ManualIds.Contains($id)) { $d = 'ManualReview'; $r = 'ManualReviewGroup' }
    elseif ($syncEnabled -eq $true) { $d = 'ManualReview'; $r = 'SynchronizedIdentity' }
    elseif ($employeeType -and $employeeType -in $ExcludedEmployeeTypes) { $d = 'Skipped'; $r = 'AccountClassification' }
    elseif ($null -eq $last) {
        $d = 'ManualReview'; $r = 'NullLastSuccessfulSignIn'
        $created = ConvertTo-SUUtc (Get-SUProp $User 'createdDateTime')
        if ($created) { $details = 'CreatedDaysAgo={0}' -f [int][math]::Floor(($Cutoffs.EvaluationUtc - $created).TotalDays) }
    }
    elseif ($last -le $Cutoffs.PolicyCutoffUtc) {
        if ($ReportOnly) { $d = 'CandidateReportOnly'; $r = 'InactiveThresholdReached' }
        elseif ($last -gt $Cutoffs.ActionCutoffUtc) { $d = 'PendingSafetyBuffer'; $r = 'SignInActivitySafetyBuffer' }
        elseif ($PilotMode -and -not $ControlState.PilotIds.Contains($id)) { $d = 'CandidateReportOnly'; $r = 'NotInPilotGroup' }
        else { $d = 'DisableCandidate'; $r = 'InactiveThresholdAndSafetyBufferExceeded' }
    }
    elseif ($daysInactive -ge 25) { $d = 'ReviewTicket'; $r = 'Inactive25To29Days' }
    elseif ($daysInactive -ge 20) { $d = 'NotifyUserAndManager'; $r = 'Inactive20To24Days' }
    elseif ($daysInactive -ge 15) { $d = 'NotifyUser'; $r = 'Inactive15To19Days' }
    else { $d = 'WithinPolicy'; $r = 'SuccessfulSignInWithinPolicy' }

    [pscustomobject]@{
        UserId                       = $id
        UserPrincipalName            = [string](Get-SUProp $User 'userPrincipalName')
        DisplayName                  = [string](Get-SUProp $User 'displayName')
        UserType                     = $userType
        AccountEnabled               = $accountEnabled
        EmployeeType                 = $employeeType
        OnPremisesSyncEnabled        = [bool]($syncEnabled -eq $true)
        LastSuccessfulSignInDateTime = $last
        DaysInactive                 = $daysInactive
        Disposition                  = $d
        Reason                       = $r
        Excluded                     = ($r -eq 'ApprovedExclusion')
        ManualReview                 = ($d -eq 'ManualReview')
        PilotMember                  = $ControlState.PilotIds.Contains($id)
        Action                       = 'None'
        ActionStatus                 = 'NotRequired'
        VerifiedAccountEnabled       = $null
        ErrorDetails                 = $null
        Details                      = $details
    }
}

#endregion

#region Evidence

function ConvertTo-SUIso {
    param([AllowNull()][object]$Value)
    $v = ConvertTo-SUUtc $Value
    if ($v) { return $v.ToString('o') } else { return $null }
}

function ConvertTo-SUEvidenceRecord {
    param(
        [Parameter(Mandatory)][ValidateSet('RunStarted', 'Evaluation', 'PendingAction', 'CompletedAction', 'Blocked', 'RunCompleted', 'RunFailed')][string]$RecordType,
        [AllowNull()][object]$Row,
        [Parameter(Mandatory)][hashtable]$Run,
        [string]$Reason,
        [string]$Details,
        [string]$ErrorDetails
    )
    $has = $null -ne $Row
    [ordered]@{
        TimeGenerated                = [DateTimeOffset]::UtcNow.ToString('o')
        RunId                        = $Run.RunId
        Engine                       = $Run.Engine
        Mode                         = $Run.Mode
        RecordType                   = $RecordType
        UserId                       = if ($has) { $Row.UserId } else { $null }
        UserPrincipalName            = if ($has) { $Row.UserPrincipalName } else { $null }
        DisplayName                  = if ($has) { $Row.DisplayName } else { $null }
        UserType                     = if ($has) { $Row.UserType } else { $null }
        AccountEnabled               = if ($has) { $Row.AccountEnabled } else { $null }
        EmployeeType                 = if ($has) { $Row.EmployeeType } else { $null }
        OnPremisesSyncEnabled        = if ($has) { $Row.OnPremisesSyncEnabled } else { $null }
        LastSuccessfulSignInDateTime = if ($has) { ConvertTo-SUIso $Row.LastSuccessfulSignInDateTime } else { $null }
        DaysInactive                 = if ($has) { [int]$Row.DaysInactive } else { $null }
        Disposition                  = if ($has) { $Row.Disposition } else { $null }
        Reason                       = if ($Reason) { $Reason } elseif ($has) { $Row.Reason } else { $null }
        Excluded                     = if ($has) { [bool]$Row.Excluded } else { $false }
        ManualReview                 = if ($has) { [bool]$Row.ManualReview } else { $false }
        PilotMember                  = if ($has) { [bool]$Row.PilotMember } else { $false }
        Action                       = if ($has) { $Row.Action } else { 'None' }
        ActionStatus                 = if ($has) { $Row.ActionStatus } else { 'NotRequired' }
        TicketId                     = $null
        VerifiedAccountEnabled       = if ($has) { $Row.VerifiedAccountEnabled } else { $null }
        PolicyCutoffUtc              = $Run.Cutoffs.PolicyCutoffUtc.ToString('o')
        ActionCutoffUtc              = $Run.Cutoffs.ActionCutoffUtc.ToString('o')
        Details                      = if ($Details) { $Details } elseif ($has) { $Row.Details } else { $null }
        ErrorDetails                 = if ($ErrorDetails) { $ErrorDetails } elseif ($has) { $Row.ErrorDetails } else { $null }
    }
}

function Split-SUBatches {
    param([object[]]$Records, [int]$MaxBytes = 900KB)
    $batches = [System.Collections.Generic.List[object]]::new()
    $current = [System.Collections.Generic.List[object]]::new()
    $size = 2
    foreach ($rec in $Records) {
        $len = [Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $rec -Depth 5 -Compress)) + 1
        if ($current.Count -gt 0 -and ($size + $len) -gt $MaxBytes) {
            $batches.Add($current.ToArray()); $current = [System.Collections.Generic.List[object]]::new(); $size = 2
        }
        $current.Add($rec); $size += $len
    }
    if ($current.Count -gt 0) { $batches.Add($current.ToArray()) }
    return , $batches.ToArray()
}

function Publish-SUEvidence {
    param([Parameter(Mandatory)][object[]]$Records, [Parameter(Mandatory)][hashtable]$Run)
    if ($Run.OutputPath) {
        foreach ($rec in $Records) { Add-Content -Path $Run.OutputPath -Value (ConvertTo-Json -InputObject $rec -Depth 5 -Compress) -Encoding utf8 }
    }
    if (-not $Run.IngestionEndpoint) {
        if (-not $Run.ReportOnly) { throw 'Durable evidence (DCR ingestion) is not configured. Enforcement is blocked.' }
        if (-not $Run.OutputPath) { foreach ($rec in $Records) { Write-Output (ConvertTo-Json -InputObject $rec -Depth 5 -Compress) } }
        return
    }
    $uri = '{0}/dataCollectionRules/{1}/streams/{2}?api-version=2023-01-01' -f $Run.IngestionEndpoint.TrimEnd('/'), $Run.DcrImmutableId, $Run.StreamName
    foreach ($batch in (Split-SUBatches -Records $Records)) {
        $body = ConvertTo-Json -InputObject @($batch) -Depth 5 -Compress
        [void](Invoke-SURest -Method POST -Uri $uri -Resource $script:SUContext.MonitorResource -Body $body)
    }
}

#endregion

#region Phase 3 skeleton (separate approval required)

function Set-SUBlocked {
    param([object]$Row, [string]$Reason)
    $Row.Disposition = 'BlockedRemediation'; $Row.Reason = $Reason; $Row.Action = 'None'; $Row.ActionStatus = 'Blocked'
}

function Invoke-SUEnforcement {
    param([Parameter(Mandatory)][object[]]$Candidates, [Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][hashtable]$Groups)
    $graph = $script:SUContext.GraphBase
    foreach ($c in $Candidates) {
        # Reload every control group immediately before each write.
        $fresh = Get-SUControlState -ExclusionGroupId $Groups.Exclusion -ManualReviewGroupId $Groups.ManualReview -PilotGroupId $Groups.Pilot
        $u = Invoke-SURest -Method GET -Uri "$graph/v1.0/users/$($c.UserId)?`$select=id,accountEnabled,userType,onPremisesSyncEnabled,signInActivity" -Resource $graph
        $freshLast = ConvertTo-SUUtc (Get-SUProp (Get-SUProp $u 'signInActivity') 'lastSuccessfulSignInDateTime')

        if ((Get-SUProp $u 'accountEnabled') -ne $true) { Set-SUBlocked $c 'AlreadyDisabledAtRevalidation' }
        elseif ((Get-SUProp $u 'userType') -ne 'Member') { Set-SUBlocked $c 'OutOfScopeAtRevalidation' }
        elseif ((Get-SUProp $u 'onPremisesSyncEnabled') -eq $true) { Set-SUBlocked $c 'SynchronizedAtRevalidation' }
        elseif ($null -eq $freshLast) { Set-SUBlocked $c 'NullActivityAtRevalidation' }
        elseif ($freshLast -gt $Run.Cutoffs.ActionCutoffUtc) { Set-SUBlocked $c 'RecentSignInAtRevalidation' }
        elseif ($fresh.ExclusionIds.Contains($c.UserId)) { Set-SUBlocked $c 'ApprovedExclusionAtRevalidation' }
        elseif ($fresh.ManualIds.Contains($c.UserId)) { Set-SUBlocked $c 'ManualReviewAtRevalidation' }
        elseif ($Run.PilotMode -and -not $fresh.PilotIds.Contains($c.UserId)) { Set-SUBlocked $c 'NotInPilotAtRevalidation' }

        if ($c.ActionStatus -eq 'Blocked') {
            Publish-SUEvidence -Records @(ConvertTo-SUEvidenceRecord -RecordType Blocked -Row $c -Run $Run) -Run $Run
            continue
        }

        $c.Action = 'Disable'; $c.ActionStatus = 'Planned'
        # The pending record must be stored before the write; a publish failure throws and blocks the write.
        Publish-SUEvidence -Records @(ConvertTo-SUEvidenceRecord -RecordType PendingAction -Row $c -Run $Run) -Run $Run

        try {
            [void](Invoke-SURest -Method PATCH -Uri "$graph/v1.0/users/$($c.UserId)" -Resource $graph -Body @{ accountEnabled = $false })
        }
        catch {
            $c.Disposition = 'Failed'; $c.ActionStatus = 'Failed'; $c.ErrorDetails = $_.Exception.Message
            Publish-SUEvidence -Records @(ConvertTo-SUEvidenceRecord -RecordType CompletedAction -Row $c -Run $Run) -Run $Run
            throw
        }
        try {
            [void](Invoke-SURest -Method POST -Uri "$graph/v1.0/users/$($c.UserId)/revokeSignInSessions" -Resource $graph -Body @{})
        }
        catch {
            $c.Disposition = 'Failed'; $c.ActionStatus = 'PartialSuccess'; $c.ErrorDetails = "Disabled but session revocation failed: $($_.Exception.Message)"
            Publish-SUEvidence -Records @(ConvertTo-SUEvidenceRecord -RecordType CompletedAction -Row $c -Run $Run) -Run $Run
            throw "Account $($c.UserId) was disabled, but session revocation failed. Subsequent writes stopped."
        }
        $verify = Invoke-SURest -Method GET -Uri "$graph/v1.0/users/$($c.UserId)?`$select=id,accountEnabled" -Resource $graph
        $c.VerifiedAccountEnabled = Get-SUProp $verify 'accountEnabled'
        if ($c.VerifiedAccountEnabled -ne $false) {
            $c.Disposition = 'Failed'; $c.ActionStatus = 'Failed'; $c.ErrorDetails = 'Post-action verification did not return accountEnabled=false.'
            Publish-SUEvidence -Records @(ConvertTo-SUEvidenceRecord -RecordType CompletedAction -Row $c -Run $Run) -Run $Run
            throw "Disable verification failed for $($c.UserId)."
        }
        $c.Disposition = 'Disabled'; $c.Reason = 'InactiveAccountDisabled'; $c.ActionStatus = 'Success'
        Publish-SUEvidence -Records @(ConvertTo-SUEvidenceRecord -RecordType CompletedAction -Row $c -Run $Run) -Run $Run
    }
}

#endregion

#region Main

function Resolve-SUSetting {
    param([AllowNull()][AllowEmptyString()][string]$Value, [string]$VariableName)
    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if (Get-Command -Name Get-AutomationVariable -ErrorAction SilentlyContinue) {
        try { return [string](Get-AutomationVariable -Name $VariableName) } catch { return $null }
    }
    return $null
}

function Invoke-SUMain {
    param([Parameter(Mandatory)][hashtable]$Config)

    $cloud = $script:SUCloud[$Config.GraphEnvironment]
    $script:SUContext = @{ AuthMode = $Config.AuthMode; GraphBase = $cloud.Graph; MonitorResource = $cloud.Monitor; TokenCache = @{} }

    $groups = @{
        Exclusion    = Resolve-SUSetting $Config.ExclusionGroupId 'StaleUser-ExclusionGroupId'
        ManualReview = Resolve-SUSetting $Config.ManualReviewGroupId 'StaleUser-ManualReviewGroupId'
        Pilot        = Resolve-SUSetting $Config.PilotGroupId 'StaleUser-PilotGroupId'
    }
    Assert-SUObjectId -Name 'ExclusionGroupId' -Value $groups.Exclusion
    Assert-SUObjectId -Name 'ManualReviewGroupId' -Value $groups.ManualReview
    if ($groups.Pilot -or ($Config.PilotMode -and -not $Config.ReportOnly)) { Assert-SUObjectId -Name 'PilotGroupId' -Value $groups.Pilot }

    $run = @{
        RunId             = [guid]::NewGuid().ToString()
        Engine            = $Config.Engine
        Mode              = if ($Config.ReportOnly) { 'ReportOnly' } elseif ($Config.PilotMode) { 'DisablePilot' } else { 'Production' }
        ReportOnly        = [bool]$Config.ReportOnly
        PilotMode         = [bool]$Config.PilotMode
        Cutoffs           = Get-SUCutoffs -EvaluationUtc ([DateTimeOffset]::UtcNow) -InactivityDays $Config.InactivityDays -SignInActivitySafetyHours $Config.SignInActivitySafetyHours
        IngestionEndpoint = Resolve-SUSetting $Config.IngestionEndpoint 'StaleUser-IngestionEndpoint'
        DcrImmutableId    = Resolve-SUSetting $Config.DcrImmutableId 'StaleUser-DcrImmutableId'
        StreamName        = $Config.StreamName
        OutputPath        = $Config.OutputPath
    }
    if (-not $run.ReportOnly -and (-not $run.IngestionEndpoint -or -not $run.DcrImmutableId)) {
        throw 'Durable evidence (DCR ingestion) is not configured. Enforcement is blocked.'
    }
    if ($run.IngestionEndpoint -and -not $run.DcrImmutableId) { throw 'IngestionEndpoint is set but DcrImmutableId is missing.' }

    try {
        $control = Get-SUControlState -ExclusionGroupId $groups.Exclusion -ManualReviewGroupId $groups.ManualReview -PilotGroupId $groups.Pilot
        $startDetails = [ordered]@{
            InactivityDays = $Config.InactivityDays; SafetyHours = $Config.SignInActivitySafetyHours; MaxDisableCount = $Config.MaxDisableCount
            GraphEnvironment = $Config.GraphEnvironment; Exclusions = $control.ExclusionIds.Count; ManualReview = $control.ManualIds.Count
            Pilot = $control.PilotIds.Count; GroupPages = $control.GroupPages; EvaluationUtc = $run.Cutoffs.EvaluationUtc.ToString('o')
        }
        Publish-SUEvidence -Records @(ConvertTo-SUEvidenceRecord -RecordType RunStarted -Row $null -Run $run -Reason 'RunStarted' -Details (ConvertTo-Json $startDetails -Compress)) -Run $run

        $users = Get-SUGraphCollection -RelativeUri "/v1.0/users?`$top=500&`$select=$($script:SUUserSelect)"
        $report = @(foreach ($u in $users.Items) {
                Get-SUDisposition -User $u -ControlState $control -Cutoffs $run.Cutoffs -ReportOnly $run.ReportOnly -PilotMode $run.PilotMode
            })
        if ($report.Count -gt 0) {
            Publish-SUEvidence -Records @($report | ForEach-Object { ConvertTo-SUEvidenceRecord -RecordType Evaluation -Row $_ -Run $run }) -Run $run
        }

        $candidates = @($report | Where-Object Disposition -EQ 'DisableCandidate')
        if (-not $run.ReportOnly) {
            if ($candidates.Count -gt $Config.MaxDisableCount) {
                Publish-SUEvidence -Records @(ConvertTo-SUEvidenceRecord -RecordType Blocked -Row $null -Run $run -Reason 'MaxDisableCountExceeded' -Details "Candidates=$($candidates.Count);Max=$($Config.MaxDisableCount)") -Run $run
                throw "Candidate count $($candidates.Count) exceeds MaxDisableCount $($Config.MaxDisableCount). No writes performed."
            }
            if ($candidates.Count -gt 0) { Invoke-SUEnforcement -Candidates $candidates -Run $run -Groups $groups }
        }

        $summary = [ordered]@{ Evaluated = $report.Count; UserPages = $users.Pages }
        foreach ($g in ($report | Group-Object Disposition)) { $summary[$g.Name] = $g.Count }
        $summaryJson = ConvertTo-Json $summary -Compress
        Publish-SUEvidence -Records @(ConvertTo-SUEvidenceRecord -RecordType RunCompleted -Row $null -Run $run -Reason 'RunCompleted' -Details $summaryJson) -Run $run
        Write-Output "RunId=$($run.RunId) Mode=$($run.Mode) Summary=$summaryJson"
    }
    catch {
        $message = $_.Exception.Message
        try {
            Publish-SUEvidence -Records @(ConvertTo-SUEvidenceRecord -RecordType RunFailed -Row $null -Run $run -Reason 'RunFailed' -ErrorDetails $message) -Run $run
        }
        catch { Write-Warning "Unable to publish RunFailed evidence: $($_.Exception.Message)" }
        throw "Fail-closed run failure for RunId $($run.RunId): $message"
    }
}

#endregion

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-SUMain -Config @{
        ReportOnly                = $ReportOnly
        PilotMode                 = $PilotMode
        InactivityDays            = $InactivityDays
        SignInActivitySafetyHours = $SignInActivitySafetyHours
        MaxDisableCount           = $MaxDisableCount
        GraphEnvironment          = $GraphEnvironment
        AuthMode                  = $AuthMode
        ExclusionGroupId          = $ExclusionGroupId
        ManualReviewGroupId       = $ManualReviewGroupId
        PilotGroupId              = $PilotGroupId
        IngestionEndpoint         = $IngestionEndpoint
        DcrImmutableId            = $DcrImmutableId
        StreamName                = $StreamName
        Engine                    = $Engine
        OutputPath                = $OutputPath
    }
}

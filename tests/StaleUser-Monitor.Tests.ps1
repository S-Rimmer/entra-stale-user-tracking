#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'src') 'StaleUser-Monitor.ps1')

    # Safety net: no test may reach a real endpoint or acquire a real token.
    Mock Invoke-RestMethod { throw "Unexpected real HTTP call to $Uri" }
    Mock Get-SUAccessToken { 'test-token' }

    $script:Now = [DateTimeOffset]::new(2026, 10, 8, 12, 0, 0, [TimeSpan]::Zero)
    $script:Cutoffs = Get-SUCutoffs -EvaluationUtc $script:Now -InactivityDays 30 -SignInActivitySafetyHours 24

    function New-TestUser {
        param(
            [string]$Id = ([guid]::NewGuid().ToString()),
            [Nullable[double]]$DaysAgo,
            [string]$UserType = 'Member',
            [object]$AccountEnabled = $true,
            [object]$Sync = $null,
            [string]$EmployeeType = $null
        )
        $last = if ($null -ne $DaysAgo) { $script:Now.AddDays(-$DaysAgo).ToString('o') } else { $null }
        [pscustomobject]@{
            id                    = $Id
            displayName           = "User $Id"
            userPrincipalName     = "$Id@contoso.test"
            userType              = $UserType
            accountEnabled        = $AccountEnabled
            createdDateTime       = $script:Now.AddDays(-400).ToString('o')
            employeeType          = $EmployeeType
            onPremisesSyncEnabled = $Sync
            signInActivity        = [pscustomobject]@{ lastSuccessfulSignInDateTime = $last }
        }
    }

    function New-TestControl {
        param([string[]]$Exclusions = @(), [string[]]$Manual = @(), [string[]]$Pilot = @())
        @{
            ExclusionIds = (New-SUIdSet ($Exclusions | ForEach-Object { [pscustomobject]@{ id = $_ } }))
            ManualIds    = (New-SUIdSet ($Manual | ForEach-Object { [pscustomobject]@{ id = $_ } }))
            PilotIds     = (New-SUIdSet ($Pilot | ForEach-Object { [pscustomobject]@{ id = $_ } }))
            GroupPages   = @{}
        }
    }

    function Get-Disp {
        param($User, $Control = (New-TestControl), [bool]$ReportOnly = $true, [bool]$PilotMode = $true)
        Get-SUDisposition -User $User -ControlState $Control -Cutoffs $script:Cutoffs -ReportOnly $ReportOnly -PilotMode $PilotMode
    }
}

Describe 'Cutoff calculation' {
    It 'derives PolicyCutoffUtc as 30 x 24h and ActionCutoffUtc as policy minus safety hours' {
        $script:Cutoffs.PolicyCutoffUtc | Should -Be $script:Now.AddDays(-30)
        $script:Cutoffs.ActionCutoffUtc | Should -Be $script:Now.AddDays(-31)
    }
    It 'supports a zero safety interval' {
        $c = Get-SUCutoffs -EvaluationUtc $script:Now -InactivityDays 30 -SignInActivitySafetyHours 0
        $c.ActionCutoffUtc | Should -Be $c.PolicyCutoffUtc
    }
}

Describe 'Phase 1 classification bands' {
    It '<Name> -> <Disposition>/<Reason>' -ForEach @(
        @{ Name = 'Active member (2 days)'; Days = 2; Disposition = 'WithinPolicy'; Reason = 'SuccessfulSignInWithinPolicy' }
        @{ Name = '14.9 days'; Days = 14.9; Disposition = 'WithinPolicy'; Reason = 'SuccessfulSignInWithinPolicy' }
        @{ Name = '15-day member'; Days = 15; Disposition = 'NotifyUser'; Reason = 'Inactive15To19Days' }
        @{ Name = '20-day member'; Days = 20; Disposition = 'NotifyUserAndManager'; Reason = 'Inactive20To24Days' }
        @{ Name = '25-day member'; Days = 25; Disposition = 'ReviewTicket'; Reason = 'Inactive25To29Days' }
        @{ Name = '29.9 days'; Days = 29.9; Disposition = 'ReviewTicket'; Reason = 'Inactive25To29Days' }
        @{ Name = 'Exactly 30 days (boundary)'; Days = 30; Disposition = 'CandidateReportOnly'; Reason = 'InactiveThresholdReached' }
        @{ Name = '90 days'; Days = 90; Disposition = 'CandidateReportOnly'; Reason = 'InactiveThresholdReached' }
    ) {
        $r = Get-Disp (New-TestUser -DaysAgo $Days)
        $r.Disposition | Should -Be $Disposition
        $r.Reason | Should -Be $Reason
        $r.Action | Should -Be 'None'
    }

    It 'never produces DisableCandidate in report-only mode, even for pilot members' {
        $u = New-TestUser -DaysAgo 120
        $r = Get-Disp $u (New-TestControl -Pilot $u.id) -ReportOnly $true -PilotMode $false
        $r.Disposition | Should -Not -Be 'DisableCandidate'
    }

    It 'calculates whole DaysInactive and -1 for unknown activity' {
        (Get-Disp (New-TestUser -DaysAgo 31.7)).DaysInactive | Should -Be 31
        (Get-Disp (New-TestUser -DaysAgo $null)).DaysInactive | Should -Be -1
    }
}

Describe 'Safety gates and exclusions' {
    It 'Exclusion member is skipped as ApprovedExclusion even at 200 days' {
        $u = New-TestUser -DaysAgo 200
        $r = Get-Disp $u (New-TestControl -Exclusions $u.id) -ReportOnly $false -PilotMode $false
        $r.Disposition | Should -Be 'Skipped'; $r.Reason | Should -Be 'ApprovedExclusion'; $r.Excluded | Should -BeTrue
    }
    It 'Exclusion takes precedence over manual review' {
        $u = New-TestUser -DaysAgo 60
        (Get-Disp $u (New-TestControl -Exclusions $u.id -Manual $u.id)).Reason | Should -Be 'ApprovedExclusion'
    }
    It 'Manual-review member is ManualReview only' {
        $u = New-TestUser -DaysAgo 60
        $r = Get-Disp $u (New-TestControl -Manual $u.id) -ReportOnly $false -PilotMode $false
        $r.Disposition | Should -Be 'ManualReview'; $r.Reason | Should -Be 'ManualReviewGroup'; $r.ManualReview | Should -BeTrue
    }
    It 'Group membership matching is case-insensitive' {
        $u = New-TestUser -Id 'AAAAAAAA-1111-2222-3333-444444444444' -DaysAgo 60
        (Get-Disp $u (New-TestControl -Exclusions 'aaaaaaaa-1111-2222-3333-444444444444')).Reason | Should -Be 'ApprovedExclusion'
    }
    It 'Guest is out of scope' {
        (Get-Disp (New-TestUser -DaysAgo 90 -UserType 'Guest')).Reason | Should -Be 'OutOfScopeUserType'
    }
    It 'Already disabled is skipped' {
        $r = Get-Disp (New-TestUser -DaysAgo 90 -AccountEnabled $false)
        $r.Disposition | Should -Be 'Skipped'; $r.Reason | Should -Be 'AlreadyDisabled'
    }
    It 'Unknown accountEnabled routes to manual review' {
        (Get-Disp (New-TestUser -DaysAgo 90 -AccountEnabled $null)).Reason | Should -Be 'UnknownAccountState'
    }
    It 'Null lastSuccessfulSignInDateTime routes to manual review with created age' {
        $r = Get-Disp (New-TestUser -DaysAgo $null) -ReportOnly $false -PilotMode $false
        $r.Disposition | Should -Be 'ManualReview'; $r.Reason | Should -Be 'NullLastSuccessfulSignIn'
        $r.Details | Should -Be 'CreatedDaysAgo=400'
    }
    It 'User with no signInActivity property at all routes to manual review' {
        $u = New-TestUser -DaysAgo 90; $u.PSObject.Properties.Remove('signInActivity')
        (Get-Disp $u).Reason | Should -Be 'NullLastSuccessfulSignIn'
    }
    It 'Synchronized identity routes to manual review' {
        $r = Get-Disp (New-TestUser -DaysAgo 90 -Sync $true) -ReportOnly $false -PilotMode $false
        $r.Reason | Should -Be 'SynchronizedIdentity'; $r.OnPremisesSyncEnabled | Should -BeTrue
    }
    It 'Excluded employeeType <Type> is skipped' -ForEach @(@{ Type = 'ServiceAccount' }, @{ Type = 'SharedAccount' }, @{ Type = 'EmergencyAccess' }) {
        (Get-Disp (New-TestUser -DaysAgo 90 -EmployeeType $Type)).Reason | Should -Be 'AccountClassification'
    }
}

Describe 'Phase 3 classification (separately approved)' {
    It '30.5 days is PendingSafetyBuffer, not a disable candidate' {
        $u = New-TestUser -DaysAgo 30.5
        (Get-Disp $u (New-TestControl -Pilot $u.id) -ReportOnly $false).Disposition | Should -Be 'PendingSafetyBuffer'
    }
    It '32-day pilot member is DisableCandidate' {
        $u = New-TestUser -DaysAgo 32
        (Get-Disp $u (New-TestControl -Pilot $u.id) -ReportOnly $false -PilotMode $true).Disposition | Should -Be 'DisableCandidate'
    }
    It 'Non-pilot user during pilot is report-only' {
        $r = Get-Disp (New-TestUser -DaysAgo 32) -ReportOnly $false -PilotMode $true
        $r.Disposition | Should -Be 'CandidateReportOnly'; $r.Reason | Should -Be 'NotInPilotGroup'
    }
}

Describe 'Input validation' {
    It 'rejects placeholder group IDs' {
        { Assert-SUObjectId -Name 'ExclusionGroupId' -Value '[ExclusionGroupObjectId]' } | Should -Throw '*valid Microsoft Entra object ID*'
        { Assert-SUObjectId -Name 'ExclusionGroupId' -Value '' } | Should -Throw
    }
    It 'parses Graph timestamps as UTC regardless of input type' {
        (ConvertTo-SUUtc '2026-09-01T10:00:00Z').Offset | Should -Be ([TimeSpan]::Zero)
        (ConvertTo-SUUtc ([datetime]::SpecifyKind([datetime]'2026-09-01T10:00:00', 'Utc'))).Hour | Should -Be 10
        ConvertTo-SUUtc $null | Should -BeNullOrEmpty
    }
}

Describe 'Graph pagination and fail-closed reads' {
    BeforeEach { $script:SUContext = @{ AuthMode = 'AzureCli'; GraphBase = 'https://graph.microsoft.com'; MonitorResource = 'https://monitor.azure.com'; TokenCache = @{} } }

    It 'follows @odata.nextLink until exhausted' {
        Mock Invoke-SURest -ParameterFilter { $Uri -notmatch 'page2' } { [pscustomobject]@{ value = @(@{ id = '1' }, @{ id = '2' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/users?page2' } }
        Mock Invoke-SURest -ParameterFilter { $Uri -match 'page2' } { [pscustomobject]@{ value = @(@{ id = '3' }) } }
        $r = Get-SUGraphCollection -RelativeUri '/v1.0/users'
        $r.Items.Count | Should -Be 3
        $r.Pages | Should -Be 2
    }
    It 'handles an empty page' {
        Mock Invoke-SURest { [pscustomobject]@{ value = @() } }
        (Get-SUGraphCollection -RelativeUri '/v1.0/users').Items.Count | Should -Be 0
    }
    It 'throws when a later page fails (incomplete pagination)' {
        Mock Invoke-SURest -ParameterFilter { $Uri -notmatch 'page2' } { [pscustomobject]@{ value = @(@{ id = '1' }); '@odata.nextLink' = 'https://graph.microsoft.com/next?page2' } }
        Mock Invoke-SURest -ParameterFilter { $Uri -match 'page2' } { throw 'HTTP GET failed (status 500)' }
        { Get-SUGraphCollection -RelativeUri '/v1.0/users' } | Should -Throw
    }
    It 'Get-SUControlState throws when any control group cannot be read' {
        Mock Invoke-SURest -ParameterFilter { $Uri -match 'groups/bad' } { throw 'HTTP GET failed (status 404)' }
        Mock Invoke-SURest { [pscustomobject]@{ value = @() } }
        { Get-SUControlState -ExclusionGroupId 'good' -ManualReviewGroupId 'bad' } | Should -Throw
    }
}

Describe 'REST retry handling' {
    BeforeEach {
        $script:SUContext = @{ AuthMode = 'AzureCli'; GraphBase = 'https://graph.microsoft.com'; MonitorResource = 'https://monitor.azure.com'; TokenCache = @{} }
        Mock Get-SUAccessToken { 'token' }
        Mock Start-Sleep { }
        $script:Calls = 0
    }
    It 'retries 429 using Retry-After and then succeeds' {
        Mock Invoke-RestMethod {
            $script:Calls++
            if ($script:Calls -lt 3) {
                $resp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
                $resp.Headers.RetryAfter = [System.Net.Http.Headers.RetryConditionHeaderValue]::new([TimeSpan]::FromSeconds(7))
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('throttled', $resp)
            }
            [pscustomobject]@{ ok = $true }
        }
        (Invoke-SURest -Uri 'https://graph.microsoft.com/v1.0/users' -Resource 'https://graph.microsoft.com').ok | Should -BeTrue
        $script:Calls | Should -Be 3
        Should -Invoke Start-Sleep -Times 2 -ParameterFilter { $Seconds -eq 7 }
    }
    It 'does not retry a 403 and surfaces the status' {
        Mock Invoke-RestMethod {
            $script:Calls++
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('forbidden', [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden))
        }
        { Invoke-SURest -Uri 'https://graph.microsoft.com/v1.0/users' -Resource 'https://graph.microsoft.com' } | Should -Throw '*status 403*'
        $script:Calls | Should -Be 1
    }
}

Describe 'Evidence schema and batching' {
    BeforeAll {
        $script:Run = @{ RunId = 'r1'; Engine = 'AzureAutomation'; Mode = 'ReportOnly'; Cutoffs = $script:Cutoffs }
        $script:Expected = 'TimeGenerated', 'RunId', 'Engine', 'Mode', 'RecordType', 'UserId', 'UserPrincipalName', 'DisplayName', 'UserType',
        'AccountEnabled', 'EmployeeType', 'OnPremisesSyncEnabled', 'LastSuccessfulSignInDateTime', 'DaysInactive', 'Disposition', 'Reason',
        'Excluded', 'ManualReview', 'PilotMember', 'Action', 'ActionStatus', 'TicketId', 'VerifiedAccountEnabled', 'PolicyCutoffUtc',
        'ActionCutoffUtc', 'Details', 'ErrorDetails'
    }
    It 'Evaluation record contains every E.2 column' {
        $rec = ConvertTo-SUEvidenceRecord -RecordType Evaluation -Row (Get-Disp (New-TestUser -DaysAgo 40)) -Run $script:Run
        @($rec.Keys) | Should -Be $script:Expected
        $rec.LastSuccessfulSignInDateTime | Should -Match 'Z$|\+00:00$'
    }
    It 'Run-level record has null user fields and both cutoffs' {
        $rec = ConvertTo-SUEvidenceRecord -RecordType RunStarted -Row $null -Run $script:Run -Reason 'RunStarted'
        $rec.UserId | Should -BeNullOrEmpty
        $rec.PolicyCutoffUtc | Should -Not -BeNullOrEmpty
        $rec.ActionCutoffUtc | Should -Not -BeNullOrEmpty
    }
    It 'splits large payloads into batches under the size limit' {
        $recs = 1..300 | ForEach-Object { @{ Details = ('x' * 4000) } }
        $batches = Split-SUBatches -Records $recs -MaxBytes 200KB
        $batches.Count | Should -BeGreaterThan 1
        ($batches | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum | Should -Be 300
    }
    It 'keeps a single record as a JSON array' {
        $batches = Split-SUBatches -Records @(@{ a = 1 })
        $batches.Count | Should -Be 1
        (ConvertTo-Json -InputObject @($batches[0]) -Compress) | Should -Match '^\['
    }
}

Describe 'End-to-end run with mocked Graph and ingestion' {
    BeforeAll {
        $script:Ids = @{ Excl = [guid]::NewGuid().ToString(); Manual = [guid]::NewGuid().ToString(); Pilot = [guid]::NewGuid().ToString() }
        $script:BaseConfig = @{
            ReportOnly = $true; PilotMode = $true; InactivityDays = 30; SignInActivitySafetyHours = 24; MaxDisableCount = 2
            GraphEnvironment = 'Global'; AuthMode = 'AzureCli'; Engine = 'Pester'; StreamName = 'Custom-EntraStaleUser_CL'; OutputPath = $null
            ExclusionGroupId = $script:Ids.Excl; ManualReviewGroupId = $script:Ids.Manual; PilotGroupId = $script:Ids.Pilot
            IngestionEndpoint = 'https://dcr.test.ingest.monitor.azure.com'; DcrImmutableId = 'dcr-test'
        }
        function Initialize-GraphMock {
            param([object[]]$Users, [string[]]$Exclusions = @(), [string[]]$Manual = @(), [string[]]$Pilot = @(), [object]$FreshUser)
            $script:Ingested = [System.Collections.Generic.List[object]]::new()
            $script:Writes = [System.Collections.Generic.List[string]]::new()
            $script:MockUsers = $Users; $script:MockFresh = $FreshUser
            $script:MockGroups = @{ $script:Ids.Excl = $Exclusions; $script:Ids.Manual = $Manual; $script:Ids.Pilot = $Pilot }
            Mock Invoke-SURest -ParameterFilter { $Uri -match 'ingest\.monitor' } { foreach ($r in ($Body | ConvertFrom-Json)) { $script:Ingested.Add($r) } }
            Mock Invoke-SURest -ParameterFilter { $Uri -match '/groups/([0-9a-f-]+)/' } {
                $gid = [regex]::Match($Uri, '/groups/([0-9a-f-]+)/').Groups[1].Value
                [pscustomobject]@{ value = @($script:MockGroups[$gid] | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = $_ } }) }
            }
            Mock Invoke-SURest -ParameterFilter { $Uri -match '/v1\.0/users\?' } { [pscustomobject]@{ value = $script:MockUsers } }
            Mock Invoke-SURest -ParameterFilter { $Method -eq 'GET' -and $Uri -match '/v1\.0/users/[0-9a-f-]+\?' } {
                if ($script:MockFresh) { $script:MockFresh } else { [pscustomobject]@{ id = 'x'; accountEnabled = $false } }
            }
            Mock Invoke-SURest -ParameterFilter { $Method -in 'PATCH', 'POST' -and $Uri -match 'graph\.microsoft' } { $script:Writes.Add("$Method $Uri") }
        }
        function Get-Records([string]$Type) { , @($script:Ingested | Where-Object RecordType -EQ $Type) }
    }

    Context 'Phase 1 report-only' {
        It 'publishes RunStarted, one Evaluation per user, RunCompleted, and performs no writes' {
            $users = @(
                (New-TestUser -DaysAgo 1), (New-TestUser -DaysAgo 45), (New-TestUser -DaysAgo $null),
                (New-TestUser -DaysAgo 60 -UserType Guest), (New-TestUser -DaysAgo 90 -AccountEnabled $false)
            )
            Initialize-GraphMock -Users $users -Pilot $users[1].id
            $out = Invoke-SUMain -Config $script:BaseConfig
            (Get-Records RunStarted).Count | Should -Be 1
            (Get-Records Evaluation).Count | Should -Be 5
            (Get-Records RunCompleted).Count | Should -Be 1
            @($script:Ingested | Where-Object { $_.RecordType -eq 'Evaluation' -and $_.Disposition -eq 'DisableCandidate' }).Count | Should -Be 0
            @($script:Ingested.RunId | Select-Object -Unique).Count | Should -Be 1
            $script:Writes.Count | Should -Be 0
            "$out" | Should -Match 'Mode=ReportOnly'
        }
        It 'fails closed with a RunFailed record and no Evaluation records when a control group read fails' {
            Initialize-GraphMock -Users @(New-TestUser -DaysAgo 45)
            Mock Invoke-SURest -ParameterFilter { $Uri -match '/groups/' } { throw 'HTTP GET failed (status 503)' }
            { Invoke-SUMain -Config $script:BaseConfig } | Should -Throw '*Fail-closed*'
            (Get-Records RunFailed).Count | Should -Be 1
            (Get-Records Evaluation).Count | Should -Be 0
        }
        It 'fails closed when the user listing fails after RunStarted' {
            Initialize-GraphMock -Users @()
            Mock Invoke-SURest -ParameterFilter { $Uri -match '/v1\.0/users\?' } { throw 'HTTP GET failed (status 500)' }
            { Invoke-SUMain -Config $script:BaseConfig } | Should -Throw
            (Get-Records RunStarted).Count | Should -Be 1
            (Get-Records RunCompleted).Count | Should -Be 0
            (Get-Records RunFailed).Count | Should -Be 1
        }
        It 'rejects placeholder group IDs before any Graph call' {
            Initialize-GraphMock -Users @()
            $cfg = $script:BaseConfig.Clone(); $cfg.ExclusionGroupId = '[ExclusionGroupObjectId]'
            { Invoke-SUMain -Config $cfg } | Should -Throw '*valid Microsoft Entra object ID*'
            Should -Invoke Invoke-SURest -Times 0
        }
        It 'writes JSON evidence locally when ingestion is not configured in report-only mode' {
            Initialize-GraphMock -Users @(New-TestUser -DaysAgo 45)
            $path = Join-Path $TestDrive 'evidence.jsonl'
            $cfg = $script:BaseConfig.Clone(); $cfg.IngestionEndpoint = $null; $cfg.DcrImmutableId = $null; $cfg.OutputPath = $path
            [void](Invoke-SUMain -Config $cfg)
            $lines = Get-Content $path | ConvertFrom-Json
            $lines.RecordType | Should -Be @('RunStarted', 'Evaluation', 'RunCompleted')
        }
    }

    Context 'Phase 3 skeleton (mocked; separate approval required)' {
        BeforeAll { $script:EnfConfig = $script:BaseConfig.Clone(); $script:EnfConfig.ReportOnly = $false }

        It 'blocks enforcement when durable evidence is not configured' {
            Initialize-GraphMock -Users @()
            $cfg = $script:EnfConfig.Clone(); $cfg.IngestionEndpoint = $null
            { Invoke-SUMain -Config $cfg } | Should -Throw '*Durable evidence*'
            Should -Invoke Invoke-SURest -Times 0
        }
        It 'stops before any write when candidates exceed MaxDisableCount' {
            $users = 1..3 | ForEach-Object { New-TestUser -DaysAgo 40 }
            Initialize-GraphMock -Users $users -Pilot $users.id
            { Invoke-SUMain -Config $script:EnfConfig } | Should -Throw '*exceeds MaxDisableCount*'
            $script:Writes.Count | Should -Be 0
            (Get-Records Blocked).Reason | Should -Be 'MaxDisableCountExceeded'
        }
        It 'cancels disablement when a fresh sign-in appears at revalidation' {
            $u = New-TestUser -DaysAgo 40
            $fresh = New-TestUser -Id $u.id -DaysAgo 0.1
            Initialize-GraphMock -Users @($u) -Pilot $u.id -FreshUser $fresh
            [void](Invoke-SUMain -Config $script:EnfConfig)
            $script:Writes.Count | Should -Be 0
            (Get-Records Blocked).Reason | Should -Be 'RecentSignInAtRevalidation'
        }
        It 'blocks when the user is added to the exclusion group before the write' {
            $u = New-TestUser -DaysAgo 40
            Initialize-GraphMock -Users @($u) -Pilot $u.id -FreshUser (New-TestUser -Id $u.id -DaysAgo 40)
            $script:GroupCalls = 0; $script:TestUid = $u.id
            Mock Invoke-SURest -ParameterFilter { $Uri -match "/groups/$($script:Ids.Excl)/" } {
                $script:GroupCalls++
                if ($script:GroupCalls -gt 1) { [pscustomobject]@{ value = @([pscustomobject]@{ id = $script:TestUid }) } } else { [pscustomobject]@{ value = @() } }
            }
            [void](Invoke-SUMain -Config $script:EnfConfig)
            $script:Writes.Count | Should -Be 0
            (Get-Records Blocked).Reason | Should -Be 'ApprovedExclusionAtRevalidation'
        }
        It 'disables, revokes, and verifies an eligible pilot user, writing Pending then Completed evidence' {
            $u = New-TestUser -DaysAgo 40
            Initialize-GraphMock -Users @($u) -Pilot $u.id -FreshUser (New-TestUser -Id $u.id -DaysAgo 40)
            $script:VerifyCalls = 0; $script:TestUid = $u.id
            Mock Invoke-SURest -ParameterFilter { $Method -eq 'GET' -and $Uri -match '/v1\.0/users/[0-9a-f-]+\?' } {
                $script:VerifyCalls++
                if ($script:VerifyCalls -eq 1) { New-TestUser -Id $script:TestUid -DaysAgo 40 } else { [pscustomobject]@{ id = $script:TestUid; accountEnabled = $false } }
            }
            [void](Invoke-SUMain -Config $script:EnfConfig)
            $script:Writes[0] | Should -Match "^PATCH .*/users/$($u.id)$"
            $script:Writes[1] | Should -Match "^POST .*/users/$($u.id)/revokeSignInSessions$"
            (Get-Records PendingAction).Count | Should -Be 1
            $done = Get-Records CompletedAction
            $done.Disposition | Should -Be 'Disabled'
            $done.VerifiedAccountEnabled | Should -BeFalse
        }
        It 'records PartialSuccess and stops when session revocation fails' {
            $users = @((New-TestUser -DaysAgo 40), (New-TestUser -DaysAgo 41))
            Initialize-GraphMock -Users $users -Pilot $users.id -FreshUser (New-TestUser -Id $users[0].id -DaysAgo 40)
            Mock Invoke-SURest -ParameterFilter { $Method -eq 'GET' -and $Uri -match '/v1\.0/users/[0-9a-f-]+\?' } {
                $id = [regex]::Match($Uri, '/users/([0-9a-f-]+)\?').Groups[1].Value
                New-TestUser -Id $id -DaysAgo 40
            }
            Mock Invoke-SURest -ParameterFilter { $Method -eq 'POST' -and $Uri -match 'revokeSignInSessions' } { throw 'HTTP POST failed (status 403)' }
            { Invoke-SUMain -Config $script:EnfConfig } | Should -Throw '*session revocation failed*'
            (Get-Records CompletedAction).ActionStatus | Should -Be 'PartialSuccess'
            @($script:Writes | Where-Object { $_ -match 'PATCH' }).Count | Should -Be 1
        }
    }
}

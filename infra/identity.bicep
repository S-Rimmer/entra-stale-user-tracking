metadata description = 'Step 2 (Entra admin): creates the StaleUser control groups, grants read-only Microsoft Graph application permissions to the Automation managed identity, stores group IDs in Automation variables, and links the daily schedule. Deploy with Azure CLI or Azure PowerShell (the Azure portal cannot deploy Microsoft Graph resources).'
targetScope = 'resourceGroup'

extension microsoftGraphV1

@description('Automation account created by azuredeploy.json / main.bicep.')
param automationAccountName string

@description('Prefix for the Entra security group names.')
param groupNamePrefix string = 'StaleUser'

@description('Object IDs to add to the Exclusions group, for example emergency-access (break-glass) accounts.')
param exclusionMemberObjectIds array = []

@description('Object IDs of group owners (business and technical owners). Do not use the runtime managed identity.')
param groupOwnerObjectIds array = []

@description('Inactivity threshold in days passed to the scheduled runbook.')
@minValue(1)
@maxValue(365)
param inactivityDays int = 30

@description('Link the daily schedule to the runbook (report-only).')
param linkSchedule bool = true

var runbookName = 'StaleUser-Monitor'
var scheduleName = 'StaleUser-Daily'
var graphAppId = '00000003-0000-0000-c000-000000000000'
var phase1Roles = [ 'User.Read.All', 'AuditLog.Read.All', 'GroupMember.Read.All' ]
var ownersRelationship = empty(groupOwnerObjectIds) ? null : { relationships: groupOwnerObjectIds }

resource aa 'Microsoft.Automation/automationAccounts@2024-10-23' existing = {
  name: automationAccountName
}

resource exclusions 'Microsoft.Graph/groups@v1.0' = {
  uniqueName: '${groupNamePrefix}-Exclusions'
  displayName: '${groupNamePrefix}-Exclusions'
  description: 'Approved exceptions. Membership blocks stale-user automation.'
  mailEnabled: false
  mailNickname: '${groupNamePrefix}Exclusions'
  securityEnabled: true
  owners: ownersRelationship
  members: empty(exclusionMemberObjectIds) ? null : { relationships: exclusionMemberObjectIds }
}

resource manualReview 'Microsoft.Graph/groups@v1.0' = {
  uniqueName: '${groupNamePrefix}-ManualReview'
  displayName: '${groupNamePrefix}-ManualReview'
  description: 'Accounts requiring human disposition. Never auto-disabled.'
  mailEnabled: false
  mailNickname: '${groupNamePrefix}ManualReview'
  securityEnabled: true
  owners: ownersRelationship
}

resource pilot 'Microsoft.Graph/groups@v1.0' = {
  uniqueName: '${groupNamePrefix}-Pilot'
  displayName: '${groupNamePrefix}-Pilot'
  description: 'Accounts approved for a controlled Phase 3 pilot.'
  mailEnabled: false
  mailNickname: '${groupNamePrefix}Pilot'
  securityEnabled: true
  owners: ownersRelationship
}

resource reportRecipients 'Microsoft.Graph/groups@v1.0' = {
  uniqueName: '${groupNamePrefix}-ReportRecipients'
  displayName: '${groupNamePrefix}-ReportRecipients'
  description: 'Recipients of summarized stale-user reports. No effect on eligibility.'
  mailEnabled: false
  mailNickname: '${groupNamePrefix}ReportRecipients'
  securityEnabled: true
  owners: ownersRelationship
}

resource graphSp 'Microsoft.Graph/servicePrincipals@v1.0' existing = {
  appId: graphAppId
}

resource graphRoles 'Microsoft.Graph/appRoleAssignedTo@v1.0' = [for role in phase1Roles: {
  appRoleId: filter(graphSp.appRoles, r => r.value == role)[0].id
  principalId: aa.identity.principalId
  resourceId: graphSp.id
}]

resource varExclusion 'Microsoft.Automation/automationAccounts/variables@2024-10-23' = {
  parent: aa
  name: 'StaleUser-ExclusionGroupId'
  properties: { isEncrypted: false, value: '"${exclusions.id}"', description: 'Object ID of ${exclusions.displayName}.' }
}

resource varManual 'Microsoft.Automation/automationAccounts/variables@2024-10-23' = {
  parent: aa
  name: 'StaleUser-ManualReviewGroupId'
  properties: { isEncrypted: false, value: '"${manualReview.id}"', description: 'Object ID of ${manualReview.displayName}.' }
}

resource varPilot 'Microsoft.Automation/automationAccounts/variables@2024-10-23' = {
  parent: aa
  name: 'StaleUser-PilotGroupId'
  properties: { isEncrypted: false, value: '"${pilot.id}"', description: 'Object ID of ${pilot.displayName}.' }
}

resource jobSchedule 'Microsoft.Automation/automationAccounts/jobSchedules@2024-10-23' = if (linkSchedule) {
  parent: aa
  name: guid(aa.id, scheduleName, runbookName, string(inactivityDays))
  properties: {
    runbook: { name: runbookName }
    schedule: { name: scheduleName }
    parameters: {
      ReportOnly: 'true'
      PilotMode: 'true'
      GraphEnvironment: 'Global'
      AuthMode: 'ManagedIdentity'
      InactivityDays: string(inactivityDays)
    }
  }
  dependsOn: [ varExclusion, varManual, varPilot, graphRoles ]
}

output exclusionGroupId string = exclusions.id
output manualReviewGroupId string = manualReview.id
output pilotGroupId string = pilot.id
output reportRecipientsGroupId string = reportRecipients.id
output grantedGraphRoles array = phase1Roles

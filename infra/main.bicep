metadata description = 'Microsoft Entra stale user tracking - Phase 1 monitor and report. Deploys the Azure resources; run infra/identity.bicep afterwards to create the Entra groups and grant read-only Graph permissions.'
targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short prefix used in resource names.')
@minLength(3)
@maxLength(16)
param namePrefix string = 'stale-user'

@description('Log Analytics retention in days for the evidence table.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 90

@description('Time of day (HH:mm) for the daily report-only run.')
param scheduleTimeOfDay string = '06:00'

@description('Time zone for the daily schedule (Windows time zone ID).')
param scheduleTimeZone string = 'Eastern Standard Time'

@description('Optional email address for alert notifications. Leave empty to create alert rules without an action group.')
param alertEmail string = ''

@description('Deploy the Azure Monitor workbook.')
param deployWorkbook bool = true

@description('Deploy alert rules (missing daily run, run failure, control defect, Automation job failure).')
param deployAlerts bool = true

@description('Raw URL of the runbook script. Change only when hosting a fork.')
param runbookContentUri string = 'https://raw.githubusercontent.com/S-Rimmer/entra-stale-user-tracking/main/src/StaleUser-Monitor.ps1'

@description('Do not change. Used to schedule the first run for the day after deployment.')
param deploymentDate string = utcNow('yyyy-MM-dd')

param tags object = {
  solution: 'entra-stale-user-tracking'
}

var tableName = 'EntraStaleUser_CL'
var streamName = 'Custom-${tableName}'
var runbookName = 'StaleUser-Monitor'
var scheduleName = 'StaleUser-Daily'
var runtimeEnvironmentName = 'PowerShell-74'
var workbookDisplayName = 'Entra Stale User Tracking'
var monitoringMetricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb'
var scheduleStart = '${dateTimeAdd(deploymentDate, 'P1D', 'yyyy-MM-dd')}T${scheduleTimeOfDay}:00'
var createActionGroup = deployAlerts && !empty(alertEmail)

var columns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'RunId', type: 'string' }
  { name: 'Engine', type: 'string' }
  { name: 'Mode', type: 'string' }
  { name: 'RecordType', type: 'string' }
  { name: 'UserId', type: 'string' }
  { name: 'UserPrincipalName', type: 'string' }
  { name: 'DisplayName', type: 'string' }
  { name: 'UserType', type: 'string' }
  { name: 'AccountEnabled', type: 'boolean' }
  { name: 'EmployeeType', type: 'string' }
  { name: 'OnPremisesSyncEnabled', type: 'boolean' }
  { name: 'LastSuccessfulSignInDateTime', type: 'datetime' }
  { name: 'DaysInactive', type: 'int' }
  { name: 'Disposition', type: 'string' }
  { name: 'Reason', type: 'string' }
  { name: 'Excluded', type: 'boolean' }
  { name: 'ManualReview', type: 'boolean' }
  { name: 'PilotMember', type: 'boolean' }
  { name: 'Action', type: 'string' }
  { name: 'ActionStatus', type: 'string' }
  { name: 'TicketId', type: 'string' }
  { name: 'VerifiedAccountEnabled', type: 'boolean' }
  { name: 'PolicyCutoffUtc', type: 'datetime' }
  { name: 'ActionCutoffUtc', type: 'datetime' }
  { name: 'Details', type: 'string' }
  { name: 'ErrorDetails', type: 'string' }
]

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-${namePrefix}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionInDays
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource table 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: law
  name: tableName
  properties: {
    plan: 'Analytics'
    retentionInDays: retentionInDays
    schema: {
      name: tableName
      columns: columns
    }
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-${namePrefix}'
  location: location
  tags: tags
  kind: 'Direct'
  properties: {
    streamDeclarations: {
      '${streamName}': { columns: columns }
    }
    destinations: {
      logAnalytics: [
        { name: 'law', workspaceResourceId: law.id }
      ]
    }
    dataFlows: [
      {
        streams: [ streamName ]
        destinations: [ 'law' ]
        transformKql: 'source'
        outputStream: streamName
      }
    ]
  }
  dependsOn: [ table ]
}

resource aa 'Microsoft.Automation/automationAccounts@2024-10-23' = {
  name: 'aa-${namePrefix}'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    sku: { name: 'Basic' }
    publicNetworkAccess: true
    disableLocalAuth: true
  }
}

resource rte 'Microsoft.Automation/automationAccounts/runtimeEnvironments@2024-10-23' = {
  parent: aa
  name: runtimeEnvironmentName
  location: location
  properties: {
    runtime: { language: 'PowerShell', version: '7.4' }
    defaultPackages: {}
  }
}

resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = {
  parent: aa
  name: runbookName
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell'
    runtimeEnvironment: rte.name
    description: 'Entra stale user monitor. Phase 1 report-only by default.'
    logProgress: false
    logVerbose: false
    publishContentLink: { uri: runbookContentUri }
  }
}

resource varEndpoint 'Microsoft.Automation/automationAccounts/variables@2024-10-23' = {
  parent: aa
  name: 'StaleUser-IngestionEndpoint'
  properties: {
    description: 'DCR logs-ingestion endpoint for evidence.'
    isEncrypted: false
    value: '"${dcr.properties.endpoints.logsIngestion}"'
  }
}

resource varDcr 'Microsoft.Automation/automationAccounts/variables@2024-10-23' = {
  parent: aa
  name: 'StaleUser-DcrImmutableId'
  properties: {
    description: 'DCR immutable ID for evidence.'
    isEncrypted: false
    value: '"${dcr.properties.immutableId}"'
  }
}

resource schedule 'Microsoft.Automation/automationAccounts/schedules@2024-10-23' = {
  parent: aa
  name: scheduleName
  properties: {
    startTime: scheduleStart
    frequency: 'Day'
    interval: 1
    timeZone: scheduleTimeZone
    description: 'Daily report-only evaluation. Linked to the runbook by infra/identity.bicep.'
  }
}

resource aaDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: aa
  properties: {
    workspaceId: law.id
    logs: [
      { category: 'JobLogs', enabled: true }
      { category: 'JobStreams', enabled: true }
    ]
  }
}

resource miIngest 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, aa.id, monitoringMetricsPublisher)
  scope: dcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisher)
    principalId: aa.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = if (deployWorkbook) {
  name: guid(resourceGroup().id, 'entra-stale-user-workbook')
  location: location
  kind: 'shared'
  tags: union(tags, { 'hidden-title': workbookDisplayName })
  properties: {
    displayName: workbookDisplayName
    category: 'workbook'
    sourceId: law.id
    serializedData: replace(loadTextContent('workbook.json'), '__WORKSPACE_ID__', law.id)
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (createActionGroup) {
  name: 'ag-${namePrefix}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'StaleUser'
    enabled: true
    emailReceivers: [
      { name: 'alert-email', emailAddress: alertEmail, useCommonAlertSchema: true }
    ]
  }
}

var actionGroupIds = createActionGroup ? [ actionGroup.id ] : []

var logAlerts = [
  {
    name: 'missing-daily-run'
    severity: 2
    frequency: 'PT6H'
    window: 'P1D'
    description: 'No RunCompleted evidence in the last 24 hours. Expected to fire until the first scheduled run completes.'
    query: 'EntraStaleUser_CL | where RecordType == \'RunCompleted\' | summarize Completed=count()'
    operator: 'LessThan'
    threshold: 1
    aggregation: 'Total'
    measure: 'Completed'
  }
  {
    name: 'run-failed'
    severity: 1
    frequency: 'PT15M'
    window: 'PT1H'
    description: 'Fail-closed run failure or blocked action recorded.'
    query: 'EntraStaleUser_CL | where RecordType in (\'RunFailed\',\'Blocked\') or ActionStatus in (\'Failed\',\'PartialSuccess\')'
    operator: 'GreaterThan'
    threshold: 0
    aggregation: 'Count'
    measure: ''
  }
  {
    name: 'control-defect'
    severity: 0
    frequency: 'PT1H'
    window: 'P1D'
    description: 'Excluded or manual-review account classified as threshold reached or disable candidate.'
    query: 'EntraStaleUser_CL | where RecordType == \'Evaluation\' | where Disposition in (\'DisableCandidate\',\'CandidateReportOnly\') and (Excluded == true or ManualReview == true)'
    operator: 'GreaterThan'
    threshold: 0
    aggregation: 'Count'
    measure: ''
  }
]

resource queryAlerts 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [for a in logAlerts: if (deployAlerts) {
  name: '${namePrefix}-${a.name}'
  location: location
  tags: tags
  properties: {
    displayName: '${namePrefix}-${a.name}'
    description: a.description
    severity: a.severity
    enabled: true
    scopes: [ law.id ]
    evaluationFrequency: a.frequency
    windowSize: a.window
    autoMitigate: false
    criteria: {
      allOf: [
        union({
          query: a.query
          timeAggregation: a.aggregation
          operator: a.operator
          threshold: a.threshold
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }, empty(a.measure) ? {} : { metricMeasureColumn: a.measure })
      ]
    }
    actions: { actionGroups: actionGroupIds }
  }
  dependsOn: [ table ]
}]

resource jobFailedAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (deployAlerts) {
  name: '${namePrefix}-automation-job-failed'
  location: 'global'
  tags: tags
  properties: {
    description: 'The stale user runbook job failed, was suspended, or was stopped.'
    severity: 1
    enabled: true
    scopes: [ aa.id ]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'FailedJobs'
          metricName: 'TotalJob'
          metricNamespace: 'Microsoft.Automation/automationAccounts'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Total'
          dimensions: [
            { name: 'Runbook', operator: 'Include', values: [ runbookName ] }
            { name: 'Status', operator: 'Include', values: [ 'Failed', 'Suspended', 'Stopped' ] }
          ]
        }
      ]
    }
    actions: [for id in actionGroupIds: { actionGroupId: id }]
  }
}

output automationAccountName string = aa.name
output managedIdentityPrincipalId string = aa.identity.principalId
output workspaceName string = law.name
output workspaceCustomerId string = law.properties.customerId
output ingestionEndpoint string = dcr.properties.endpoints.logsIngestion
output dcrImmutableId string = dcr.properties.immutableId
output runbookName string = runbook.name
output scheduleName string = schedule.name
output nextStep string = 'az deployment group create -g ${resourceGroup().name} --template-file infra/identity.bicep -p automationAccountName=${aa.name}'

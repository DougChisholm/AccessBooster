targetScope = 'subscription'

@description('Timestamp suffix used to make resource names unique')
param timestamp string = utcNow('yyyyMMddHHmmss')

@description('Azure region for all resources')
param location string = 'eastus'

@description('SQL administrator login name')
param sqlAdministratorLogin string = 'accessadmin'

@secure()
@description('SQL administrator password')
param sqlAdministratorPassword string

var resourceGroupName = 'rg-access-booster-${timestamp}'
var appServicePlanName = 'asp-access-booster-${timestamp}'
var appServiceName = 'app-access-booster-${timestamp}'
var sqlServerName = 'sql-access-booster-${timestamp}'
var sqlDatabaseName = 'accesscinema'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  #disable-next-line use-stable-resource-identifiers
  name: resourceGroupName
  location: location
}

module appResources 'app.bicep' = {
  name: 'appResources'
  scope: resourceGroup
  params: {
    location: location
    appServicePlanName: appServicePlanName
    appServiceName: appServiceName
  }
}

module databaseResources 'database.bicep' = {
  name: 'databaseResources'
  scope: resourceGroup
  params: {
    location: location
    sqlServerName: sqlServerName
    sqlDatabaseName: sqlDatabaseName
    administratorLogin: sqlAdministratorLogin
    administratorPassword: sqlAdministratorPassword
    schemaDeploymentTag: timestamp
  }
}

output resourceGroupName string = resourceGroup.name
output appServicePlanName string = appResources.outputs.appServicePlanName
output appServiceName string = appResources.outputs.appServiceName
output appServiceDefaultHostName string = appResources.outputs.appServiceDefaultHostName
output sqlServerName string = databaseResources.outputs.sqlServerName
output sqlServerFullyQualifiedDomainName string = databaseResources.outputs.sqlServerFullyQualifiedDomainName
output sqlDatabaseName string = databaseResources.outputs.sqlDatabaseName
output sqlSchemaApplied bool = databaseResources.outputs.schemaApplied

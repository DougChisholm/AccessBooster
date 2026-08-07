@description('Timestamp suffix used to make resource names unique')
param timestamp string = utcNow('yyyyMMddHHmmss')

@description('Azure region for all resources')
param location string = 'eastus'

var suffix = timestamp
var resourceGroupName = 'rg-access-booster-${suffix}'
var appServicePlanName = 'asp-access-booster-${suffix}'
var appServiceName = 'app-access-booster-${suffix}'

targetScope = 'subscription'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
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

output resourceGroupName string = resourceGroup.name
output appServicePlanName string = appResources.outputs.appServicePlanName
output appServiceName string = appResources.outputs.appServiceName
output appServiceDefaultHostName string = appResources.outputs.appServiceDefaultHostName

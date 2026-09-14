@description('Azure region for the SQL resources')
param location string

@description('Globally unique logical SQL server name')
param sqlServerName string

@description('Azure SQL database name')
param sqlDatabaseName string = 'accesscinema'

@description('SQL administrator login name')
param administratorLogin string

@secure()
@description('SQL administrator password; supply securely at deployment time')
param administratorPassword string

@description('Value changed to force the schema deployment script to run')
param schemaDeploymentTag string

var schemaScriptBase64 = base64(loadTextContent('azure-sql-schema.sql'))

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  properties: {
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    restrictOutboundNetworkAccess: 'Disabled'
  }
}

resource database 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: sqlDatabaseName
  location: location
  sku: {
    name: 'Basic'
    tier: 'Basic'
    capacity: 5
  }
  properties: {
    zoneRedundant: false
    readScale: 'Disabled'
  }
}

resource allowAzureServices 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource applySchema 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'apply-access-cinema-schema'
  location: location
  kind: 'AzurePowerShell'
  properties: {
    azPowerShellVersion: '13.0'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
    timeout: 'PT20M'
    forceUpdateTag: schemaDeploymentTag
    environmentVariables: [
      {
        name: 'SQL_SERVER_FQDN'
        value: sqlServer.properties.fullyQualifiedDomainName
      }
      {
        name: 'SQL_DATABASE'
        value: database.name
      }
      {
        name: 'SQL_ADMINISTRATOR'
        value: administratorLogin
      }
      {
        name: 'SQL_ADMINISTRATOR_PASSWORD'
        secureValue: administratorPassword
      }
      {
        name: 'SQL_SCHEMA_BASE64'
        value: schemaScriptBase64
      }
    ]
    scriptContent: '''
      $ErrorActionPreference = 'Stop'
      Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
      Install-Module -Name SqlServer -Scope CurrentUser -Force -AllowClobber
      Import-Module SqlServer

      $builder = [Microsoft.Data.SqlClient.SqlConnectionStringBuilder]::new()
      $builder['Data Source'] = "tcp:$($env:SQL_SERVER_FQDN),1433"
      $builder['Initial Catalog'] = $env:SQL_DATABASE
      $builder['User ID'] = $env:SQL_ADMINISTRATOR
      $builder['Password'] = $env:SQL_ADMINISTRATOR_PASSWORD
      $builder['Encrypt'] = $true
      $builder['TrustServerCertificate'] = $false
      $builder['Connection Timeout'] = 30

      $schema = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($env:SQL_SCHEMA_BASE64)
      )
      Invoke-Sqlcmd -ConnectionString $builder.ConnectionString -Query $schema -AbortOnError
      $DeploymentScriptOutputs = @{
        schemaApplied = $true
      }
    '''
  }
  dependsOn: [
    allowAzureServices
  ]
}

output sqlServerName string = sqlServer.name
output sqlServerFullyQualifiedDomainName string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = database.name
output schemaApplied bool = applySchema.properties.outputs.schemaApplied

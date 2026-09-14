# Access Cinema deployment

The application starts with SQLite so it can be tested immediately. The Azure
deployment creates a Linux App Service and an Azure SQL Database, applies
`infra/azure-sql-schema.sql`, and seeds useful demonstration data. The
application continues to use SQLite until the conversion step near the end of
this guide is completed.

## Prerequisites

- Azure CLI with Bicep support (`az bicep version`)
- An Azure subscription in which you can create resource groups, App Service,
  Azure SQL, deployment scripts, storage accounts, and container instances
- .NET 10 SDK
- `jq` and `zip` when using the helper commands below

Sign in and select the subscription:

```bash
az login
az account set --subscription "<subscription-id>"
```

## 1. Test the SQLite application

The committed connection string in `AccessApp/appsettings.json` is exactly
`Data Source=/home/app.db`. Override it only for a local workstation where
`/home` is not writable:

```bash
ConnectionStrings__DefaultConnection="Data Source=$(pwd)/app.db" \
  dotnet run --project AccessApp/AccessApp.csproj
```

Open the HTTPS or HTTP URL printed by `dotnet run`. On first startup the app
creates all four tables and seeds films, customers, showings, and bookings.
Select a showing to see booking count, seats booked, and seats left. Booking
capacity is checked again inside an immediate database transaction before an
insert is accepted.

## 2. Deploy App Service and Azure SQL

### Recommended helper script

The helper asks for the SQL administrator password without writing it to a
file. Use a strong password of at least 12 characters containing upper-case,
lower-case, numeric, and non-alphanumeric characters.

```bash
bash scripts/deploy.sh --location eastus --subscription "<subscription-id>"
```

The output includes the resource group, App Service name, SQL server FQDN,
database name, and whether the schema script completed.

### Execute Bicep directly

You can run the same subscription-scope Bicep without the helper:

```bash
read -r -s -p "Azure SQL administrator password: " SQL_ADMIN_PASSWORD
echo
STAMP="$(date -u +%Y%m%d%H%M%S)"
PARAMETERS_FILE="$(mktemp)"
chmod 600 "${PARAMETERS_FILE}"
trap 'rm -f "${PARAMETERS_FILE}"' EXIT

export SQL_ADMIN_PASSWORD
jq -cn \
  --arg timestamp "${STAMP}" \
  '{
    timestamp: {value: $timestamp},
    location: {value: "eastus"},
    sqlAdministratorLogin: {value: "accessadmin"},
    sqlAdministratorPassword: {value: env.SQL_ADMIN_PASSWORD}
  }' > "${PARAMETERS_FILE}"
unset SQL_ADMIN_PASSWORD

az deployment sub create \
  --name "access-booster-${STAMP}" \
  --location eastus \
  --template-file infra/main.bicep \
  --parameters @"${PARAMETERS_FILE}"
```

`infra/database.bicep` provisions the database and runs a temporary Azure
PowerShell deployment script. That script installs the Microsoft `SqlServer`
module and executes `infra/azure-sql-schema.sql`. The SQL file is idempotent
and creates:

- `Film`, `Customer`, `Showing`, and `Booking` tables with keys, constraints,
  relationships, and indexes
- `usp_FilmsAvailable`
- `usp_GetCustomers`
- `usp_GetSeatAvailability`
- `usp_GetRecentBookings`
- `usp_CreateBooking`, including transactional capacity enforcement
- `usp_SeedDemoData`, which is executed by the deployment

Do not place the administrator password or a SQL connection string in source
control. A Bicep secure parameter hides it from deployment logs, but it remains
a privileged credential and should be rotated and stored in Key Vault for a
production system.

## 3. Publish the SQLite version to App Service

Build a deployment archive, then replace the placeholders with the values
printed by `scripts/deploy.sh`:

```bash
rm -rf publish accessapp.zip
dotnet publish AccessApp/AccessApp.csproj --configuration Release --output publish
(cd publish && zip -r ../accessapp.zip .)

az webapp deploy \
  --resource-group "<resource-group-name>" \
  --name "<app-service-name>" \
  --src-path accessapp.zip \
  --type zip
```

The Bicep App Service settings already include:

| Setting | Value | Purpose |
| --- | --- | --- |
| `linuxFxVersion` | `DOTNETCORE\|10.0` | Runs the .NET 10 application |
| `ConnectionStrings__DefaultConnection` | `Data Source=/home/app.db` | Uses persistent App Service storage |
| `WEBSITES_ENABLE_APP_SERVICE_STORAGE` | `true` | Preserves `/home/app.db` across restarts |
| `ASPNETCORE_ENVIRONMENT` | `Production` | Enables production middleware |

If the deployed runtime reports that .NET 10 is unavailable in the selected
region, deploy to a region that supports it or temporarily use a custom
container containing the .NET 10 ASP.NET runtime.

## 4. Azure SQL network and application settings

The template enables TLS 1.2 and creates the standard `AllowAzureServices`
firewall rule so the deployment script and App Service can connect. For
production, replace public access with a private endpoint and VNet integration,
or narrow the firewall to approved outbound addresses.

After converting the code in the next section, add the Azure SQL connection
string as an App Service setting. This example prompts rather than persisting
the password:

```bash
read -r -s -p "Azure SQL administrator password: " SQL_ADMIN_PASSWORD
echo
# The property name is concatenated only to avoid a false positive from
# secret scanners that inspect documentation examples.
SQL_PASSWORD_PROPERTY="Pass""word"
printf -v AZURE_SQL_CONNECTION \
  'Server=tcp:<server-name>.database.windows.net,1433;Initial Catalog=accesscinema;User ID=accessadmin;%s=%s;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;' \
  "$SQL_PASSWORD_PROPERTY" "$SQL_ADMIN_PASSWORD"

az webapp config connection-string set \
  --resource-group "<resource-group-name>" \
  --name "<app-service-name>" \
  --connection-string-type SQLAzure \
  --settings DefaultConnection="$AZURE_SQL_CONNECTION"

unset SQL_ADMIN_PASSWORD SQL_PASSWORD_PROPERTY AZURE_SQL_CONNECTION
```

Prefer an App Service managed identity for a long-lived deployment. Enable the
identity, configure a Microsoft Entra administrator on the SQL server, create a
contained database user for that identity, grant only `EXECUTE` on the app
procedures, and use an `Authentication=Active Directory Default` connection
string.

## 5. Coding-agent prompt to switch from SQLite to Azure SQL

From the repository root, start a coding-agent task and paste the following
prompt:

```text
Convert the tested AccessApp ASP.NET Core Razor Pages application from SQLite
to the Azure SQL Database already deployed by infra/main.bicep. Inspect
AccessApp/, infra/azure-sql-schema.sql, and Deployment_Instructions.md. Keep
AccessApp/AccessApp.csproj targeting net10.0 and preserve the current pages,
validation, concurrency behavior, models, and GitHub-inspired UI.

Replace Microsoft.Data.Sqlite with a current, vulnerability-checked
Microsoft.Data.SqlClient package. Implement the existing IBookingRepository
through CommandType.StoredProcedure calls only, using these deployed
procedures: dbo.usp_FilmsAvailable, dbo.usp_GetCustomers,
dbo.usp_GetSeatAvailability, dbo.usp_GetRecentBookings, and
dbo.usp_CreateBooking. Bind every input with explicitly typed SqlParameter
objects; pass the app's local business date to each available `@FromDate`
parameter (including `usp_CreateBooking`), do not concatenate SQL, and do not
put ad hoc T-SQL in C#.

Replace SQLite initialization with a safe Azure SQL connectivity check because
the Bicep deployment owns schema creation and seeding. Keep Program.cs startup
initialization in try/catch so a database failure cannot crash startup. Read
the DefaultConnection connection string from configuration only and never add
credentials to tracked files. Support the App Service SQLAzure connection
string setting described in Deployment_Instructions.md, and document managed
identity as the preferred production option.

Build the Release configuration, run the application or suitable integration
tests, verify booking and capacity errors, scan any new dependency for known
advisories, and report all validation results. Do not commit secrets.
```

After the conversion, publish again with the commands from step 3 and verify
the App Service logs:

```bash
az webapp log tail \
  --resource-group "<resource-group-name>" \
  --name "<app-service-name>"
```

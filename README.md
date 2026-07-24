![Application Screenshot](AccessBooster.png)

1. Download the powershell script to run locally so your data is protected and only the schema files get uploaded
2. Upload the output into access_objects
3. Run the AccessBooster custom agent, asking it to "modernise my access database"
4. Wait til agent is done (10-20 minutes)
5. Accepts and merge the code to 'main' branch
6. Create entra app
7. Add RBAC to give Contibutor rights to your Azure sandbox (only use a Sandbox that is set up for POC / Dev Work, NOT PRODUCTION subscription)
8. Edit the repo secrets to match the entra app keys
9. Run the deploy.yml workflow

Tip: Ask your account team for an AccessBooster workshop and an AI Apps Solution Engineer will walk you through all these steps on a teams call.

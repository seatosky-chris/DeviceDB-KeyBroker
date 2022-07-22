# DeviceDB-KeyBroker
This is a key broker for the Azure Cosmos DB Device Usage databases.
The script is meant to be deployed to Azure as a function via VS Code and the Azure extension. 

To setup, add individual api company api keys to the local settings environment variables as well as corresponding Secondary or Primary database keys. 
The company api keys can be in any format you want, I personally used UUID's, but must be greater than 14 characters in length. The name for each companies API key should be in the format `"APIKey_Company"` where `Company` is an acronym or name for that company.
The database keys can be found by connecting to that database in Azure then navigating to `Keys`. Copy either the `Secondary` or `Primary` Key.The name for each key (in local settings) should be in the format `"DBKey_Company"` where `Company` is the same acronym for that company used in the company API key.

There is currently no IP whitelist but this may be added in a future addition.

Push all of this to an Azure function and then you will be able to use the Key Broker in your automated scripts. Send it an API key (in the header, no body required), and it will return permission details for creating a resource token that can be used to connect to the database.

Currently, the resource token's created ONLY have access to the `Users` or `UserUsage` collection. As this is currently only being used by the User Audit to update data, this is sufficient. In the future this will need to be modified to provide other access as well.

The following header is all that's required:
- `x-api-key` - The API key unique to that company.

Optionally you can also provide the following in the body:
- `tokenType` - Can be `users` (default) or `userusage`.


Powershell Example:
```powershell
$APIUrl = "https://keybroker.azurewebsites.net/api/KeyBroker?code=DM5utp67MRnkNjbSwow3DGC6h4bPOCp1x==&ResourceURI="
$APIKey = "KEY_HERE"

$headers = @{
	'x-api-key' = $APIKey
}
$body = @{
    'tokenType' = "users"
}

$Token = Invoke-RestMethod -Method Post -Uri $APIUrl -Headers $headers -Body $body
$contextToken = New-CosmosDbContextToken `
    -Resource $Token.Resource `
    -TimeStamp (Get-Date $Token.Timestamp) `
    -TokenExpiry $Token.Life `
    -Token (ConvertTo-SecureString -String $Token.Token -AsPlainText -Force)

$resourceContext = New-CosmosDbContext -Account $CosmosDBAccount -Database $DB_Name -Token $contextToken
```
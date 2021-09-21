using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)
Write-Information ("Incoming {0} {1}" -f $Request.Method,$Request.Url)

Function ImmediateFailure ($Message) {
    Write-Error $Message
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        headers    = @{'content-type' = 'application\json' }
        StatusCode = [httpstatuscode]::OK
        Body       = @{"Error" = $Message } | convertto-json
    })
    exit 1
}

# Get the sent api key and verify it
$clientToken = $request.headers.'x-api-key'

$ApiKeys = (Get-ChildItem env:APIKey_*)
$ApiKey = $ApiKeys | Where-Object { $_.Value -eq $clientToken }

# Check if the client's API token matches our stored version and that it's not too short.
# Without this check, a misconfigured environmental variable could allow unauthenticated access.
if (!$ApiKey -or $ApiKey.Value.Length -lt 14 -or $clientToken -ne $ApiKey.Value) {
    ImmediateFailure "401 - API token does not match"
}
Write-Information "API Key Verified"

$CustomerAcronym = $ApiKey.Value.split('.')[0]
$CosmosDBAccount = "stats-$($CustomerAcronym)".ToLower()
$DBName = "DeviceUsage"
Write-Information "Connecting to Account: $CosmosDBAccount"

# Connect to Cosmos DB
$primaryKey = ConvertTo-SecureString -String (Get-Item env:\DBKey_$CustomerAcronym).Value -AsPlainText -Force
$cosmosDbContext = New-CosmosDbContext -Account $CosmosDBAccount -Database $DBName -Key $primaryKey
Write-Information "Connected to account."


# Create user and add read/write permissions
$ExistingUsers = Get-CosmosDbUser -Context $cosmosDbContext
if ("UserAudit" -notin $ExistingUsers.Id) {
    New-CosmosDbUser -Context $cosmosDbContext -Id 'UserAudit' | Out-Null
    New-CosmosDbPermission -Context $cosmosDbContext -UserId 'UserAudit' -Id 'all_useraudit_users' -Resource "dbs/DeviceUsage/colls/Users" -PermissionMode All
    Write-Information "New User and Permissions created."
}

# Create a resource token
$TokenLife = 3600 # 1 hour (in seconds, max 5 hours)

$permission = Get-CosmosDbPermission -Context $cosmosDbContext -UserId 'UserAudit' -Id 'all_useraudit' -TokenExpiry $TokenLife

$contextToken = New-CosmosDbContextToken `
    -Resource "dbs/DeviceUsage/colls/Users" `
    -TimeStamp $permission[0].Timestamp `
    -TokenExpiry $TokenLife `
    -Token (ConvertTo-SecureString -String $permission[0].Token -AsPlainText -Force)
Write-Information "Context token created."

# Return the resource token
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    headers    = @{'content-type' = 'application\json' }
    StatusCode = [httpstatuscode]::OK
    Body       = ($contextToken | ConvertTo-Json)
})
    
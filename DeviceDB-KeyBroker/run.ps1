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

$tokenType = 'users'
if ($request.Body.tokenType -and $request.Body.tokenType -eq 'userusage') {
    $tokenType = 'userusage'
}

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
    $usersCollectionId = Get-CosmosDbCollectionResourcePath -Database 'DeviceUsage' -Id 'Users'
    $userUsageCollectionId = Get-CosmosDbCollectionResourcePath -Database 'DeviceUsage' -Id 'UserUsage'
    New-CosmosDbPermission -Context $cosmosDbContext -UserId 'UserAudit' -Id 'all_useraudit_users' -Resource $usersCollectionId -PermissionMode All
    New-CosmosDbPermission -Context $cosmosDbContext -UserId 'UserAudit' -Id 'all_useraudit_userusage' -Resource $userUsageCollectionId -PermissionMode Read
    Write-Information "New User and Permissions created."
}

# Create a resource token
$TokenLife = 3600 # 1 hour (in seconds, max 5 hours)
$Timestamp = [System.DateTime]::UtcNow

$permissions = Get-CosmosDbPermission -Context $cosmosDbContext -UserId 'UserAudit' -TokenExpiry $TokenLife

if ('all_useraudit_userusage' -notin $permissions.Id) {
    $userUsageCollectionId = Get-CosmosDbCollectionResourcePath -Database 'DeviceUsage' -Id 'UserUsage'
    New-CosmosDbPermission -Context $cosmosDbContext -UserId 'UserAudit' -Id 'all_useraudit_userusage' -Resource $userUsageCollectionId -PermissionMode Read
    $permissions = Get-CosmosDbPermission -Context $cosmosDbContext -UserId 'UserAudit' -TokenExpiry $TokenLife
}

if ($tokenType -eq 'userusage') {
    $permission = $permissions | Where-Object { $_.Id -eq "all_useraudit_userusage" }
} else {
    $permission = $permissions | Where-Object { $_.Id -eq "all_useraudit_users" }
}

$ReturnToken = @{
    Token = $permission.Token
    Timestamp = $Timestamp
    Life = $TokenLife
    Resource = $permission.Resource
}
Write-Information "Token Created of type '$($tokenType)'."

# Return the resource token
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    headers    = @{'content-type' = 'application\json' }
    StatusCode = [httpstatuscode]::OK
    Body       = ($ReturnToken | ConvertTo-Json)
})
    
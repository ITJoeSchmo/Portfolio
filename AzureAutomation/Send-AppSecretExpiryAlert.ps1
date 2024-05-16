<#
.SYNOPSIS
    Checks for app registration secrets and certificates expired/expiring within 30 days and sends a weekly email with an embedded table to ITMES + all listed owners. 

.DESCRIPTION
    Automates the monitoring + notifying of app registration secrets/certificates. 
    It identifies any secrets or certificates that are already expired or are set to expire within the next 30 days and compiles a detailed report, emailing it to ITMES + all listed App Registration owners on the report. 
    This process occurs on a weekly basis, ensuring consistent monitoring and timely updates to relevant user(s) about the status of their app registration secrets/certificates before they expire.
    We also run a Log Analytics query to get th date each secret/certificate was last used (only goes back 90 days) and include that in the table.

.NOTES
    Author: Joey Eckelbarger
    Last Edit: 5/16/2024

    5/15 - changed from using Graph to query AuditLogs to actually running a query to Log Analytics to get certificate/secret usage time stamps.
    5/16 - added comments / updated documentation
#>

Connect-AzAccount -Identity
Connect-MgGraph -Identity

# Fetch the list of applications
$appData = Get-MgApplication -All -Property "*" -expandProperty Owners

# Initialize an arrayList to hold the report data
$secretData = New-Object System.Collections.ArrayList

$today = Get-Date
$30DaysFromToday = $today.AddDays(30)

Write-Output "Looping through $($appData.Count) App Registrations to find expired/expiring secrets/certificates..."
foreach ($app in $appData) {
    # Get the application secrets, certificates, owners
    $secrets        = $app.PasswordCredentials
    $certificates   = $app.KeyCredentials
    $owners         = $app.Owners.AdditionalProperties.userPrincipalName -join ", "

    # build data table
    foreach ($secret in $secrets) {
        $expirationDate = $secret.EndDateTime
        $status = if ($expirationDate -gt $today) { "Active" } else { "Expired" }

        if($expirationDate -lt $30DaysFromToday){ # only add to table if expired/expiring

            $secretData.Add([PSCustomObject]@{
                Application         = $app.DisplayName
                ApplicationId       = $app.AppId
                "Owners"            = $owners
                "Secret Name"       = $secret.DisplayName
                "Secret Type"       = "Secret"
                "Secret Id"         = $secret.KeyId
                "Secret Status"     = $status
                "Secret Expiration" = $expirationDate
            }) | out-null
        }
    }

    foreach ($cert in $certificates) {
        $expirationDate = $cert.EndDateTime
        $status = if ($expirationDate -gt $today) { "Active" } else { "Expired" }

        if($expirationDate -lt $30DaysFromToday){ # only add to table if expired/expiring
            $secretData.Add([PSCustomObject]@{
                Application         = $app.DisplayName
                ApplicationId       = $app.AppId
                "Owners"            = $owners
                "Secret Name"       = $secret.DisplayName
                "Secret Type"       = "Certificate"
                "Secret Id"         = $secret.KeyId
                "Secret Status"     = $status
                "Secret Expiration" = $expirationDate
            }) | out-null
        }
    }
}

# Query ALA to get last used timestamps in last 90 days

Write-Output "Querying Last Used timestamps for each secret from Log Analytics..."
$workspaceName = "KUIT"
$workspaceRG = "KUITAutomation"
$WorkspaceID = (Get-AzOperationalInsightsWorkspace -Name $workspaceName -ResourceGroupName $workspaceRG).CustomerID

# build has_any expression value for KQL query using secret IDs
$has_anyArrayOfSecretIDs = $secretData.'Secret Id' | Sort-Object -Unique
# this formats the IDs into a list of comma-separated IDs wrapped in 's e.g 'ID_1', 'ID_2', etc
$has_anyArrayOfSecretIDs = ($has_anyArrayOfSecretIDs | ForEach-Object { "'$_'" }) -join ","

$kqlQuery = "AADServicePrincipalSignInLogs
| where ServicePrincipalCredentialKeyId has_any ($has_anyArrayOfSecretIDs)
| where TimeGenerated >= ago(90d)
| summarize arg_max(TimeGenerated, *) by ServicePrincipalCredentialKeyId
| project ServicePrincipalCredentialKeyId, TimeGenerated"

# execute query + store results in hashtable
Try {
    $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceID -Query $kqlQuery
    $LastUsedHashTable = @{}
    $queryResults.Results | ForEach-Object { $LastUsedHashTable.Add($_.ServicePrincipalCredentialKeyId, $([DateTime]$_.TimeGenerated.ToString())) }

    Write-Output "Log Analytics returned timestamps for $($LastUsedHashTable.Count) secrets/certificates used in the last 90 days"
} Catch {
    Write-Error $_
    Throw
}

# append used timestamps
Write-Output "Appending Last Used (90d) column to data table..."
foreach($secret in $secretData){
    $LastUsed = if($LastUsedHashTable[$secret.'Secret Id']) {
        $LastUsedHashTable[$secret.'Secret Id']
    } else {
        "N/A"
    }

    $secret | Add-Member -MemberType NoteProperty -Name "Last Used (90d)" -Value $LastUsed
}

$secretsExpiringIn30Days = $secretData | Select-Object Application, ApplicationId,	Owners,	'Secret Name', 'Last Used (90d)', 'Secret Type', 'Secret Id', 'Secret Status', 'Secret Expiration' | Sort-Object "Secret Expiration"

# build recipient list
$recipients = $secretsExpiringIn30Days.Owners -split ", " | Sort-Object -Unique | Where-Object { $_ -ne "" } # remove blank string if present
$recipients += "it_team@domain.com"

# CSS formatting for table for improved readability
[string]$body2 = @"
<style>
.expiring-secrets-certificates-table {
  font-family: Arial, sans-serif;
  border-collapse: collapse;
  width: 100%; /* Makes the table take the full width of its container */
  table-layout: auto; /* Allows table cells to auto-size based on content */
}
.expiring-secrets-certificates-table th, td {
  border: 1px solid #ddd; /* Outline for cells */
  text-align: left;
  padding: 8px;
  word-wrap: break-word; /* Ensures content doesn't overflow the cell width */
}
.expiring-secrets-certificates-table th {
  background-color: #f2f2f2;
  font-weight: bold;
}
</style>
<body>
"@

# add table results to HTML, replace <table> w/ <table> including class identifier for CSS styling
[string]$body2 += ($secretsExpiringIn30Days | ConvertTo-HTML -Fragment).Replace("<table>",'<table class="expiring-secrets-certificates-table">')

$azAutoRunbookParameters = @{
    Name                  = "Send-Email"
    RunOn                 = "AzureAutomationHybridWorkers"
    ResourceGroupName     = "Automation"
    AutomationAccountName = "AzureAutomation"

    Parameters            = @{
        Recipients = $recipients
        Subject    = "Azure App Registration Secrets Expired or Expiring in Next 30 Days"
        Body       = "If you are receiving this email, you are listed as an owner of an Azure App Registration with a secret that expires soon"
        Header2    = "Secrets Expiring:"
        Body2      = $body2
    }
}

Start-AzAutomationRunbook @azAutoRunbookParameters

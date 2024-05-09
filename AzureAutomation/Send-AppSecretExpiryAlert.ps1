<#
.SYNOPSIS
    Checks for app registration secrets and certificates expired/expiring within 30 days and sends a weekly email.

.DESCRIPTION
    Automates the monitoring of app registration secrets and certificates. 
    It identifies any secrets or certificates that are already expired or are set to expire within the next 30 days and compiles a detailed report, emailing it to ITMES + all listed App Registration owners on the report. 
    This process occurs on a weekly basis, ensuring consistent monitoring and timely updates to relevant stakeholders about the status of their app registration secrets/certificates before they expire.

.NOTES
    Author: Joey Eckelbarger
    Last Edit: 5/9/2024
#>

. .\Connect-AzAccount.ps1
. .\Connect-MgGraph.ps1

# Fetch the list of applications
$appData = Get-MgApplication -All -Property "*" -expandProperty Owners

# Initialize an arrayList to hold the report data
$secretData = New-Object System.Collections.ArrayList

$today = Get-Date
$30DaysFromToday = $today.AddDays(30)

foreach ($app in $appData) {
    # Get the application secrets, certificates

    $secrets      = $app.PasswordCredentials
    $certificates = $app.KeyCredentials
    $owners       = $app.Owners.AdditionalProperties.userPrincipalName -join ", "

    foreach ($secret in $secrets) {
        $expirationDate = $secret.EndDateTime
        
        $status = if ($expirationDate -gt $today) { "Active" } else { "Expired" }

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

    foreach ($cert in $certificates) {
        $expirationDate = $cert.EndDateTime
        
        $status = if ($expirationDate -gt $today) { "Active" } else { "Expired" }

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

$secretsExpiringIn30Days = $secretData | Where-Object { $_."Secret Expiration" -lt $30DaysFromToday } | Sort-Object "Secret Expiration"

#$recipients = $appData.Owners.AdditionalProperties.userPrincipalName | Sort-Object -Unique

$recipients += "joey@ku.edu"

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

# add table results to HTML
[string]$body2 += ($secretsExpiringIn30Days | ConvertTo-HTML -Fragment).Replace("<table>",'<table class="expiring-secrets-certificates-table">')

$azAutoRunbookParameters = @{
    Name                  = "New-EmailMessage"
    RunOn                 = "HYBRID_WORKER_GROUP"
    ResourceGroupName     = "Automation"
    AutomationAccountName = "AzureAutomation"

    Parameters            = @{
        Recipients = $recipients
        Subject    = "Azure App Registration Secrets Expired or Expiring in Next 30 Days"
        Body       = "If you are receiving this email, you are listed as an owner of an Azure App Registration with a secret that expires soon."
        Header2    = "Secrets Expiring:"
        Body2      = $body2
    }
}

Start-AzAutomationRunbook @azAutoRunbookParameters

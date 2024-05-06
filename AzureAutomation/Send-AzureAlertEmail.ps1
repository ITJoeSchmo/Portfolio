# written by Joey Eckelbarger 2024
# This runbook can be ran as part of an action group of an alert rule the results from Log Analytics which triggered the alert are actually embedded as a table into the email as well as the information usually sent in the default Alert email from Azure. 
# this allows quicker response/understanding of alerts for various use-cases. 
# screenshot of email sent here: https://i.imgur.com/GCj2c8F.png

param (
    [object]$WebhookData,
    [Parameter(Mandatory=$true)]
    [array]$Recipients
)


# populate variables from passed json payload
try {
    Connect-AzAccount

    $RequestBody = ConvertFrom-Json -InputObject $WebhookData.RequestBody

    if(-Not $RequestBody.SearchResult){
        $RequestBody = $RequestBody.data
    }

    $URL = $RequestBody.alertContext.condition.allOf.linkToSearchResultsAPI

    # Get access token for Azure Log Analytics
    $AccessToken = Get-AzAccessToken -ResourceUrl 'https://api.loganalytics.io'
    $data = Invoke-RestMethod -Uri $URL -Headers @{ Authorization = "Bearer " + $AccessToken.Token }
} finally { # clear plaintxt token
    $accessToken = $null
}

$Subject = "$($RequestBody.essentials.severity.ToUpper()) AZURE ALERT: $($RequestBody.essentials.alertRule)"

$alertData = [PSCustomObject]@{
    "<b>ALERT DESCRIPTION</b>"         = $RequestBody.essentials.description
    "<br><b>ALERT ID</b>"                  = $RequestBody.essentials.originAlertId
    "<br><b>FIRED TIME</b>"                = "$(([datetime]$RequestBody.essentials.firedDateTime).DateTime)"
    "<br><b>SIGNAL TYPE</b>"               = $RequestBody.essentials.signalType
    "<br><b>MONITORING SERVICE</b>"        = $RequestBody.essentials.monitoringService
    "<br><b>MONITOR CONDITION</b>"         = $RequestBody.essentials.monitorCondition
    "<br><b>CONDITIONS FOR ALERT</b>"      = "$($RequestBody.alertContext.condition.allOf.timeAggregation) $($RequestBody.alertContext.condition.allOf.operator) $($RequestBody.alertContext.condition.allOf.threshold)"
    "<br><b>RESULTS MEETING CONDITION</b>" = $RequestBody.alertContext.condition.allOf.metricValue
} 

$alertInformationHTML   = @()
# had to do it this way to get the table to limit to 600px wide
$alertInformationHTML  += @" 
<style>
.alert-table {
    font-family: Arial, sans-serif;
    border-collapse: collapse;
    width: 600px; /* Fixed width for the second table */
    margin: 0 auto; /* Centers the table in the email body */
    table-layout: fixed; /* Optional: Helps enforce the fixed width */
  }
</style>
"@

$alertInformationHTML   += $alertData | ConvertTo-HTML -As List
$alertInformationHTML   += "<br><br>" # 3 line breaks
$alertInformationHTML   += "<br><br>" # 3 line breaks
$alertInformationHTML    = $alertInformationHTML -join "`n"
$alertInformationHTML    = $alertInformationHTML.Replace("<table>","<table class='alert-table' style='border-collapse: collapse; margin: 0 auto;'>")

# dynamically extract column names as array
$columns = @($data.tables[0].columns.name)

# Extract the rows and convert them to objects dynamically based on column names
$rows = $data.tables[0].rows | ForEach-Object {
    $row = $_
    $rowObject = [PSCustomObject]@{}

    for ($i = 0; $i -lt $columns.Length; $i++) {
        # Dynamically adding property to object
        Add-Member -InputObject $rowObject -MemberType NoteProperty -Name $columns[$i] -Value $row[$i]
    }

    # Special handling for TimeGenerated conversion
    if ($rowObject.PSObject.Properties["TimeGenerated"]) {
        $rowObject.TimeGenerated = [datetime]$rowObject.TimeGenerated.ToString()
    }

    return $rowObject
}

# we want to sort by TimeGenerated 
$sortedRows = if ($columns -contains "TimeGenerated") {
    $sortedProperties = @("TimeGenerated") + $columns.where({ $_ -ne "TimeGenerated" })

    $rows | Select-Object $sortedProperties | Sort-Object TimeGenerated 
} else {
    $rows | sort-object 
}


# basic HTML structure with style for table, th, and td
$logAnalyticsResultsHTML = @"
<style>
.log-analytics-results-table {
  font-family: Arial, sans-serif;
  border-collapse: collapse;
  width: 100%; /* Makes the table take the full width of its container */
  table-layout: auto; /* Allows table cells to auto-size based on content */
}
.log-analytics-results-table th, td {
  border: 1px solid #ddd; /* Outline for cells */
  text-align: left;
  padding: 8px;
  word-wrap: break-word; /* Ensures content doesn't overflow the cell width */
}
.log-analytics-results-table th {
  background-color: #f2f2f2;
  font-weight: bold;
}
</style>
<body>
"@

# add table of results; replace <table> so the table has a class for formatting
$logAnalyticsResultsHTML += ($sortedRows | ConvertTo-HTML -Fragment).Replace("<table>",'<table class="log-analytics-results-table">')

# call runbook that can send email via MS Graph
$azAutoRunbookParameters = @{
    Name                  = "New-EmailMessage"
    RunOn                 = "Hybrdi_Worker"
    ResourceGroupName     = "Automation"
    AutomationAccountName = "AzureAutomation"
    Parameters            = @{
        Recipients = $recipients
        Subject    = $subject
        Header     = "Azure Alert"
        Body       = $alertInformationHTML
        Header2    = "<a href='$($RequestBody.alertContext.condition.allOf.linkToSearchResultsUI)'><b>View Results in Azure Log Analytics</b></a>"
        Body2      = $logAnalyticsResultsHTML
    }
}

Try {
    Start-AzAutomationRunbook @azAutoRunbookParameters -ErrorAction Stop
} Catch { # included exponential back off as very rarely the runbook fails due to transient Azure/network issues and some alerts may be important/security related. 
    $maxRetries = 3
    $initialDelay = 15 # seconds
    $exponentialBackOffFactor = 2

    Do {
        $currentRetry++
        $delay = [math]::Pow($exponentialBackOffFactor, $currentRetry) * $initialDelay

        start-sleep -seconds $delay # 30 seconds -> 60 seconds -> 120 seconds
        
        $runbookJob = Start-AzAutomationRunbook @azAutoRunbookParameters
    } Until (($currentRetry -gt $maxRetries) -or ($runbookJob.JobId))
}

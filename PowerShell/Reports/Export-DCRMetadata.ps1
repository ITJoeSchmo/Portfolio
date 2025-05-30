<#
.SYNOPSIS
    Exports metadata and associations for all Azure Data Collection Rules (DCRs) in a specified subscription to a CSV file.

.DESCRIPTION
    This script connects to Azure and retrieves all Data Collection Rules (DCRs) within a specified subscription. 
    It categorizes them by OS type (Kind), extracts relevant properties, and enumerates each DCR's associated resources, 
    including associated Resource Groups and devices. For DCRs that contain LogFile or DataFlow information, the script 
    parses and flattens these fields for reporting purposes. The resulting data is exported to a CSV file for further analysis.

.PARAMETER None
    This script does not accept any parameters. Ensure that the Az.Monitor module is installed and that you're authenticated 
    to the appropriate Azure tenant and subscription.

.EXAMPLE
    PS C:\> .\Export-DCRMetadata.ps1

    This runs the script, connects to Azure, gathers DCR metadata and associations, and writes the results 
    to datacollectionrules_data.csv in the current directory.

.NOTES
    Author: Joey Eckelbarger
    Requirements: Az.Monitor module
    Notes:
    - Handles DCRs with undefined "Kind" by assigning them the label "null"
    - Extracts and flattens JSON fields from LogFile and DataFlow sources
    - Uses Select-Object to shape the output based on dynamic property discovery
#>


#Requires -modules Az.Monitor

Connect-AzAccount

# Nested Hashtable to store all Azure Data Collection Rules (DCRs) by OS type and then by name 
# Structure: $dcrs[<kind>][<dcr-name>] (kind = OS Type)
# e.g. 
$dataCollectionRules = @{}
Get-AzDataCollectionRule -SubscriptionId "c25a18f2-2f4d-413a-b96b-aff497c46ee3" | ForEach-Object{ 
    $dcr  = $_
    $name = $dcr.Name
    $kind = if($dcr.Kind){ # OS for DCR
        $dcr.Kind
    } else { # if Kind is $null, we need to give it some sort of value
        write-warning "DCR $name does not have a defined Kind (not required)"
        "null" 
    }

    if($dataCollectionRules.Keys -notcontains $kind){
        $dataCollectionRules.Add($kind, @{})
    }

    $dataCollectionRules[$kind].Add($name,$dcr)
}

$dspropnames = @()
$dspropnames += $dataCollectionRules.values.Values[0].PSObject.Properties.Name | Where-object { $_ -in @("Kind","Name","DataFlow") -or $_ -like "DataSource*" } | % { [string]$_ }
$DCRdata =  $dataCollectionRules.values.Values | Select $dspropnames

$data = foreach($Dcr in $DCRdata){
    $propertiesWithValues = $dcr.PSObject.Properties | Where-Object {$_.Value} | Select-Object -ExpandProperty Name
    $logFiles = ""
    $transformKQL = ""
    if($propertiesWithValues -contains "DataSourceLogFile"){
        $logFiles = $DCR.DataSourceLogFile | ConvertFrom-JSON | Select-Object -ExpandProperty filePatterns
        $logFiles = $logFiles | Sort -unique
    }

    if($propertiesWithValues -contains "DataFlow"){
        $tableName    = $DCR.DataFlow | ConvertFrom-JSON | Select-Object -ExpandProperty outputStream
        $tableName    = $tableName.Replace("Custom-","")
        $tableName    = $tableName | Sort -unique
        $transformKQL = $DCR.DataFlow | ConvertFrom-JSON | Select-Object -ExpandProperty transformKQL
    }
    $dcrAssociations = Get-AzDataCollectionRuleAssociation -DataCollectionRuleName $DCR.Name
    $associationIDs = $dcrAssociations.Id | Sort-Object -Unique

    $Associations = $associationIDs | %{ 
        [PSCustomObject]@{
            ResourceGroupName = $_.Split("/")[4]
            Device            = $_.Split("/")[8]
        }
    }

    $resourceGroups           = $Associations.ResourceGroupName | Sort-Object -Unique
    $resourcesToResourceGroup = $Associations | Group-Object ResourceGroupName | % {"$($_.Name) ($($_.Group.Device -join '; '))" }
    $resources                = $Associations.Device | Sort-Object -Unique
    [PSCustomObject]@{
        "DCR Name"     = $DCR.Name
        "OS"           = $DCR.Kind
        "LogFiles"     = $logFiles -join "`n"
        "Table"        = $tableName -join "`n"
        "TransformKQL" = $transformKQL 
        "Associated Resource Group(s)"  = $resourceGroups -join "`n"
        "Resources Associated to Group" = $resourcesToResourceGroup -join "`n"
        "Resources (ungrouped)"         = $resources -join "`n"
    }
}

$data | sort-object "OS","DCR Name" | export-csv .\datacollectionrules_data.csv -NoTypeInformation

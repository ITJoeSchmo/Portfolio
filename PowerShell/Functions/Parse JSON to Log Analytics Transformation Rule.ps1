<#
.SYNOPSIS
    Creates a Data Collection Rule Transformation to parse and flatten JSON into individual columns for Log Analytics.

.DESCRIPTION
    This function takes a JSON string input and creates a Data Collection Rule Transformation to parse and flatten the JSON into individual columns. 
    It supports optional parameters for flattening nested JSON properties, preserving: ParsedData, RawData, and the original timestamp key.

.PARAMETER FlattenNestedJSON
    A switch to flatten nested JSON keys by pre-pending the parent key name to the inner-nested-property name.
    Default: $true
    Example: 
        {
        "parent_json_key":  {
                        "nested_key":  "test_value"
                    }
        }

        would be flattened to: parent_json_key_nested_key: test_value

.PARAMETER jsonString
    The JSON string to be parsed (copy from RawData field of the Log Analytics Table).

.PARAMETER TimeGeneratedKeyName
    The JSON key to be parsed as TimeGenerated, if one exists.

.PARAMETER KeepParsedData
    A switch to extend ParsedData as the RawData parsed as JSON in Log Analytics. Add this switch to keep the ParsedData field.
    Default: $false

.PARAMETER KeepRawData
    A switch to keep the RawData field. Add this switch to retain the RawData field.
    Default: $false

.PARAMETER KeepTimeKey
    A switch to keep the original timestamp key and the TimeGenerated value. Add this switch if you want to retain both the original timestamp key and the parsed TimeGenerated value.
    Default: $false

.EXAMPLE
    PS C:\> New-JsonLogAnalyticsTransformation -jsonString $json -FlattenNestedJSON -TimeGeneratedKeyName "timestamp"

.NOTES
    Author:  Joey Eckelbarger
    Created: 05-23-2024
#>

function New-JsonLogAnalyticsTransformation {
    param(
        [switch]$FlattenNestedJSON = $true, 
        [string]$jsonString,
        [string]$TimeGeneratedKeyName,
        [switch]$KeepParsedData = $false,
        [switch]$KeepRawData = $false,
        [switch]$KeepTimeKey = $false
    )

    $json = $jsonString | ConvertFrom-Json

    # get parent keys 
    [array]$properties = $json.psobject.Properties.name

    # custom object to hold "flattened" JSON data
    $mergedJSON = New-Object PSObject

    $originalNestedPropertyName = @{}

    # this loop is "flattening" the nested JSON properties under the parent keys (metadata, subscription, body)
    foreach($property in $properties)
    {
        # grab nested object and loop thru its nested properties
        $object = $json.$property

        # get nested properties
        $defaultPropertiesToExclude = @("Length")
        [array]$nestedProperties = $object.psobject.Properties.name | where-object {$_ -notin $defaultPropertiesToExclude}


        if($nestedProperties -and $FlattenNestedJSON){
            foreach($nestedProperty in $nestedProperties){
                $newPropertyName = "$($property)_$($nestedProperty)" 
        
                Add-Member -InputObject $mergedJSON -NotePropertyName $newPropertyName -NotePropertyValue $($object.$nestedProperty)

                $originalNestedPropertyName.Add($newPropertyName, @($property,$nestedProperty))
            }
        } else {
            Add-Member -InputObject $mergedJSON -NotePropertyName $property -NotePropertyValue $object
        }
    }

    $transformationRule = "source
| extend ParsedData = parse_json(RawData)`n"

    if($TimeGeneratedKeyName){
        $transformationRule = $transformationRule.Insert($transformationRule.Length, "| extend TimeGenerated = todatetime(ParsedData['$TimeGeneratedKeyName']), ")
    } else {
        $transformationRule = $transformationRule.Insert($transformationRule.Length, "| extend ")
    }

    $allPropertiesExtended = foreach($property in $mergedJSON.PSObject.Properties.Name){
        $extendedPropertyName = $property.Replace("-","_").Replace(".","_").Replace(" ","_")


        if($originalNestedPropertyName.ContainsKey($property)){
            #  test = ParsedData['instant']['epochSecond']
            $nestedPropertyReference = $originalNestedPropertyName[$property] | ForEach-Object { "['$_']" }
            $nestedPropertyReference = $nestedPropertyReference -join ""

            $extendToAppend = "$extendedPropertyName = ParsedData$($nestedPropertyReference)"
        } else {
            $extendToAppend = "$extendedPropertyName = ParsedData['$property']"
        }

        $extendToAppend
    }

    $allPropertiesExtended = $allPropertiesExtended -join ", "

    $transformationRule = $transformationRule.Insert($transformationRule.Length, $allPropertiesExtended)

    $projectAway = @() # init array

    if(-Not $KeepParsedData){
        $projectAway += "ParsedData"
    }
    
    if(-Not $KeepTimeKey -and $TimeGeneratedKeyName){
        $projectAway += $TimeGeneratedKeyName
    }

    
    if(-Not $KeepRawData){
        $projectAway += "RawData"
    }

    if($projectAway){
        $projectAway = $projectAway -join ", "
        $transformationRule = $transformationRule.Insert($transformationRule.Length, "`n| project-away $projectAway")
    }

    return $transformationRule
}

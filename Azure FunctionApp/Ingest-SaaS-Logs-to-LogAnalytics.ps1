using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Create the function to create the authorization signature for Azure Log Analytics workspace
Function Build-Signature ($workspaceId, $sharedKey, $date, $contentLength, $method, $contentType, $resource)
{
    $xHeaders = "x-ms-date:" + $date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKey)

    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)

    $authorization = 'SharedKey {0}:{1}' -f $workspaceId,$encodedHash

    return $authorization
}

# the function to create and post the request
Function Post-LogAnalyticsData($workspaceId, $sharedKey, $jsonBody, $logType, $TimeStampField, $AzureResourceId)
{
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $jsonBody.Length
    $signature = Build-Signature `
        -workspaceId $workspaceId `
        -sharedKey $sharedKey `
        -date $rfc1123date `
        -contentLength $contentLength `
        -method $method `
        -contentType $contentType `
        -resource $resource
    $uri = "https://" + $workspaceId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"

    $headers = @{
        "Authorization" = $signature
        "Log-Type" = $logType
        "x-ms-date" = $rfc1123date
        "x-ms-AzureResourceId" = $AzureResourceId
        "time-generated-field" = $TimeStampField
    }
    $response = Invoke-WebRequest -TimeoutSec 20 -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $jsonbody -UseBasicParsing
          
    return $response
}

# Interact with query parameters or the body of the request
$body = $Request.Body

# custom object to hold "flattened" JSON data
$mergedJSON = New-Object PSObject

# get parent keys 
[array]$properties = $body.Keys
# this loop is "flattening" the nested JSON properties under the parent keys (metadata, subscription, body)
foreach($property in $properties){
    # grab nested object and loop thru its nested properties
    $object = $body.$property

    # get nested keys (actual key=value JSON we want)
    [array]$nestedProperties = $object.Keys

    foreach($nestedProperty in $nestedProperties){
        # added this switch statement to pre-pend the parent JSON key to the beginning of the property name
        switch ($property) {
            # body is where the bulk of the values we actually want to see are -- so lets not pre-pend anything on this, and prepend values within metadata, subscription, etc.
            "body" { 
                $propertyName = $nestedProperty 
                break
            }
            # this will pre-pend the parent key name (e.g. Body_ or Subscription_ to the front of the nested values 
            # e.g. isntead of owner_id we'll see subscription_owner_id -- makes more sense when considering these values are fairly static, all users being in this subscription
            # this is to prevent name conflicts of the flattened JSON
            Default { 
                $propertyName = "$($property)_$($nestedProperty)" 
            }
        }
        
        Add-Member -InputObject $mergedJSON -NotePropertyName $propertyName -NotePropertyValue $($object.$nestedProperty)
    }
}

# this sort is to group together datapoints that should be together e.g. event_time and event_action
$sortedProperties = $mergedJSON.PSObject.Properties.Name | Sort-Object 

# using 2 var instead of just $mergedJSON because we need to ref the event_time value when sending up to ALA and after converting to JSON it isnt referencable as a property
$json = $mergedJSON | Select-Object -Property $sortedProperties | ConvertTo-Json

#write-host $json

# Workspace ID and Key for Azure Monitor Log Analytics.
$workspaceId = "workspace_guid"
$sharedKey = $ENV:SharedKey

# vars for handling spikes in traffic leading to ALA post failure
$maxRetries   = 3
$initialDelay = 2 # seconds
$retryCount   = 0

$jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($json)

# Forward the logs to Azure Monitor
while ($retryCount -lt $maxRetries) {
    try {
    $response = Post-LogAnalyticsData -logType "SaaS_Live_Events" -sharedKey $sharedKey -workspaceId $workspaceId -jsonBody $jsonBytes -timeStampField $mergedJSON.metadata_event_time -azureResourceId "/subscriptions/36e64ef7-a4c1-4d70-8e0d-5a672a56fa6d/resourceGroups/rg-canvas-pi" -errorAction Stop
    # If successful, break out of the while loop
    break
    } catch {
        $retryCount++
        # Calculate exponential backoff delay, then add random jitter (1-2 seconds)
        # this ensures we do not overload the API -- a simple delay of all POSTs would not resolve the issue.
        # exponential backoff = after each retry, the delay is going to increase ^2 of the retryCount 
        # e.g. (wait 2 seconds -> 4 seconds -> 8 seconds + random jitter 1-3 seconds = total delay)
        $delay = $initialDelay * [Math]::Pow(2, $retryCount) + (Get-Random -Minimum 1 -Maximum 3)
        # Ensure delay doesn't exceed 25 seconds total, longer runtime = more $
        $delay = [Math]::Min($delay, 25)
        
        Write-Host "Retry $retryCount of $maxRetries Waiting $delay seconds... Error:"
        Write-Host $_
        
        Start-Sleep -Seconds $delay
    }
}
 
if($retryCount -gt 0 -and ($response.StatusCode -eq 200 -or $response.StatusCode -eq 204))
{
    write-host "Successfully posted to ALA on the $retryCount retry"
}

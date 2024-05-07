# Script to sync PIA VPN IP Address list to Azure's Conditional Access policy's named locations to block access. The script will dynamically create additional named locations and re-link them to the policies needed. 
# PIA Server Repo: https://github.com/Lars-/PIA-servers.git
# 
# Scripted by Joey Eckelbarger 10/30/2023
#
# this script is very dynamic with the NamedLocations -- it will create more if needed and remove them if not needed as the size of the list fluctuates, then re-links all to the appropriate CA policy.
# scheduled to execute hourly 6 minutes past the hour (the list updates @ 5 min past each hr). 

# Conditional Access Policy for Blocked Sign-in Locations (policy is what determines the response to the named location conditions being met)
$conditionalAccessPolicyId = "93d42f09-8306-4338-8b6a-9b10a8b0b5c7"

# download the content of the CSV
$url = "https://raw.githubusercontent.com/Lars-/PIA-servers/master/export.csv"
$csvContent = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
# ConvertFrom-CSV to create object w/ properties
$ipBlockList = $csvContent.Content | ConvertFrom-Csv 
# transform data to IPs and append "/32" 
#       (these are static IPs and not ranges, so we need to specify all octets are set with /32)
$ipBlockList = $ipBlockList | Select-Object IP | ForEach-Object { "$($_.IP)/32" } | Sort-Object

Write-Output "Found $($ipBlockList.Count) IPs to sync up to Named Locations"

# get the current namedLocationIDs
try {
    Connect-MgGraph -Identity -NoWelcome 
    $namedLocationIDs = [array](Get-MgIdentityConditionalAccessNamedLocation -All -ErrorAction Stop | Where-Object { $_.DisplayName -like "*Blocked_VPN_Addresses_XX*" } | Sort-Object DisplayName).Id
    $manualLocationIDs = [array](Get-MgIdentityConditionalAccessNamedLocation -All -ErrorAction Stop | Where-Object { $_.DisplayName -like "*Adhoc*" } | Sort-Object DisplayName).Id

    Write-Output "Found $($namedLocationIDs.Count) Named Locations already provisioned"
    Write-Output "Found $($manualLocationIDs.Count) Manual Locations already provisioned"

} catch {
    Write-Error $_
    Throw
}

$namedLocationsNeeded = [math]::Ceiling($ipBlockList.Count / 2000) - ($namedLocationIDs.Count)
if($namedLocationsNeeded -gt 0) {
    Write-Output "The script will create $namedLocationsNeeded more Named Locations (Blocked_VPN_Addresses_XX)"
}

Write-Output "Breaking IPs into chunks of 2000 to loop through and update Named Locations..."
$chunkSize = 2000
$iteration = 0

for ($i = 0; $i -lt $ipBlockList.Count; $i += $chunkSize) {
    $currentChunkOfIPs = $ipBlockList[$i..($i+$chunkSize-1)]

    # parameters for "Blocked_VPN_Addresses_XX" NamedLocation in Azure
    $params = @{ 
        "@odata.type" = "#microsoft.graph.ipNamedLocation" 
        DisplayName = "Blocked_VPN_Addresses_$($iteration+1)"  # + 1 here because I want the named locations to read 1-10 not 0-9, but arrays index at 0, so there is an offset
        IsTrusted = $False
        IpRanges = @()
    }   

    # loop thru blocklist and add addresses to the params
    foreach($IP in $currentChunkOfIPs) 
    { 

        $IpRanges = @{
            "@odata.type" = "#microsoft.graph.iPv4CidrRange"
            "CidrAddress" = $IP
        }

        $params.IpRanges += $IpRanges
    }

    # if we have a NamedLocation for this chunk, just update its IpRanges
    if($namedLocationIDs[$iteration])
    {
        Write-Output "--Overwriting $($currentChunkOfIPs.Count) IPs in Named Location $($params.DisplayName) with ID $($namedLocationIDs[$iteration])"
        Update-MgIdentityConditionalAccessNamedLocation -NamedLocationID $namedLocationIDs[$iteration] -BodyParameter $params
    # if we do not have a NamedLocation made for this chunk, lets make one with the IpRanges
    } else {
        Write-Output "--Adding $($currentChunkOfIPs.Count) IPs to a NEW Named Location $($params.DisplayName)"
        New-MgIdentityConditionalAccessNamedLocation -BodyParameter $params
    }

    $iteration++ # want this at the bottom since arrays index @ 0 and we are using this to determine what namedLocation to store each chunk of IPs
}

# if we have less total iterations than the NamedLocations provisioned, there are extra named locations to be cleaned up.
Write-Output "Checking if there are more Named Locations than needed..."
if($iteration -lt $namedLocationIDs.Count)
{
    $maxIndex = ($namedLocationIDs.Count - 1) # index @ 0 so need to adjust 

    # the named locations indexed $iteration-> last entry were not updated therefor they don't need to be retained
    [array]$namedLocationsToDelete = $namedLocationIDs[$iteration..$maxIndex]
    [array]$namedLocationsToRetain = $namedLocationIDs[0..($iteration-1)] # -1 to offset index @ 0
    
    Write-Output "--Identified $($namedLocationsToDelete.Count) extra Named Locations to delete"
    Write-Output "--Identified $($namedLocationsToRetain.Count) Named Locations to retain"
    Write-Output "--Identified $(.count) manually add Locations to retain"

    [array]$LocationsToRetain = $manualLocationIDs + $namedLocationsToRetain

    try {
        $params = @{
            Conditions = @{
                Locations = @{
                    IncludeLocations = @(
                        $LocationsToRetain
                    )
                }
            }
        }
        Write-Output "--Unlinking extra Named Locations from Conditional Access Policy so they can be removed..."
        # update conditional access policy to point at only the Blocked_VPN_Addresses_XX named locations being used
        Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $conditionalAccessPolicyId -BodyParameter $params

        Write-Output "--Looping through and deleting extra Named Locations"
        foreach($namedLocationID in $namedLocationsToDelete)
        {
            Write-Output "----Deleting $namedLocationID"
            Remove-MgIdentityConditionalAccessNamedLocation -NamedLocationID $namedLocationID
        }
    } catch {
        Write-Error $_
        Throw "Exception during removing excess Named Locations"
    }
}


# refresh list of named Locations so we can update the policy to be linked to them.
$namedLocationIDs = [array](Get-MgIdentityConditionalAccessNamedLocation -All | Where-Object { $_.DisplayName -like "*Blocked_VPN_Addresses*" } | Sort-Object DisplayName).Id

$params = @{
    Conditions = @{
        Locations = @{
            IncludeLocations = @(
                $namedLocationIDs
            )
        }
    }
}

Write-Output "Updating Conditional Access Policy to be linked to all Blocked_VPN_Addresses_XX named locations..."

Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $conditionalAccessPolicyId -BodyParameter $params

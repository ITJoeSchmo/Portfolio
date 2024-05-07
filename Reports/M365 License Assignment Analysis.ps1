# written by Joey Eckelbarger
# this is a very complex script which ties together various reports: M365 Usage/Activation, Teams Call Activity, Group data from MSGraph, User Data from MSGraph (licensed users only), Group data from MS Graph, and some data from on-prem AD.

# multiple CSV files are exported with all data points needed to understand if you have a population of users over-licensed with all this data or inactive users who still have licenses assigned. 
# I have successfully analyzed this data and saved an employer ~$60,000/year on licenses. When you have a large organization, things tend to snowball, and leads to over-spend such as this. 

# you can understand which M365 products are being used (Teams Phone is a big one as it is included in E5 but not in lower license levels). This can help you understand if you have a population of users that are better served with a lower license level
# say you have a subset of users who only use their email/teams via web browser and never use a workstation and are never connected to an on-prem network, it may make more sense to drop their licensing down to a much lower level.

Connect-AzAccount

$vault_creds = Get-AutomationPSCredential -Name 'Vault_AzureAutomation_Approle'
Connect-Vault -vaultaddress "vault.domain.com" -Credential $vault_creds
$Entra_Cred = Read-VaultSecret -enginepath "engine/path" -secretpath "path/to/secret" -keyname "EntraID_Admin"

try {
    write-debug "Getting access token from AzAccount session to pull license:SKU definition list"
    
    # 74658136-14ec-4630-ad9b-26e160ff0fc6 is a AppId to some hidden Microsoft API
    # this Azure API is what the Azure portal uses to resolve SKU -> license name in the back-end
    $Token = (Get-AzAccessToken -ResourceUrl "74658136-14ec-4630-ad9b-26e160ff0fc6").Token | ConvertTo-SecureString -AsPlainText -Force

    # query License to SKU definition list from MSFT's API (found that Azure uses this API by inspecting traffic)
    # super annoying MSFT doesn't have a 'native' way to resolve license names
    $webData = Invoke-WebRequest -UseBasicParsing -Uri "https://main.iam.ad.ext.azure.com/api/AccountSkus?backfillTenants=false" `
    -Headers @{
        "Authorization"="Bearer $([PSCredential]::new("token", $($script:Token)).GetNetworkCredential().Password)"
     }
    # convert JSON to objects
    $licenseData = $webData.Content | ConvertFrom-Json 

    $resolveLicenseID = @{}

    # populate SKU:name definitions
    $licenseData | ForEach-Object { $resolveLicenseID[$_.skuId] = $_.name }
    write-debug "License SkuId:DisplayName definition hashtable populated with $($resolveLicenseID.count)  definitions"
} catch {
    write-debug "Failed to get access token from AzAccount; license IDs will not be resolved to display name"
}

Disconnect-AzAccount | out-null

Connect-MgGraph -Identity -NoWelcome

# array list for return results
$returnUserLicenseData = New-Object System.Collections.ArrayList
# array list for users missing properties
$usersMissingProperties = New-Object System.Collections.ArrayList

Write-Debug "Querying users with assignedLicenses greater than 0 from EntraID"
# properties for graph query
$properties = "displayName,id,jobTitle,department,CreatedDateTime,AccountEnabled,AssignedLicenses,licenseAssignmentStates,signInActivity,userPrincipalName,BusinessPhones,OnPremisesDistinguishedName"
# get users with a license assigned
$licensedUsers = Get-MgUser -All -Property $properties -Filter 'assignedLicenses/$count ne 0' -ConsistencyLevel eventual -CountVariable $licensedUserCount 
write-debug "Found $($licensedUsers.Count) licensed users"

Write-Debug "Pulling Group data"
# cache GroupID->DisplayName definitions in a hashtable
$resolveGroupID = @{}
# groups which need resolved for license inheritance
$groupIDsFromGraphQuery = $licensedUsers.LicenseAssignmentStates.AssignedByGroup | Sort-Object -Unique
$groupData = Get-MgGroup -All -Property 'DisplayName','Id'
# populate hashtable for resolving the group, only add the necessary IDs to maximize efficiency
$groupData.where({ $_.Id -in $groupIDsFromGraphQuery }) | ForEach-Object { $resolveGroupID[$_.Id] = $_.DisplayName }
# free up RAM, this is a decent chunk of data to hold onto for nothing 
$groupData,$groupIDsFromGraphQuery = $null
write-debug "Group license ID:DisplayName definition hashtable populated with $($resolveGroupID.count) definitions"

Write-Debug "Pulling M365 Usage/Activation report data from M365 Usage and Activation Details"

# get M365 Usage / Activation report from other bot
$activeUserDetailsCSV        = "$env:temp\m365_activeuser_details.csv"
$activationUserDetailsCSV    = "$env:temp\m365_activation_details.csv"

Get-MgReportOffice365ActivationUserDetail -OutFile $activationUserDetailsCSV 
Get-MgReportOffice365ActiveUserDetail -Period "D180" -OutFile $activeUserDetailsCSV 

$activeUserDetails     = Import-Csv -Path $activeUserDetailsCSV
$activationUserDetails = Import-Csv -Path $activationUserDetailsCSV

$enterpriseM365ActivationReport = $activationUserDetails | Where-Object { $_.'Product Type' -eq "MICROSOFT 365 APPS FOR ENTERPRISE" } | Select-Object 'Last Activated Date','Product Type','User Principal Name'
$mobileM365ActivationReport = $activationUserDetails | Where-Object { $_.'Product Type' -eq "OFFICE MOBILE APPS FOR OFFICE 365" } | Select-Object 'Last Activated Date','Product Type','User Principal Name'
$m365ActivityReport = $activeUserDetails | Select-Object 'Exchange Last Activity Date','OneDrive Last Activity Date','SharePoint Last Activity Date','Skype For Business Last Activity Date','Teams Last Activity Date','User Principal Name','Yammer Last Activity Date'

# get teams usage data
$teamsActivityUserDetailsCSV = @("$env:temp\teams_activityUser_details180.csv","$env:temp\teams_activityUser_details90.csv","$env:temp\teams_activityUser_details30.csv")
$reportPeriods               = @("D180","D90","D30")

# download all 3 teams reports
Invoke-MgGraphRequest -Method GET -URI "https://graph.microsoft.com/v1.0/reports/getTeamsUserActivityUserDetail(period='$($reportPeriods[0])')" -OutputFilePath $teamsActivityUserDetailsCSV[0]
Invoke-MgGraphRequest -Method GET -URI "https://graph.microsoft.com/v1.0/reports/getTeamsUserActivityUserDetail(period='$($reportPeriods[1])')" -OutputFilePath $teamsActivityUserDetailsCSV[1]
Invoke-MgGraphRequest -Method GET -URI "https://graph.microsoft.com/v1.0/reports/getTeamsUserActivityUserDetail(period='$($reportPeriods[2])')" -OutputFilePath $teamsActivityUserDetailsCSV[2]

$teamsUserActivityData = @{}
$userIdToUPN = @{}
# combine data from all 3 CSVs 
foreach($csv in $teamsActivityUserDetailsCSV){
    $teamsUserData = Import-Csv -Path $csv | Select-Object "Report Refresh Date","User Id","Call Count","Report Period","User Principal Name"
    
    $teamsUserData | Foreach-Object {
        # grab refresh date 1x to populate in table
        if(-Not $reportRefreshDate) { $reportRefreshDate = $_.'Report Refresh Date' }

        # create nested hashtables if not already made
        if(-Not $teamsUserActivityData[$($_.'Report Period')]) { $teamsUserActivityData[$($_.'Report Period')] = @{} }

        if(-Not $userIdToUPN.ContainsKey($_.'User Id')) { $userIdToUPN.Add($_.'User Id', $_.'User Principal Name') }

        # add user call count to nested hash
        $teamsUserActivityData[$($_.'Report Period')].Add($_.'User Id', $_.'Call Count')
    }
}

$userUPNsFromGraphQuery = $licensedUsers.UserPrincipalName

# populate various  hashtables to improve efficiency vs using where-object on 50k+ objects within loops
$enterpriseAppDetails = @{}
$enterpriseM365ActivationReport.where({$_.'User Principal Name' -in $userUPNsFromGraphQuery}) | ForEach-Object { $enterpriseAppDetails[$_.'User Principal Name'] = $_.'Last Activated Date' }

$mobileAppDetails     = @{}
$mobileM365ActivationReport.where({$_.'User Principal Name' -in $userUPNsFromGraphQuery}) | ForEach-Object { $mobileAppDetails[$_.'User Principal Name'] = $_.'Last Activated Date' }
write-debug "M365 Enterprise/Mobile Activation definition hashtable populated with $($mobileAppDetails.count + $enterpriseAppDetails.count) definitions"

$userActivityDetails  = @{}
$m365ActivityReport.where({$_.'User Principal Name' -in $userUPNsFromGraphQuery}) | ForEach-Object { $userActivityDetails[$_.'User Principal Name'] = $_ }
$m365ActivityReport,$mobileM365ActivationReport,$enterpriseM365ActivationReport = $null
write-debug "M365 Usage definition hashtable populated with $($userActivityDetails.count) definitions"

$userPhoneNumber = @{}
$teamNumberAssignments  = Get-CsOnlineUser -Filter "HostingProvider -eq 'sipfed.online.lync.com'" -Property 'LineUri','UserPrincipalName','HostingProvider'
$skypeNumberAssignments = Get-CsOnlineUser -Filter "HostingProvider -eq 'SRV:'"

$teamNumberAssignments  | Where-Object { $_.UserPrincipalName -in $userUPNsFromGraphQuery } | ForEach-Object { if($_.LineUri) { $userPhoneNumber[$_.'UserPrincipalName'] = "TEAMS: $($_.LineUri)" } }
$skypeNumberAssignments | Where-Object { $_.UserPrincipalName -in $userUPNsFromGraphQuery } | ForEach-Object { if($_.LineURI) { $userPhoneNumber[$_.'UserPrincipalName'] = "SKYPE: $($_.LineURI)" } }

$teamNumberAssignments,$skypeNumberAssignments = $null

$teamsUserCallCount = @{}
$teamUserData  = $teamsUserActivityData["180"].Keys | Select-Object  @{N="User Id";                   E={$_}},`
                                                                     @{N="UserPrincipalName";         E={$userIdToUPN[$_]}},`
                                                                     @{N="Call Count (Last 180 Days)";E={$teamsUserActivityData["180"][$_]}},`
                                                                     @{N="Call Count (Last 90 Days)"; E={$teamsUserActivityData["90"][$_]}},`
                                                                     @{N="Call Count (Last 30 Days)"; E={$teamsUserActivityData["30"][$_]}},`
                                                                     @{N="Report Refresh Date";       E={$reportRefreshDate}}

$teamUserData | Where-Object { $_.UserPrincipalName -in $userUPNsFromGraphQuery } | ForEach-Object { $teamsUserCallCount[$_.'User Id'] = $_ }
$teamUserData,$userUPNsFromGraphQuery = $null


Write-Debug "Looping through $($licensedUsers.Count) licensed users"
foreach($user in $licensedUsers){
    $assignedLicenses = $user.LicenseAssignmentStates
    # hash table to store licenses for user
    $licenses = @{}
    # to track if createdtime or lastsignin is missing from AAD
    $missingProperty = $false

    foreach($license in $assignedLicenses){
        if($license.state -ne "Disabled"){
            switch ($license.AssignedByGroup) {
                # if not assigned by group, it is directly assigned 
                $null { 
                    $inheritance = "Directly Assigned"
                    continue
                }
                # if the license is inherited from group membership AND we dont have a cached definition
                ({$_ -notin $resolveGroupID.Keys}) {
                    # now that we cache ID -> displayNames from the other RB bot, this shouldnt really be executed but just in case
                    $inheritance = (Get-MgGroup -GroupId $license.AssignedByGroup).DisplayName
                    # cache group ID -> DisplayName definition so we dont have to repeat calls to EntraID
                    $resolveGroupID.Add($license.AssignedByGroup, $inheritance)
                    continue
                }
                # if the license is assigned by group AND we have a cached definition of group ID:displayName
                ({$_ -in $resolveGroupID.Keys}) {
                    $inheritance = $resolveGroupID[$license.AssignedByGroup]
                    continue
                }
            }

            # create an arraylist to hold licenses by inheritance (group or directly assigned)
            if($null -eq $licenses[$inheritance]) {
                # create ArrayList nested within hashtable if doesnt exist already 
                $licenses[$inheritance] = New-Object System.Collections.ArrayList
            }

            # if we have a definition for SKU
            if($resolveLicenseID[$license.SkuId]) {
                $licenseName = $resolveLicenseID[$($license.SkuId)] + " ($($license.SkuId))"
            # if not, save just the license skuID
            } else {
                $licenseName = $($license.SkuId)
            }
            
            # nesting arraylist within hashtable because when converted to JSON this gives us a good visual for understanding inheritance
            $licenses[$inheritance].Add($licenseName) | out-null
        }
    }

    # if we have created time from Entra ID
    if($user.CreatedDateTime) { 
        $createdDateTime = ([datetime]$user.CreatedDateTime | Get-Date -Format "yyyy-MM-dd")
    } else {
        $createdDateTime = "N/A"
        $missingProperty = $true
    }

    # if we have last sign in time from Entra ID
    if($user.SignInActivity.LastSignInDateTime) { 
        $LastSignInDateTime = ([datetime]$user.SignInActivity.LastSignInDateTime | Get-Date -Format "yyyy-MM-dd")
    } else { 
        $LastSignInDateTime = "N/A"
        $missingProperty = $true
    }

    # if we have last sign in time from Entra ID
    if($user.SignInActivity.LastNonInteractiveSignInDateTime) { 
        $LastNoninteractiveSignInDateTime = ([datetime]$user.SignInActivity.LastNonInteractiveSignInDateTime | Get-Date -Format "yyyy-MM-dd")
    } else { 
        $LastNoninteractiveSignInDateTime = "N/A"
    }

    # find applicable data for each user from the data table

    # if no missing properties or device acct, add to data table
    if($missingProperty -eq $false -or $user.userPrincipalName -like "*_device_*") {
        $returnUserLicenseData.Add(
        [PSCustomObject]@{
            User                                        = $user.displayName
            UserCreatedDate                             = $createdDateTime
            UserPrincipalName                           = $user.userPrincipalName
            DistinguishedName                           = $user.OnPremisesDistinguishedName
            PhoneNumber                                 = $userPhoneNumber[$user.userPrincipalName]
            JobTitle                                    = $user.jobTitle
            Department                                  = $user.department
            "User ID"                                   = $user.Id
            "Account Enabled"                           = $user.AccountEnabled
            LastSignInTime                              = $LastSignInDateTime
            LastNoninteractiveSignInTime                = $LastNoninteractiveSignInDateTime
            Licenses                                    = ($licenses | ConvertTo-Json)
            "M365 Enterpise Apps Last Activation Date"  = $enterpriseAppDetails[$user.userPrincipalName]
            "Office Mobile Apps Last Activation Date"   = $mobileAppDetails[$user.userPrincipalName]
            'Skype For Business Last Activity Date'     = $userActivityDetails[$user.userPrincipalName].'Skype For Business Last Activity Date'
            'Teams Last Activity Date'                  = $userActivityDetails[$user.userPrincipalName].'Teams Last Activity Date'
            'Exchange Last Activity Date'               = $userActivityDetails[$user.userPrincipalName].'Exchange Last Activity Date'
            'OneDrive Last Activity Date'               = $userActivityDetails[$user.userPrincipalName].'OneDrive Last Activity Date'
            'SharePoint Last Activity Date'             = $userActivityDetails[$user.userPrincipalName].'SharePoint Last Activity Date'
            'Yammer Last Activity Date'                 = $userActivityDetails[$user.userPrincipalName].'Yammer Last Activity Date'
            'Call Count (Last 180 Days)'                = $teamsUserCallCount[$user.Id].'Call Count (Last 180 Days)'
            'Call Count (Last 90 Days)'                 = $teamsUserCallCount[$user.Id].'Call Count (Last 90 Days)'
            'Call Count (Last 30 Days)'                 = $teamsUserCallCount[$user.Id].'Call Count (Last 30 Days)'
        }) | out-null                                                                   
    # if we are missing properties, add to missingproperties data table
    } else {
        $usersMissingProperties.Add(
        [PSCustomObject]@{
            User                                        = $user.displayName
            UserCreatedDate                             = $createdDateTime
            UserPrincipalName                           = $user.userPrincipalName
            DistinguishedName                           = $user.OnPremisesDistinguishedName
            PhoneNumber                                 = $userPhoneNumber[$user.userPrincipalName]
            JobTitle                                    = $user.jobTitle
            Department                                  = $user.department
            "User ID"                                   = $user.Id
            "Account Enabled"                           = $user.AccountEnabled
            LastSignInTime                              = $LastSignInDateTime
            LastNoninteractiveSignInTime                = $LastNoninteractiveSignInDateTime
            Licenses                                    = ($licenses | ConvertTo-Json)
            "M365 Enterpise Apps Last Activation Date"  = $enterpriseAppDetails[$user.userPrincipalName]
            "Office Mobile Apps Last Activation Date"   = $mobileAppDetails[$user.userPrincipalName]
            'Skype For Business Last Activity Date'     = $userActivityDetails[$user.userPrincipalName].'Skype For Business Last Activity Date'
            'Teams Last Activity Date'                  = $userActivityDetails[$user.userPrincipalName].'Teams Last Activity Date'
            'Exchange Last Activity Date'               = $userActivityDetails[$user.userPrincipalName].'Exchange Last Activity Date'
            'OneDrive Last Activity Date'               = $userActivityDetails[$user.userPrincipalName].'OneDrive Last Activity Date'
            'SharePoint Last Activity Date'             = $userActivityDetails[$user.userPrincipalName].'SharePoint Last Activity Date'
            'Yammer Last Activity Date'                 = $userActivityDetails[$user.userPrincipalName].'Yammer Last Activity Date'
            'Call Count (Last 180 Days)'                = $teamsUserCallCount[$user.Id].'Call Count (Last 180 Days)'
            'Call Count (Last 90 Days)'                 = $teamsUserCallCount[$user.Id].'Call Count (Last 90 Days)'
            'Call Count (Last 30 Days)'                 = $teamsUserCallCount[$user.Id].'Call Count (Last 30 Days)'
        }) | out-null
    }
}

write-debug "$($usersMissingProperties.count) users missing properties (LastSignInTime or CreatedDateTime)"

# LDAP filter w/ UPNs
$upnFilters = $usersMissingProperties | ForEach-Object { "(userPrincipalName=$($_.userPrincipalName))" }

# ArrayList for on prem AD user results
$onPremUsers = New-Object System.Collections.ArrayList
# ArrayList for users not returned from AD queries
$usersMissingInAD = New-Object System.Collections.ArrayList

# How many users to process in each chunk of ad queries to prevent a huge LDAPfilter
$chunkSize = 1000
write-debug "Querying users with missing properties in chunks of 1000 from on-prem AD"
# Loop through all filters in chunks of 1k users
for ($i = 0; $i -lt $upnFilters.Count; $i += $chunkSize) {
    $currentFilters = $upnFilters[$i..($i+$chunkSize-1)]
    $ldapFilter = "(|" + ($currentFilters -join '') + ")"

    try {
        # get ad results and only select the needed properties from returned data
        $adResults = Get-ADUser -LDAPFilter $ldapFilter -ResultPageSize 1000 -Properties LastLogonDate,whenCreated -Credential $ADSA_Creds | Select-Object -Property UserPrincipalName,LastLogonDate,whenCreated
        Write-Debug "AD Returned $($adResults.count) user objects for chunk starting at index $i"
        $onPremUsers.AddRange($adResults)
    } catch {
        write-debug "AD query did not return all users"
    }
}

write-debug "AD Returned $($onPremUsers.count) total user objects"

# create hashtable definition by UPN for on prem obj data
# this should speed up looping through many objects considerably
# switching to hashtables in previous loops reduced time to loop thru 40k users from 11 hours to ~2 minutes
$onPremUserData = @{} 
$onPremUsers | ForEach-Object { $onPremUserData[$_.UserPrincipalName] = $_ }
$onPremUsers = $null

Write-Debug "Looping through $($usersMissingProperties.Count) users to populate missing properties"
# loop thru users missing properties and update them using their on-prem AD object properties
foreach($user in $usersMissingProperties) {
    # if we have an on prem obj for this user 
    if($onPremUserData[$user.userPrincipalName]) {
        # update createdDate
        if($user.UserCreatedDate -eq "N/A") {
            $user.UserCreatedDate = ([datetime]$onPremUserData[$user.userPrincipalName].whenCreated | Get-Date -Format "yyyy-MM-dd" -errorAction Stop) 
        }

        # update lastSignIn -- may be null/empty if the user has never signed into AD
        # if  we don't currently have last sign on time (= N/A)
        if($user.LastSignInTime -eq "N/A") {
            # and the on prem user has a lastLogonDate
            if($onPremUserData[$user.userPrincipalName].lastLogonDate) {
                $user.LastSignInTime = ([datetime]$onPremUserData[$user.userPrincipalName].lastLogonDate | Get-Date -Format "yyyy-MM-dd")
            # if we don't have value from AAD nor on-prem AD, they have never signed in
            } else {
                $user.LastSignInTime = "Never Signed In"
            } 
        } 

    } else {
        # we want to store these just to spot check that these are users who do not have on prem objects -- usually AAD only 
        $usersMissingInAD.Add("$($user.UserPrincipalName)")
    }
}

# add users missing properties table to the return data table
$returnUserLicenseData.AddRange($usersMissingProperties)
Write-Debug "User license assignments have completed processing, outputting data table to RB"

$returnUserLicenseData  | Export-CSV "User License Assignments.csv"

Write-Debug "Querying groups with assignedLicenses greater than 0 from EntraID"
# query group license assignments
$properties = "displayName,id,AssignedLicenses,Owners,Members"
$licensedGroups = Get-MgGroup -All -Filter 'assignedLicenses/$count ne 0' -property $properties -ConsistencyLevel eventual -CountVariable licensedGroupCount

write-debug "Found $($licensedGroups.Count) licensed groups and starting to loop through them"

# array list for return results of group assignments
$returnGroupLicenseData = New-Object System.Collections.ArrayList

foreach($group in $licensedGroups){
    $members = $returnUserLicenseData.where({ $_.Licenses -match $group.displayName }).userPrincipalName
    # resolve the license SKUs to display name
    $licenses = $group.AssignedLicenses.SkuId | ForEach-Object { $resolveLicenseID[$_] }
    
    $returnGroupLicenseData.Add(
    [PSCustomObject]@{
        DisplayName       = $group.displayName
        Id                = $group.Id
        Owners            = ($group.Owners | ConvertTo-Json)
        MemberCount       = $members.count
        Members           = ($members.AdditionalProperties.userPrincipalName | ConvertTo-Json)
        Licenses          = ($licenses | ConvertTo-Json)

    }) | out-null
}
Write-Debug "Group license assignments have completed processing, outputting data table to RB"

# return group assignments
$returnGroupLicenseData | Export-CSV "Group License Assignments.csv"

# ArrayList for returning inactive users
$returnInactiveUsers = New-Object System.Collections.ArrayList

Write-Debug "Filtering user assignments into 2nd table for Inactive Users (>90 days inactivity) with e5 for Faculty assigned"

# filter users inactive for 90 or more days (both non-interactive and interactive sign ins)
# first have to remove the LastSignInTimes that are strings so [datetime] cast does not error out 
$returnInactiveUsers.AddRange(
    $returnUserLicenseData.Where({ 
        $_.LastSignInTime -ne $null -and
        $_.LastSignInTime -ne "Never Signed In" -and 
        $_.LastSignInTime -ne "N/A" -and 
        $_.LastNoninteractiveSignInTime -ne "N/A" -and
        [datetime]$_.LastNoninteractiveSignInTime -le (Get-Date).AddDays(-90) -and
        [datetime]$_.LastSignInTime -le (Get-Date).AddDays(-90) -and
        $_.Licenses -match "06ebc4ee-1bb5-47dd-8120-11324bc54e06" # e5 SKU
    })
)

# add users who have no sign ins logged back
$returnInactiveUsers.AddRange(
    $returnUserLicenseData.Where({ 
        ($_.LastSignInTime -eq $null -or
        $_.LastSignInTime -eq "Never Signed In" -or 
        $_.LastSignInTime -eq "N/A" -or
        $_.LastNoninteractiveSignInTime -eq "N/A") -and
        $_.Licenses -match "06ebc4ee-1bb5-47dd-8120-11324bc54e06" # e5 SKU
    })
)

Write-Debug "Inactive user assignments have completed processing, outputting data table to RB"

# return inactive users
$returnInactiveUsers | Export-CSV "Inactive User License Assignments.csv"

# return users not in AD, usually these are just AAD accounts w/o on-prem objs but writing out for spot checking later on -- typically just service accts, etc. 
$usersMissingInAD | Select-Object -Property @{ Name = "UserPrincipalName";  Expression = {$_}} | Export-CSV "users missing on-prem.csv"

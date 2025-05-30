<#
.SYNOPSIS
    Establishes a connection to the MECM (Microsoft Endpoint Configuration Manager) site.

.DESCRIPTION
    The Connect-MECM function connects to an MECM site server, initializing a new PSDrive for Configuration Manager if it doesn't already exist. 
    It can execute a script block within the context of the MECM site. The function also supports credential-based authentication using a 
    provided credential or retrieves credentials from a secret vault when none are specified.

.PARAMETER ScriptBlock
    The ScriptBlock to be executed in the context of the MECM connection. Enables MECM commands to be ran without using set-location to hop
    between local path and cmsite path.

.PARAMETER SiteServer
    The name of the MECM site server.

.PARAMETER SiteCode
    The site code of the MECM site.

.PARAMETER Credential
    A PSCredential object used for authentication when connecting to the MECM site. If not provided, the function retrieves the credential from a secrets vault.

.EXAMPLE
    PS C:\> Connect-MECM -SiteServer "MECMServer01" -SiteCode "CM01"
    Connects to the Configuration Manager site with site code "CM01" on server "MECMServer01".

.EXAMPLE
    PS C:\> Connect-MECM -SiteServer "MECMServer01" -SiteCode "CM01" -ScriptBlock { Get-CMDevice -Name "Device01" }
    Connects to the Configuration Manager site and runs the specified script block to retrieve information about a device.

.NOTES
    Author: Joey Eckelbarger 2024-10-24
#>

function Connect-MECM {
    param(
        [ScriptBlock]$ScriptBlock,
        [String]$SiteServer,
        [String]$SiteCode,
        [PSCredential]$Credential
    )

    if(-Not (Get-Module ConfigurationManager)) { Import-Module ConfigurationManager }

    if(-Not (Get-PSDrive $SiteCode -ErrorAction Ignore)){
        # if azureauto or readibots automation platforms, get the _sa cred automatically
        if($env:PSPrivateMetadata -or $PSPrivateMetadata.JobId -or $sessionvars.ProcessLoggingHelper.ScriptPath){ 
            if(-Not $Credential){
                $Credential = Get-VaultSecret -enginepath "it_infra/kv" -secretpath "ad/domain.tld/mecm_sa@domain.tld" -keyname "mecm_sa@domain.tld"
            }
            
            New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -Credential $Credential -Scope Global | Out-Null
        } else {
            Write-Verbose "MECM: Connecting"
            New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -Scope Global | Out-Null
        }
    }

    $global:previousLocation = (get-location).path

    Set-Location "$($SiteCode):"

    if($ScriptBlock){
        $currentVars = (get-variable).Name
        
        Invoke-Command -ScriptBlock $scriptblock -NoNewScope  
        
        $newVars = Get-Variable | Where-Object {$_.Name -notin $currentVars}
        foreach($var in $newVars){
            Set-Variable -Name $var.Name -Value $var.Value -Scope Global
        }

        Set-Location $global:previousLocation
    }
}
function Get-CMSchedule {
    param(
        [parameter(Mandatory=$true)][string]$String,
        [string]$SiteCode,
        [PSCredential]$Credential
    )
    if($Credential){
        # Create Connection Options with the provided credentials
        $ConnectionOptions = New-Object System.Management.ConnectionOptions
        $ConnectionOptions.Username = $Credential.UserName
        $ConnectionOptions.SecurePassword = $Credential.Password

        # Define the Management Scope with the connection options
        $ManagementScopePath = "\\$SiteServer\root\SMS\site_$SiteCode"
        $ManagementScope = New-Object System.Management.ManagementScope($ManagementScopePath, $ConnectionOptions)
        $ManagementScope.Connect()

        # Get the WMI Class with the management scope
        $ObjectPath = New-Object System.Management.ManagementPath("SMS_ScheduleMethods")
        $WMIConnection = New-Object System.Management.ManagementClass($ManagementScope, $ObjectPath, $null)

        # Prepare and invoke the method
        $Schedule = $WMIConnection.GetMethodParameters("ReadFromString")
        $Schedule.StringData = $String
        $ScheduleData = $WMIConnection.InvokeMethod("ReadFromString", $Schedule, $null)

        # Retrieve and return the schedule information
        $ScheduleInfo = $ScheduleData.TokenData
    } else {
        $WMIConnection = [WmiClass]"\\$($SiteServer)\root\SMS\site_$($SiteCode):SMS_ScheduleMethods"
        $Schedule = $WMIConnection.psbase.GetMethodParameters("ReadFromString")
        $Schedule.StringData = $String
        $ScheduleData = $WMIConnection.psbase.InvokeMethod("ReadFromString",$Schedule,$null)
        $ScheduleInfo = $ScheduleData.TokenData
    }

    $ScheduleInfo = $ScheduleInfo | Select-Object *,@{N="StartTime";E={[Management.ManagementDateTimeConverter]::ToDateTime($_.StartTime)}} -ExcludeProperty StartTime
    return $ScheduleInfo
}

<#
.SYNOPSIS
    Retrieves the maintenance window information for a specific resource.

.DESCRIPTION
    The Get-CMMaintenanceWindowsInformation function retrieves maintenance window data for a specified resource in MECM.
    It searches through all collections to which the resource belongs and extracts detailed schedule information.

.PARAMETER SiteServer
    The name of the MECM site server. This is a mandatory parameter.

.PARAMETER SiteCode
    The site code of the MECM site. This is a mandatory parameter.

.PARAMETER ResourceID
    The resource ID for which to retrieve maintenance windows. This is a mandatory parameter.

.PARAMETER Credential
    A PSCredential object used for authentication when retrieving the maintenance windows information.

.EXAMPLE
    PS C:\> Get-CMMaintenanceWindowsInformation -ResourceID 12345 -Credential $Cred
    Retrieves maintenance window details for resource ID 12345 using the provided credentials.

.NOTES
    Author: Seems to be NickolaJa from https://github.com/NickolajA/PowerShell/blob/master/ConfigMgr/Tools/GetMaintenanceWindow/Get-MaintenanceWindows.ps1
    Edited by: Joey Eckelbarger 
        Fixed 2-3 bugs which caused certain MWs to not populate/translate correctly over to DateTime resulting in blank results. 
        4/30/2025: added parameter returnPSObject - kind of hacky but wanted another method of returning data without breaking other processes built upon the current returned string...hopefully will clean this up in the future 
#>
function Get-CMMaintenanceWindowsInformation {
    param(
        $SiteServer,
        $SiteCode,
        [parameter(Mandatory=$true)]$ResourceID,
        [PSCredential]$Credential,
        [Switch]$returnPSObject
    )

    $CMSiteCode         = $SiteCode
    $CurrentDateTime    = (Get-Date)
    $MaintenanceWindows = @()
    if(-Not $script:maintenanceWindowsHT){
        $script:maintenanceWindowsHT = @{}
    }

    # Create a CIM session to the SiteServer using DCOM protocol
    if ($Credential) {
        $SessionOptions = New-CimSessionOption -Protocol Dcom
        $CimSession = New-CimSession -ComputerName $SiteServer -Credential $Credential -SessionOption $SessionOptions
    } else {
        $SessionOptions = New-CimSessionOption -Protocol Dcom
        $CimSession = New-CimSession -ComputerName $SiteServer -SessionOption $SessionOptions
    }

    $CollectionIDs = Get-CimInstance -CimSession $CimSession -Namespace "root\SMS\site_$($CMSiteCode)" -Class SMS_FullCollectionMembership -Filter "ResourceID like '$($ResourceID)'"

    foreach ($CollectionID in $CollectionIDs) { 
        # if we already have the MW info from getting another devices MW cached, we know the MW and dont need to output anything. 
        <#if($script:maintenanceWindowsHT.ContainsKey($CollectionID.CollectionID)){

            if($script:maintenanceWindowsHT[$CollectionID.CollectionID]){
                $MaintenanceWindows += $script:maintenanceWindowsHT[$CollectionID.CollectionID]
            }

            continue
        }#>
           
        $CollectionSettings = Get-CimInstance -CimSession $CimSession -Namespace "root\SMS\site_$($CMSiteCode)" -Class SMS_CollectionSettings -Filter "CollectionID='$($CollectionID.CollectionID)'" | Get-CimInstance
        $CollectionName     = Get-CimInstance -CimSession $CimSession -Namespace "root\SMS\site_$($CMSiteCode)" -Class SMS_Collection -Filter "CollectionID = '$($CollectionID.CollectionID)'" | Select-Object -ExpandProperty Name
        $collectionHasMWs   = $false

        # Map Day number to DayOfWeek enum (1=Sunday, 7=Saturday)
        $dayOfWeekMap = @{
            1 = [DayOfWeek]::Sunday
            2 = [DayOfWeek]::Monday
            3 = [DayOfWeek]::Tuesday
            4 = [DayOfWeek]::Wednesday
            5 = [DayOfWeek]::Thursday
            6 = [DayOfWeek]::Friday
            7 = [DayOfWeek]::Saturday
        }

        $weekSpanMap = @{
            1 = 0 
            2 = 7 
            3 = 14 
            4 = 21 
        }

        foreach ($CollectionSetting in $CollectionSettings) {
            foreach ($MaintenanceWindow in $CollectionSetting.ServiceWindows) {
                if($MaintenanceWindow.IsEnabled){
                    $MWDate         = $null       

                    $Schedule  = Get-CMSchedule -String $MaintenanceWindow.ServiceWindowSchedules -Credential $Credential
                    
                    [int32]$StartDay  = $Schedule.Day
                    $StartTime = $Schedule.StartTime
                    $StartHour = $StartTime.Hour
                    $StartHour = $StartHour.ToString("00")
                    $StartMin  = $StartTime.Minute
                    $StartMin  = $StartMin.ToString("00")
                    $StartSec  = $StartTime.Second

                    $DaySpan   = $Schedule.DaySpan
                    $DayOfWeek = $dayOfWeekMap[$StartDay]
                    [int32]$WeekOfMonth = $Schedule.WeekOrder

                    $WeekSpan  = $Schedule.ForNumberOfWeeks

                    $MonthSpan = $Schedule.ForNumberOfMonths
                    $MonthDay  = $Schedule.MonthDay

                    switch($maintenanceWindow.RecurrenceType){
                        1{ # No recurrence
                            $MWDate  = $Schedule.StartTime
                        }

                        2{ # Recur Daily
                            Do {
                                $StartTime = $StartTime.AddDays($DaySpan)
                            } Until ($StartTime -ge $CurrentDateTime)

                            $MWDate = $StartTime
                        }

                        3{ # Recur Weekly
                            $AddDays   = $weekSpanMap[$WeekSpan]
                            $DaysUntil = 0

                            # if today is the same day of the week, then we need to add 7 days 
                            if($CurrentDateTime.DayOfWeek -eq "$($DayOfWeek)"){
                                $DaysUntil = 7 
                            }
                            While ($CurrentDateTime.DayOfWeek -ne "$($DayOfWeek)") {
                                $DaysUntil++
                                $CurrentDateTime = $CurrentDateTime.AddDays(1)
                            }

                            $MWDate = ([datetime]"$($StartHour):$($StartMin)").AddDays($DaysUntil).AddDays($AddDays)
                        }
                        4{ # Recur Monthly by Weekday
                            $FirstDayOfThisMonth = Get-Date -Day 1
                            $calendar = @()
                            $found = $false
                            $i = 0
                            # Start from the current month
                            Do {
                                $i++
                                # if its the day we are looking for, add it to the array
                                $nextDay = $FirstDayOfThisMonth.AddDays($i)
                                if($nextDay.DayOfWeek -eq $DayOfWeek){
                                    $calendar += [PSCustomObject]@{
                                        DateTime  = $nextDay.DateTime
                                        DayOfWeek = $nextDay.DayOfWeek
                                        Month     = $nextDay.Month
                                    }
                                } else {
                                    continue
                                }
                
                
                                [array]$calendar = $calendar | Group-Object Month | Select-Object -Last 1 | Select-Object -ExpandProperty Group 
                
                                # only look at the days that are applicable
                                $daysMatchingGrouped = $calendar | Group-Object DayOfWeek
                                # if we have enough of them, we know we found the MW open
                                if($daysMatchingGrouped.group.Count -eq [int32]$WeekOfMonth){
                                    [datetime]$nextMWday = $daysMatchingGrouped | Select-Object -ExpandProperty Group | Select-Object -Last 1  | Select-Object -ExpandProperty DateTime
                                    if($nextMWday -ge $CurrentDateTime){
                                        $found = $true
                                    }
                                }
                            } Until ($found)

                            $MWDate = [DateTime]::new($nextMWday.Year, $nextMWday.Month, $nextMWday.Day, $StartTime.Hour, $StartTime.Minute, $StartTime.Second)
                        }
                        5{ # Recur Monthly by Date

                            if ($Schedule.MonthDay -ge 1) {
                                if ($MonthSpan -eq 1) {
                                    $DateTime = ((Get-Date -Year (Get-Date).Year -Month (Get-Date).Month -Day $($MonthDay) -Hour $($StartHour) -Minute $($StartMin) -Second $($StartSec))).DateTime
                                } elseif ($MonthSpan -gt 1) {
                                    $DateTime = ((Get-Date -Year (Get-Date).Year -Month (Get-Date).Month -Day $($MonthDay) -Hour $($StartHour) -Minute $($StartMin) -Second $($StartSec)).AddMonths($MonthSpan)).DateTime
                                }
                            } elseif ($Schedule.MonthDay -eq 0) {
                                $DateTime = ((Get-Date -Year (Get-Date).Year -Month (Get-Date).Month -Day 1 -Hour $($StartHour) -Minute $($StartMin) -Second $($StartSec)).AddMonths($MonthSpan).AddDays(-1)).DateTime
                            }

                            $MWDate = $DateTime
                        }
                    }
                }

                if($MWDate -and (Get-Date) -le $MWDate) {
                    $MWDate = $MWDate | Foreach-Object { $_.ToString() }
                    
                    $MaintenanceWindows += [PSCustomObject]@{
                        Name           = $MaintenanceWindow.Name
                        CollectionName = $CollectionName 
                        CollectionID   = $CollectionID.CollectionID
                        NextMW         = $MWDate
                    }

                    $collectionHasMWs = $true
                }
            }
        }

        <#if($collectionHasMWs){
            $script:maintenanceWindowsHT.Add($CollectionID.CollectionID,$MaintenanceWindows)
        } else {
            $script:maintenanceWindowsHT.Add($CollectionID.CollectionID,$null)
        }#>
    }

    if($returnPSObject){
        return $MaintenanceWindows
    } else {
        $MaintenanceWindowReturn = $MaintenanceWindows | % {
            "$($_.Name) (Collection: $($_.CollectionName))"
        }
    
        $MaintenanceWindowReturn = $MaintenanceWindowReturn  -join ", "
        $NextMW                  = $($MaintenanceWindows.NextMW) -join ", "
        
        $return = @(
            $MaintenanceWindowReturn,
            $NextMW
        )
    
        return $return
    }
}


<#
.SYNOPSIS
    Initiates a CMPivot query job on specified resources or collections in MECM.

.DESCRIPTION
    The Invoke-CMPivotQueryJob function executes a CMPivot query against either a device, collection, or collection name in MECM.
    It sends a REST request to the MECM AdminService to run the query and returns information about the job, including the operation ID
    and the number of clients targeted. The function supports credential-based authentication.

.PARAMETER Query
    The CMPivot query to execute. This is a mandatory parameter.

.PARAMETER SiteServer
    The MECM site server where the AdminService API is hosted.

.PARAMETER DeviceName
    An array of DeviceNames to target for the CMPivot query.

.PARAMETER CollectionID
    An array of collection IDs to target for the CMPivot query.

.PARAMETER CollectionName
    An array of collection names to target for the CMPivot query. The function converts the collection name to a collection ID.

.PARAMETER Credential
    A PSCredential object used for authentication when invoking the CMPivot query. If not provided, the function uses the default credentials.

.EXAMPLE
    PS C:\> Invoke-CMPivotQueryJob -Query "Select * from Win32_OperatingSystem" -ResourceID "12345" -SiteServer "MECMServer01"
    Initiates a CMPivot query for the resource ID "12345" on the site server "MECMServer01".

.EXAMPLE
    PS C:\> Invoke-CMPivotQueryJob -Query "Select * from Win32_OperatingSystem" -CollectionID "COLL001" -SiteServer "MECMServer01"
    Initiates a CMPivot query for the collection with ID "COLL001" on the site server "MECMServer01".

.EXAMPLE
    PS C:\> Invoke-CMPivotQueryJob -Query "Select * from Win32_OperatingSystem" -CollectionName "All Systems" -SiteServer "MECMServer01" -Credential $Cred
    Initiates a CMPivot query for the collection named "All Systems" using the specified credentials.

.NOTES
    Author: Joey Eckelbarger
#>
function Invoke-CMPivotQueryJob {
    param(
        [parameter(Mandatory=$true)][String]$Query,
        [String]$SiteServer,
        [string[]]$DeviceNames,
        [string[]]$CollectionID,
        [string[]]$CollectionName,
        [PSCredential]$Credential
    )

    $Body = @{
        InputQuery = $Query
    } | ConvertTo-Json

    if($DeviceNames){
        $queryType = "Device"
        $targets = Connect-MECM {
            $DeviceNames | Foreach-Object {
                if($_ -like "*.*"){
                    $name = $_.Split(".")[0]
                } else {
                    $name = $_
                }
                [int32]$id = Get-CMDevice -Name $name -Fast | Select-Object ResourceID -ExpandProperty ResourceID
                $id # return resource id
            }
        }
    } elseif($CollectionID){
        $queryType = "Collections"
        $targets   = $CollectionID
    } elseif($CollectionName){
        $queryType = "Collections"

        $targets = foreach($name in $CollectionName){
            Connect-MECM {
                [string]$collectionID = (Get-CMCollection -Name $name).CollectionID
                $collectionID # return to $targets
            }
        }
    }

    $CMPivotJobs = @()
    $clientsTotal = 1 # default assume targeting 1 device 

    # start CMPivot query
    foreach($target in $targets){
        $cmPivotStartParams = @{
            Method      = "POST"
            Body        = $Body
            ContentType = "application/json"
            ErrorAction = "Stop"
        }

        if($queryType -eq "Device"){
            $cmPivotStartParams.Add("Uri", "https://$SiteServer/AdminService/v1.0/$($queryType)($($target))/AdminService.RunCMPivot")
        } else {
            $cmPivotStartParams.Add("Uri", "https://$SiteServer/AdminService/v1.0/$($queryType)('$($target)')/AdminService.RunCMPivot")
        }

        
        if($Credential){
            $cmPivotStartParams.Add("Credential", $Credential)
        } else {
            $cmPivotStartParams.Add("UseDefaultCredentials", $true)
        }

        $CMPivotStart = Invoke-RestMethod @cmPivotStartParams

        if($CMPivotStart.value.OperationId){
            $operationId = $CMPivotStart.value.OperationId
        }elseif($CMPivotStart.OperationId){
            $operationId = $CMPivotStart.OperationId
        }

        # determine how many clients we expect to answer CMPivot by counting collection members that are both active and healthy
        if($queryType -eq "Collections"){
            $TargetCollectionMembers = Connect-MECM { 
                Get-CMCollectionMember -CollectionId $target | Select-Object Name,ClientActiveStatus,ClientCheckPass | Where-Object {$_.ClientActiveStatus -eq 1 -and $_.ClientCheckPass -eq 1}
            }
            $clientsTotal = ($TargetCollectionMembers).Count 
        }

        $jobInfo = [PSCustomObject]@{
            OperationId      = $operationId
            StartTime        = (Get-Date)
            ClientsTargeted  = $clientsTotal
        }

        $CMPivotJobs += $jobInfo
    }

    # sort so the lowest # of clients are first -- we are assuming they would probably complete first 
    $CMPivotJobs = $CMPivotJobs | Sort-Object ClientsTargeted 

    return $CMPivotJobs
}


<#
.SYNOPSIS
    Waits for the completion of one or more CMPivot query jobs.

.DESCRIPTION
    The Wait-CMPivotQueryJob function monitors the progress of one or more CMPivot query jobs in MECM. It checks the status of each job
    and waits for the job to either expire or reach the expected number of clients. The function uses the MECM AdminService and 
    optionally accepts credentials for authentication.

.PARAMETER Job
    A PSCustomObject that contains information about the CMPivot job(s), including the operation IDs and the number of targeted clients. This is a mandatory parameter.

.PARAMETER SiteServer
    The MECM site server from which the function retrieves CMPivot job summaries. Defaults to an empty string, which requires explicit input.

.PARAMETER Credential
    A PSCredential object used for authentication when retrieving job summaries from the AdminService. 
    If not provided, the function uses the default credentials.

.EXAMPLE
    PS C:\> Wait-CMPivotQueryJob -Job $cmpivotJobs -SiteServer "MECMServer01"
    Waits for the CMPivot query jobs defined in the $cmpivotJobs object on the "MECMServer01" server to complete.

.EXAMPLE
    PS C:\> Wait-CMPivotQueryJob -Job $cmpivotJobs -SiteServer "MECMServer01" -Credential $cred
    Waits for the CMPivot query jobs using the provided credentials for authentication.

.NOTES
    Author: Joey Eckelbarger

.LIMITATION
    The function monitors jobs and completes when either all clients have responded or the job is marked as expired.
    It checks status every 10 seconds and kicks off a summarization every 5 minutes.
#>

function Wait-CMPivotQueryJob {
    param(
        [parameter(Mandatory=$true)][PSCustomObject]$Job, 
        [String]$SiteServer,
        [PSCredential]$Credential
    )

    foreach($runningJob in $Job){
        $Id           = $runningJob.OperationId
        $clientsTotal = $runningJob.ClientsTargeted

        # wait until operation status is expired OR we have as many clients returned as expected 
        $queryComplete         = $false
        $SumOfClientsAttempted = 0
        $summarizationTime     = Get-Date # used for invoking client operation summarization so that job summary (# clients ran against) for cmpivot query updates more frequently than 1x every 30-45 min
        
        Do{
            ### if we have the # of clients completed as expected then we can also assume completion
            $cmPivotJobSummaryParams = @{
                Uri         = "https://$SiteServer/AdminService/v1.0/SMS_CMPivotStatus/AdminService.CMPivotJobSummary(OperationId=$Id)"
                Method      = "GET"
                ContentType = "application/json"
                ErrorAction = "Stop"
            }

            if($Credential){
                $cmPivotJobSummaryParams.Add("Credential", $Credential)
            } else {
                $cmPivotJobSummaryParams.Add("UseDefaultCredentials", $true)
            }

            Try {
                $jobSummary = Invoke-RestMethod @cmPivotJobSummaryParams
            } Catch {
                # 404 is usually caused by checking status too quickly after starting CMPivot Job
                if($_.Exception.Message -like "*(404) Not Found*"){
                    if($retryCount -gt 2){
                        Out-Error $_ -Throw 
                    }
                    Start-Sleep -seconds 30 
                    $retrycount++
                } else {
                    Out-Error $_ -Throw 
                }
            }
    
            $SumOfClientsAttempted = $jobSummary | Foreach-Object { $_.PSObject.Properties | Where-Object {$_.Name -like "*clients" -and $_.Name -ne "TotalClients"} | Select-Object -ExpandProperty Value } | Measure-Object -Sum | Select-Object -ExpandProperty Sum
    
            if($SumOfClientsAttempted -ge $clientsTotal){
                $queryComplete = $true
                $reason = "expected number of clients attempted"
            }

             ### if all operations are expired/complete then we should just have a value of 1 and can assume completion
             $operationStatus = Connect-MECM {
                Get-CMClientOperation | Where-Object {$_.ID -eq $Id} | Select-Object -ExpandProperty IsExpired
                # run summarization 1x per 5 minutes
                if($(Get-Date) -gt $($summarizationTime.AddMinutes(5))){
                    Invoke-CMClientOperationSummarization
                    $summarizationTime = Get-Date
                }
            }
    
            if($operationStatus -eq 1){
                $queryComplete = $true
                $reason = "expiration"
            }
    
            start-sleep -seconds 10
        } Until ($queryComplete)

        Write-Output "CMPivot Query Job $Id is complete due to $($reason). The query attempted running against $SumOfClientsAttempted clients"
    }
}

<#
.SYNOPSIS
    Retrieves and parses the results of a CMPivot query job from MECM.

.DESCRIPTION
    The Receive-CMPivotQueryJob function retrieves the results of a CMPivot query for a given job by invoking the MECM AdminService.
    It parses the output from XML into CSV format for easier manipulation and adds contextual information such as collection names.
    The function supports credential-based authentication and populates results with relevant collection details.

.PARAMETER Job
    A PSCustomObject that contains the CMPivot job details, including the operation IDs.

.PARAMETER SiteServer
    The MECM site server from which to retrieve the CMPivot results. This is a mandatory parameter.

.PARAMETER Credential
    An optional PSCredential object used for authentication when querying the AdminService. 
    If not provided, the function uses the default credentials.

.EXAMPLE
    PS C:\> $job = Start-CMPivotQuery -ResourceID "12345" -Query "Select * from Win32_OperatingSystem"
    PS C:\> Wait-CMPivotQueryJob -Job $job
    PS C:\> Receive-CMPivotQueryJob -Job $job -SiteServer "MECMServer01"
    Retrieves and parses the CMPivot query results for the specified job on the server "MECMServer01".

.EXAMPLE
    PS C:\> Receive-CMPivotQueryJob -Job $job -SiteServer "MECMServer01" -Credential $cred
    Retrieves the CMPivot query results using the specified credentials.

.NOTES
    Author: Joey Eckelbarger
#>

function Receive-CMPivotQueryJob {
    param(
        [parameter(Mandatory=$true)][PSCustomObject]$Job,
        [String]$SiteServer,
        [PSCredential]$Credential
    )

    $collectionIDtoName = @{}

    $CMPivotResults = foreach($operationId in $Job.OperationId){
        $cmPivotResultsParams = @{
            Uri         = "https://$SiteServer/AdminService/v1.0/SMS_CMPivotStatus?`$filter=ClientOperationId eq $operationId"
            Method      = "GET"
            ContentType = "application/json"
        }
        
        if($Credential){
            $cmPivotResultsParams.Add("Credential", $Credential)
        } else {
            $cmPivotResultsParams.Add("UseDefaultCredentials", $true)
        }

        Invoke-RestMethod @cmPivotResultsParams
        
        # populate Id -> Name definition list
        Connect-MECM {
            $operationInfo  = Get-CMClientOperation | Where-Object {$_.ID -in $operationId}
            if($operationInfo.CollectionID){
                $collectionID   = $operationInfo.CollectionID
                $collectionName = $operationInfo.TargetCollectionName
                $collectionIDtoName.Add($collectionID,$collectionName)          
            }
        }
    }

    # output results
    $results = $CMPivotResults.value | Foreach-Object {
        $XMLData = ([xml]$_.ScriptOutput).result

        # Convert XML -> CSV -> PSCustomObject to get a table/array we can easily work with
        [array]$XMLData = [array]$XMLData.e + [array]$XMLData.error | ConvertTo-Csv -NoTypeInformation -ErrorAction Ignore | ConvertFrom-Csv

        if($collectionIDtoName.ContainsKey($_.CollectionId)){ # not all queries are against collections
            $_ | Add-Member -NotePropertyName CollectionName -NotePropertyValue $collectionIDtoName[$_.CollectionId] -Force
        }
        $_ | Add-Member -NotePropertyName ScriptOutputParsed -NotePropertyValue $XMLData
        $_ | Add-Member -NotePropertyName CMPivotQuery_ResultCode -NotePropertyValue $XMLData.ResultCode
        $_ # return to $results
    }

    return $results
}

Export-ModuleMember -Function @("Connect-MECM","Get-CMMaintenanceWindowsInformation","Invoke-CMPivotQueryJob","Wait-CMPivotQueryJob","Receive-CMPivotQueryJob") 

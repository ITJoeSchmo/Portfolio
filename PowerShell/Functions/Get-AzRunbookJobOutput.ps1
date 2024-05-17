<#
.SYNOPSIS
    Retrieves and processes the output of an Azure Automation Runbook job in near real-time. This is function is preferred over the built-in Get-AzAutomationJobOutputRecord because it can handle and deserialize objects.  

.DESCRIPTION
    The Get-AzAutoJobOutput function retrieves the output of an Azure Automation Runbook job and processes it into a readable format.
    The function parses the output into an array of individual hashtables. If the key for the hashtable is set to "value", it means the value of the key in the hashtable is direct output and does not need re-construction.
    If the key is anything other than "value", it is actually a property of an object converted (aka deserialized) into a hashtable where the key is the property name and the value is the property value.
    This function helps in simplifying the complex structure of the output received from Azure Automation jobs, making it easier to use and reference elsewhere in other automation platforms/environments.

.PARAMETER runbookJobOutput
    Stores output if wanted to reference in script elsewhere.
    Type: System.Collections.ArrayList
    Global: True

.PARAMETER runbookJobId
    Specifies the ID of the runbook job.
    Type: String
    Required: True

.PARAMETER automationAccountName
    Specifies the name of the Azure Automation account.
    Type: String
    Required: False
    Default value: "AzureAutomation"

.PARAMETER resourceGroupName
    Specifies the name of the Azure resource group.
    Type: String
    Required: False
    Default value: "Automation"

.PARAMETER maxWaitTimeOut
    Specifies the maximum number of minutes after which the script will exit the do-until loop to avoid an infinite loop.
    Type: Int
    Required: False
    Position: 3
    Default value: 15

.PARAMETER formatOutputForEmail
    Specifies whether to format the output as HTML for emailing the output when completed. Useful for things like emailing the results of a failed job.
    Type: Bool
    Required: False
    Position: 4
    Default value: $false

.EXAMPLE
    Get-AzAutoJobOutput -runbookJobId "8b2356c2-0cf9-4fcf-8dc8-49effcf1989b" -automationAccountName "AzureAutomation" -resourceGroupName "Automation" -maxWaitTimeOut 20 -formatOutputForEmail $true
    Description: Retrieves and processes the output of the specified Azure Automation Runbook job, formats it for email, and exits the loop after 20 minutes even if the job is not completed.

.EXAMPLE
    Get-AzAutoJobOutput -runbookJobId "ebfb965c-cca3-46b4-8cb5-7a7ad5a0615d"
    Description: Retrieves and processes the output of the specified Azure Automation Runbook job using the default automation account and resource group, with a timeout of 15 minutes.

.NOTES
    Author: Joey Eckelbarger
    Last Edit: 12-15-2023

    The function uses Get-AzAutomationJobOutput and Get-AzAutomationJobOutputRecord to parse output from Azure Automation into an array of individual hashtables.
    - If the key for the hashtable is "value", it indicates direct output.
    - If the key is anything other than "value", it indicates a property of an object where the key is the property name and the value is the property value.
#>
function Get-AzRunbookJobOutput {
    param(
        $global:runbookJobOutput       = (New-Object System.Collections.ArrayList), # store output if wanted to reference in script elsewhere
        [string]$runbookJobId,
        [string]$automationAccountName = "AzureAutomation",
        [string]$resourceGroupName     = "Automation",
        $maxWaitTimeOut                = 15,  # how many mins after starting will the script exit the do-until loop; in case something breaks this will end a forever-looping readibots bot (unexpected but not impossible)
        [bool]$formatOutputForEmail    = $false
    )

    
    $expirationTime = (Get-Date).AddMinutes($maxWaitTimeOut) # in case something breaks this will end a forever-looping readibots bot (unexpected but not impossible)
    $jobQueued,$jobCompleted = $false
    $jobCompletedStates = @( "Failed", "Stopped", "Suspended", "Completed" )
     
    $startIndex,$endIndex,$rawAutomationJobOutput,$updatedRawAutomationOutput = $null
    
    
    Write-Debug "Get-AzJobOutput: Waiting for job to start running and produce output..."

    Do {
        start-sleep -seconds 1  # 1 sec delay between looping output retrieval for read out
        $currentTime = Get-Date # for max wait time


        $job = Get-AzAutomationJob -AutomationAccountName $automationAccountName -ResourceGroupName $resourceGroupName -Id $runbookJobId
        
        switch($job.Status) {

            { ($_ -eq "Queued") -or ($_ -eq "New") } {  
                if($jobQueued -eq $false) {
                    Write-Debug "Get-AzJobOutput: Job $runbookJobId is Queued..."
                    $jobQueued = $true  
                }
                continue # waiting for job to start, next loop
            }

            { ($_ -eq "Running") -or ($_ -in $jobCompletedStates) } { # if the job is running OR completed, we need to check for output + read it out if its NEW
                # we want both conditions ^^^ to parse output or else the job may complete before it is seen = Running, then there would be no output processed without
                # copy/pasting all this script block a 2nd time 
                # then we can set $jobCompleted true at the very end of script block if jobCompleteState -eq $_ ($job.status)

                # if defined the switch block has executed at least once; if so we need to compare new data to old to see if there is new data to process as output

                if($rawAutomationJobOutput) {  # if defined = ran at least 1x and captured data                     
                    $updatedRawAutomationOutput = Get-AzAutomationJobOutput -AutomationAccountName $automationAccountName -Id $runbookJobId -ResourceGroupName $ResourceGroupName -Stream "Any" | Get-AzAutomationJobOutputRecord

                    # cast to array, if only 1 obj is returned this will make sure the for loop still works
                    [array]$updatedRawAutomationOutput = $updatedRawAutomationOutput.Value

                    $oldCount = $($rawAutomationJobOutput).Count     # amount of OLD output data
                    $newCount = $($updatedRawAutomationOutput).Count # amount of NEW output data

                    if($newCount -gt $oldCount){ # if new data
                        $rawAutomationJobOutput = $updatedRawAutomationOutput # set new data to var & continue block to process output

                        $startIndex = $endIndex # should always be + 1 the last index so there isn't overlapping output read. 
                        $endIndex = $newCount  # last index = total items, dont need to -1 because the for loop is $i -lt $endIndex e..g $endIndex = 5 -> 0,1,2,3,4
                    } else {
                        continue # if there is not new data, next loop
                    }

                } else { # this switch block gets executed UNTIL the first bit of data is captured + processed (rawAutomationJobOutput is not null)
                    # check data to process
                    $updatedRawAutomationOutput = Get-AzAutomationJobOutput -AutomationAccountName $automationAccountName -Id $runbookJobId -ResourceGroupName $ResourceGroupName -Stream "Any" | Get-AzAutomationJobOutputRecord
                   
                    # cast to array, if only 1 obj is returned this will make sure the for loop still works
                    [array]$updatedRawAutomationOutput = $updatedRawAutomationOutput.Value

                    $newCount = $($updatedRawAutomationOutput).Count
                    
                    if($newCount -gt 0){ # we only update $rawAutomationJobOutput if there is output data captured
                        # set $rawAutomationJobOutput which will cause the if() to execute going forward
                        $rawAutomationJobOutput = $updatedRawAutomationOutput 

                        $startIndex = 0 # should always start parsing/reading output @ 0 index since this block is 1st run only
                        $endIndex = $newCount # last index = total items, dont need to -1 because the for loop is $i -lt $endIndex e..g $endIndex = 5 -> 0,1,2,3,4
                        # var used to track if an error msg is present in output we grabbed, if not and the status was failed, we need to get the error and output it as $exceptionMessageThrown
                        $errorCaught = $false

                        # storeds lines 0-3 (4 lines) are informational
                        $runbookJobOutput.Add($($job.RunbookName)) | Out-Null
                        $runbookJobOutput.Add($runbookJobId) | Out-Null
                        $runbookJobOutput.Add("$($job.CreationTime.DateTime.ToString()) ($($job.CreationTime.Offset.Hours))") | Out-Null
                        $runbookJobOutput.Add("runbookJobStatus") | Out-Null # this line is updated after execution completes
                        if($sessionvars.ProcessLoggingHelper.ScriptPath){ # checking var; keeps this whole func flexible for other platforms (not readibots)
                            $runbookJobOutput.Add($sessionvars.ProcessLoggingHelper.ScriptPath) | Out-Null
                        }

                        Write-Debug "Get-AzJobOutput: Job $runbookJobId is $_..."

                        Write-Debug "`n`n`n" # creates nice 3 line break for identifying output in readibots  easier reading/seeing

                    } else {
                        continue # if there is not new data, next loop
                    }
                }

                # begin processing output stored in hashtables 
                # $rawAutomationJobOutput.value
                # ^array of hashtables
                # loop thru set indexes to parse output

                # if the indexes are the same there is only 1 new msg, but the for loop wont handle this case
                 # e.g. if both indexes are 2, the loop below does not execute against 2, but if its 2,3 then it will execute against 2 only, so we want to +1 endIndex
                if(($startIndex) -and ($endIndex) -and ($startIndex -eq $endIndex)) 
                {
                    $endindex = ($endIndex + 1) 
                }

                for($i = $startIndex; $i -lt $endIndex; $i++) 
                {   
                    $hashtable = $rawAutomationJobOutput[$i]
                    
                    # removes if containing '*ClassId*' as usually not helpful/insightful/needed data
                    if($hashtable.Keys -match "ClassId")
                    {
                        continue # suppress output matching this
                    }

                    # loop thru remaining output and re-construct into readable output
                    # considerations: if a line is logged 2x with the exact output, we want it read out 2x but that means we cant simply if $line -in $runbookJobOutput to determine this
                    foreach ($key in $hashtable.Keys) {
                        # suppress output key'd with the following undesired keys, usually is not helpful to proxy these messages due to formatting 
                        # error msgs are still returned, just not 100% of the information 
                        if ($key -in @("ErrorDetails", "CategoryInfo", "PipelineIterationInfo", "FullyQualifiedErrorId", "OriginInfo", "TargetObject", "InvocationInfo", "ScriptStackTrace")) {
                            continue
                        }

                        switch ($key) { ###### may be able to update this at some point to loop through all & reformat data, and THEN just do 1x .AddRange but maybe not worth effort for probably small efficiency gains
                            "value" {
                                # Just display the value for this key, no additional parsing needed
                                $output = $hashtable[$key].ToString()
                                continue
                            }
                            "Exception" {
                                # tag errors with this to identify later and convert from JSON 
                                $errorCaught = $true # logging this because we are needing to get Exception msg if job status was failed and there was no error msg in output
                                $output = ("___EXCEPTION___$($hashtable[$key].ToString())")
                                continue
                            }
                            default {
                                # Prefix other keys with their name followed by a colon
                                # $key = name of the property for whatever object property was output in console
                                # $($hashtable[$key]) = value of the property for whatever object was output in the console
                                $output = "$($key): $($hashtable[$key])"
                                continue
                            }
                        }
                        
                        # begin processing output from parsed data

                        switch($output){
                            {$_.Contains("___EXCEPTION___")} { 
                                $errorDetails = $hashtable["Exception"].ToString() | ConvertFrom-Json
                                
                                $message,$categoryInfo,$errorCategory,$invocationInfo,$errorId = $null # reset vars on each loop

                                # check the 2 error properties for stored error message
                                foreach($errorMsg in $errorDetails.Message,$errorDetails.ErrorRecord.Exception)
                                {
                                    if($errorMsg) # choose the 1st one available
                                    {
                                        # create exception obj
                                        $message = $errorMsg
                                        break # we want the 1st valid value
                                    }
                                }

                                if($hashtable["CategoryInfo"])
                                {
                                    $categoryInfo = $hashtable["CategoryInfo"].ToString() | ConvertFrom-Json
                                    #$message = "$($categoryInfo.Activity) : $($message)"

                                    $resolveErrorCategory = @{} # make definition list for ID -> value
                                    [System.Enum]::GetValues([System.Management.Automation.ErrorCategory]) | ForEach-Object { $resolveErrorCategory.Add([int]$_, $_) }

                                    # confirm error category exists, if not change to not specified.
                                    if ([System.Enum]::IsDefined([System.Management.Automation.ErrorCategory], $($resolveErrorCategory[$categoryInfo.Category]))) {
                                        $errorCategory = [System.Management.Automation.ErrorCategory]::$($resolveErrorCategory[$categoryInfo.Category])
                                    } else {
                                        $errorCategory = [System.Management.Automation.ErrorCategory]::NotSpecified
                                    }
                                }

                                if($hashtable["InvocationInfo"])
                                {
                                    $invocationInfo = $hashtable["InvocationInfo"].ToString() | ConvertFrom-Json
                                    $message = "$($message) `n$($invocationInfo.PositionMessage)"
                                }

                                if($hashtable["FullyQualifiedErrorId"])
                                {
                                    $errorId = $hashtable["FullyQualifiedErrorId"]
                                }

                                $ErrorView = 'ConciseView'

                                Write-Error -ErrorId $errorId -Message $message -Category $errorCategory -CategoryActivity $categoryInfo.Activity -CategoryReason $categoryInfo.Reason -CategoryTargetName $categoryInfo.TargetName -CategoryTargetType $categoryInfo.TargetType -TargetObject $errorDetails.ErrorRecord.TargetObject

                                $runbookJobOutput.Add($message) | Out-Null # add parsed output to arrayList, not used/necessary by default but could be useful for some use cases?


                                #write-error -Exception #### reminder: may be able to parse + add additional ErrorMsg properties into this in future, but this works great as is
                                if(-Not $message)
                                {
                                    Write-Error "ERROR THROWN - FOLLOW UP W/ ITES FOR ADDITIONAL INFORMATION IF NECESSARY..." -ErrorAction Continue
                                }
                                continue # next loop
                            }
                            default {
                                $runbookJobOutput.Add($_) | Out-Null # add parsed output to arrayList, not used/necessary by default but could be useful for some use cases?
                                write-debug $_
                            }
                        }
                    } # end loop thru hashtable
                } # end loop thru $rawAutomationJobOutput
            } # end running / completed switch block 
            
        }

        # if job failed and the error was not caught in output, grab it from 'exception stream'
        # some jobs will "Fail" but not write error to the output of the job -- it makes no sense but this is a work around
        if(($job.Status -eq "Failed") -and (-Not $errorCaught))
        {
            $exceptionMessageThrown = (Get-AzAutomationJob -Id $runbookJobId -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName).Exception
            # i personally dont think the disclaimer about the errorActionPref is useful so I remove it and replace with Write-Error which is useful for identifying errors in output
            $exceptionMessageThrown = $exceptionMessageThrown.Replace('The running command stopped because the preference variable "ErrorActionPreference" or common parameter is set to Stop: ',"Write-Error : ")
        }   

        if((-Not $errorCaught) -and ($exceptionMessageThrown))
        {
            Write-Error -message $exceptionMessageThrown -ErrorAction Continue

            $runbookJobOutput.Add($exceptionMessageThrown)
        }

        if($job.Status -in $jobCompletedStates) {
            
            $jobCompleted = $true 
        }

    } Until ( $jobCompleted -or ($currentTime -ge $expirationTime))

    Write-Debug "`n`n`n" # creates nice 3 line break for identifying output in readibots easier + easier reading 

    if($jobCompleted) {
        Write-Debug "Get-AzJobOutput: Job $runbookJobId is $($job.Status)..."
    }

    # update job status line in stored output
    $runbookJobOutput[3] = $job.Status

    # since 0-3 are informational lines, count of 4 = no addtl output
    if($runbookJobOutput.count -eq 4) { 
        Write-Debug "Get-AzJobOutput: Job $runbookJobId seemed to have no output (this may be expected)..."
    }

    if(($currentTime -ge $expirationTime)) {
        Write-Error "Get-AzJobOutput: Job $runbookJobId was not determined to be complete after $maxWaitTimeOut minutes of looping; please follow up with ITES if necessary."
    }

    if($formatOutputForEmail){ # if we are emailing output, there is additional formatting in HTML needed
        # build subject
        # can reference w/ New-ITESEmail func. if wanted
        $global:subject = " Execution $($job.Status) at $(Get-Date -UFormat '%r (%Z UTC)')"

        Write-Debug 'Get-AzJobOutput: Converting Runbook output stored in $RunbookJobOutput to HTML for email'
        Write-Debug 'Get-AzJobOutput: $subject populated for email subject:'$subject

        for ($i = 0; $i -lt $runbookJobOutput.Count; $i++) {
            switch($i)
            {
                # First 5 items in the ArrayList = informational containing runbook name/job id/execution time/etc
                0 { # Runbook Name
                    $runbookJobOutput[$i] = '<table><tr><td style="text-align: right; padding-right: 10px; vertical-align: top;"><strong>' + 'Runbook Name' + '</strong></td><td style="vertical-align: top;">:</td><td style="padding-left: 10px; vertical-align: top;">' + $runbookJobOutput[$i] + '</td></tr>'
                    continue
                }
                1 { # Runbook Job ID
                    $runbookJobOutput[$i] = '<tr><td style="text-align: right; padding-right: 10px; vertical-align: top;"><strong>' + 'Runbook Job ID' + '</strong></td><td style="vertical-align: top;">:</td><td style="padding-left: 10px; vertical-align: top;">' + $runbookJobOutput[$i] + '</td></tr>'
                    continue
                }
                2 { # Start time of runbook in AA
                    $runbookJobOutput[$i] = '<tr><td style="text-align: right; padding-right: 10px; vertical-align: top;"><strong>' + 'Runbook Job Creation Time' + '</strong></td><td style="vertical-align: top;">:</td><td style="padding-left: 10px; vertical-align: top;">' + $runbookJobOutput[$i] + '</td></tr>'
                    continue
                }
                3 { # Runbook job status (completed, failed, stopped, etc)
                    $runbookJobOutput[$i] = '<tr><td style="text-align: right; padding-right: 10px; vertical-align: top;"><strong>' + 'Runbook Job Status' + '</strong></td><td style="vertical-align: top;">:</td><td style="padding-left: 10px; vertical-align: top;">' + $runbookJobOutput[$i] + '</td></tr>'
                    continue
                }
                4 { # Readibots Bot Name
                    if($runbookJobOutput[$i] -eq $sessionvars.ProcessLoggingHelper.ScriptPath){
                        $runbookJobOutput[$i] = '<tr><td style="text-align: right; padding-right: 10px; vertical-align: top;"><strong>' + "Readibots Bot (started by $($sessionvars['CbUserName']))" + '</strong></td><td style="vertical-align: top;">:</td><td style="padding-left: 10px; vertical-align: top;">' + $runbookJobOutput[$i] + '</td></tr></table>'
                        continue
                    }
                }

                default { # all other output
                    if($runbookJobOutput[$i] -match "Write-Error") { # additional html formatting to make error text red
                        $runbookJobOutput[$i] = '<p style="color: red; font-weight: bold; text-decoration: underline;">' + $runbookJobOutput[$i] + '</p>' -replace "At line:","<br>At line:"
                    }
                }
            }
        }

        # this ensures each output line is on a new line in the email. 
        $runbookJobOutput = $runbookJobOutput -join "<br>" 
    }
}

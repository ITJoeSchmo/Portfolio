<#
.SYNOPSIS
    Retries execution of the erroring line with an exponential back-off strategy.

.DESCRIPTION
    The Redo-WithExponentialBackoff function attempts to execute the command which resulted in an error from within a Try block.
    This is particularly useful for tasks that may encounter transient errors and need to be retried with an increasing interval for highest chance of success. E.g. if an API is overloaded
    The function takes the ErrorRecord $_ in the Catch block as input.

    *It is important to keep in mind that when leveraging this, there should only be 1 line within the Try block, as that is all that will be re-executed.
    *If there are important lines in the same Try block, they would not be executed unless input in the Catch block, so it would be best to just put them in their own block.

.PARAMETER ErrorRecord
    The ErrorRecord within a Catch block is referencable as $_ . This needs passed to the function which will extract the line which threw an error from the ErrorRecord.InvocationInfo.Line property and execute it again with delays.

.PARAMETER MaxRetries
    Specifies the maximum number of retries before giving up. The default is 3 retries.

.PARAMETER InitialDelay
    Specifies the initial delay in seconds before the first retry attempt. The default value is 15 seconds.

.PARAMETER BackoffFactor
    Specifies the factor by which the delay increases after each retry. The default value is 2.0, doubling the delay with each retry.

.EXAMPLE

    Try {
        Get-ChildItem -Path "asdjiasdasd" -ErrorAction stop
    } Catch {
        Redo-WithExponentialBackoff -ErrorRecord $_ -InitialDelay 2
    }

    OUTPUT:

    Re-executing the following ScriptBlock with exponential back-off:
	    Get-ChildItem -Path "asdjiasdasd" -ErrorAction stop
    Execution failed retrying in 2 seconds... Error message: Cannot find path 'C:\WINDOWS\system32\asdjiasdasd' because it does not exist. 
    Execution failed retrying in 4 seconds... Error message: Cannot find path 'C:\WINDOWS\system32\asdjiasdasd' because it does not exist. 
    Operation failed after 3 retries... Throwing Last ErrorRecord:
    Get-ChildItem : Cannot find path 'C:\WINDOWS\system32\asdjiasdasd' because it does not exist.
    At line:1 char:1
    + Get-ChildItem -Path "asdjiasdasd" -ErrorAction stop
    + ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        + CategoryInfo          : ObjectNotFound: (C:\WINDOWS\system32\asdjiasdasd:String) [Get-ChildItem], ItemNotFoundException
        + FullyQualifiedErrorId : PathNotFound,Microsoft.PowerShell.Commands.GetChildItemCommand

.NOTES
    Author: Joey Eckelbarger
#>

function Redo-WithExponentialBackoff {
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [int]$MaxRetries = 3,
        [int]$InitialDelay = 30, # Initial delay in seconds; this will progress as 30 -> 60 -> 120
        [double]$BackoffFactor = 2.0
    )

    # trim whitespace + create scriptblock object
    # can't seem to natively convert a string -> scriptblock obj without using this .NET method
    $ScriptBlock = [Scriptblock]::Create(($ErrorRecord.InvocationInfo.Line).Trim())

    Write-Output "Re-executing the following ScriptBlock with exponential back-off:`n`t$ScriptBlock"

    $currentRetry = 1

    while ($currentRetry -le $MaxRetries) {
        try {
            # Try to execute the script block again
            & $ScriptBlock
            Write-Output "Operation succeeded on retry #$($currentRetry)."
            return
        } catch {
            $newErrorRecord = $_

            # If an error occurs, calc delay for next re-try.
            $delay = [math]::Pow($BackoffFactor, $currentRetry-1) * $InitialDelay
            $currentRetry++

            Write-Output "Execution failed retrying in $delay seconds... Error message: $($newErrorRecord.Exception.Message) "
            Start-Sleep -Seconds $delay
            
        }
    }

    if ($currentRetry -ge $MaxRetries) {
        Write-Output "Operation failed after $MaxRetries retries... Throwing Last ErrorRecord:"
        Write-Error $newErrorRecord
        throw $newErrorRecord
    }
}

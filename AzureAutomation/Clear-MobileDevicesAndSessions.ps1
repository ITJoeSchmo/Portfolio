<#
.SYNOPSIS
    Clears all active login sessions via MSGraph and trusted devices for a specified user in Exchange.

.DESCRIPTION
    This runbook is specifically designed to be used in response to security incidents where an account is identified as compromised.
    It ensures that any active sessions and trusted devices associated with the specified user are promptly cleared to prevent further unauthorized access.

.PARAMETER Username
    Specifies the username of the compromised account for which active sessions and trusted devices need to be cleared.
    Type: String
    Required: True
    Position: 0

.EXAMPLE
    Clear-MobileDevicesAndSessions.ps1 -Username "johndoe"
    Description: Clears all active login sessions and removes all trusted devices for the user 'johndoe' in Exchange.

.NOTES
    Author: Joey Eckelbarger
#>

param(
    [string]$Username
)

Connect-ExchangeOnline

if($Username -like "* *"){
    Write-Output "Username had whitespace; removing..."
    $Username = $Username.Trim() # remove leading/trailing whitespace if present
}

[array]$ActiveSyncDevices = Get-MobileDevice -Mailbox $Username -ResultSize Unlimited
foreach ($Device in $ActiveSyncDevices)
{
    # shifted to GUID as just using the whole Device object piped into Remove-MobileDevice sometimes results in an error about multiple mailboxes matching the Identity criteria
    $GUID = $Device.Guid.Guid 

    Try {
        Remove-MobileDevice -Identity $GUID -Confirm:$false
        Write-Output "Removed Device with GUID: $GUID under user $Username"
    } Catch {
        Write-Error "Failed to remove Device with GUID: $GUID under user $Username"
    }
}

if(-not $ActiveSyncDevices){
    Write-Output "User has no ActiveSync devices..."
}

# connect graph
Connect-MgGraphb -Identity -NoWelcome

$userPrincipalName = "$Username@domain.edu"

Write-Output "Revoking active SignIn sessions for user $userPrincipalName"
Revoke-MgUserSignInSession -UserId $userPrincipalName

Disconnect-ExchangeOnline -Confirm:$false | Out-Null

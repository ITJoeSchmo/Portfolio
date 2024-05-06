# this runbook is triggered via API call by the security team when an account is identified as compromised.
# it clears all active login sessions + devices trusted by exchange. 

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
. ./Connect-MgGraph.ps1 

$userPrincipalName = "$Username@domain.edu"

Write-Output "Revoking active SignIn sessions for user $userPrincipalName"
Revoke-MgUserSignInSession -UserId $userPrincipalName

Disconnect-ExchangeOnline -Confirm:$false | Out-Null

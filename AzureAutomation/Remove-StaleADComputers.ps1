# written by Joey Eckelbarger 2023
# a script to delete computer objects once their last logon date has hit the defined threshold $DateLimit + log the deleted computers to a .csv

$fileSharePath = "C:\scripts\Stale Computers"

$vault_creds = Get-AutomationPSCredential -Name 'Vault_AzureAutomation_Approle'
Connect-Vault -vaultaddress "vault.domain.com" -Credential $vault_creds
$Entra_Cred = Read-VaultSecret -enginepath "engine/path" -secretpath "path/to/secret" -keyname "EntraID_Admin"

Connect-MgGraph -Identity -NoWelcome

# Set the threshold for stale computers
$DaysInactive = 360
$CurrentDate = Get-Date
$DateLimit = $CurrentDate.AddDays(-$DaysInactive)

# Get all computer accounts that have not signed in since the date limit
$StaleComputers = Get-ADComputer -Credential $Entra_Cred -Filter {LastLogonDate -lt $DateLimit} -Properties LastLogonDate,ProtectedFromAccidentalDeletion,ObjectGUID

# Output the stale computers to a file before deletion (optional but recommended for auditing purposes)
$StaleComputers | select Name,LastLogonDate | Export-CSV -path "$fileSharePath\staleComputers.csv" -NoTypeInformation -Force -Append

# Iterate over each stale computer
foreach ($Computer in $StaleComputers) {
    
    $entraDevice = Get-MgDevice -Filter "DeviceId eq '$($Computer.objectGUID)'"
    
    # if the device has checked in with Entra w/in the last 210 days, skip
    if($entraDevice.ApproximateLastSignInDateTime -gt $DateLimit){
        continue # skip iteration 
    }

    # Output the name of the computer being removed
    write-output "Removing $($Computer.Name)"
    
    if($computer.ProtectedFromAccidentalDeletion){
        write-output "$($Computer.Name) protected from accidental deletion, skipping..."
    } else {
        # Remove the computer object from AD
        try {
            Remove-ADComputer $Computer -Credential $Entra_Cred -Confirm:$false 
        } catch {
            # if the object contains children it will error out and have to use remove-adobject to remove object. 
            try {
                Remove-ADObject $Computer -Recursive -Credential $Entra_Cred -Confirm:$false 
            } catch {
                write-output "Failed to remove $($Computer.Name) but the object is not protected from deletion..."
                write-error $_
            }
        }
    }
}

# written by Joey Eckelbarger
# this runbook triggers a delta sync from AD -> Entra ID. In some cases we need to run these ad-hoc in our other automated processes so that things can happen in a timely fashion.
# generally they only take 30 seconds to 2 minutes to complete per looking at logs of the last ~30 syncs.

$vault_creds = Get-AutomationPSCredential -Name 'Vault_AzureAutomation_Approle'
Connect-Vault -vaultaddress "vault.domain.com" -Credential $vault_creds
$AD_Creds = Read-VaultSecret -enginepath "engine/path" -secretpath "path/to/secret" -keyname "Administrator@domain.com"

$Session = New-PSSession -ComputerName "EntraIDConnect.domain.com" -Credential $AD_Creds
Import-PSSession -Session $Session -Module ADSync | Out-null

# check sync status
$syncInProgress = (Get-ADSyncScheduler).SyncCycleInProgress 

# if a sync is in progress, wait for it to complete.
if ($syncInProgress){ 
    Write-Output "Start-ADSyncCycle: Entra ID Sync is already in progress; once it completes another delta sync will be initiated..."
    Do {
        start-sleep -seconds 5
        $syncInProgress = (Get-ADSyncScheduler).SyncCycleInProgress

    } Until ($syncInProgress -eq $false)
}

Try {
    Start-ADSyncSyncCycle -PolicyType Delta | Out-null
    Write-Output "Start-ADSyncCycle: On-prem AD -> Entra ID Delta Sync has successfully started!"
} Catch {
    Write-Output "Start-ADSyncCycle: Failed to initiate sync cycle!"
    Write-Error $_ 
    Throw
}

Write-output "Start-ADSyncCycle: Waiting for sync to complete..."
$syncInProgress = $true 
Do
{
    start-sleep -seconds 5
    $syncInProgress = (Get-ADSyncScheduler).SyncCycleInProgress

} Until ($syncInProgress -eq $false)
Write-output "Start-ADSyncCycle: Entra ID Sync has completed."

$Session | Remove-PSSession 

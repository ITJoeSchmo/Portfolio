<#
.SYNOPSIS
    Triggers a delta synchronization from Active Directory to Entra ID.

.DESCRIPTION
    The Start-ADEntraSyncCycle.ps1 runbook triggers a delta synchronization from Active Directory to Entra ID.
    This runbook is useful for scenarios where timely synchronization between Active Directory and Entra ID is critical.
    It helps ensure that updates made in AD are quickly propagated to Entra ID, minimizing delays in automated processes.
    The delta sync generally takes 30 seconds to 2 minutes to complete, based on logs from the last 30 syncs.

.EXAMPLE
    Start-ADEntraSyncCycle.ps1
    Description: Triggers a delta synchronization from Active Directory to Entra ID, ensuring that changes in AD are promptly reflected in Entra ID.

.NOTES
    Author: Joey Eckelbarger
#>


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

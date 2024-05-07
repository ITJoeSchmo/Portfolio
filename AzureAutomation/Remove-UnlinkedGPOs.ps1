# written by Joey Eckelbarger 2023
# This script tracks unlinked GPOs in a local .csv and once they have hit the defined threshold of days consistently being unlinked, they will be deleted. 

$fileSharePath = "C:\scripts\Unlinked GPOs"
$csvFilePath = "$fileSharePath\unlinkedGPOs.csv"

$vault_creds = Get-AutomationPSCredential -Name 'Vault_AzureAutomation_Approle'
Connect-Vault -vaultaddress "vault.domain.com" -Credential $vault_creds
$AD_Creds = Read-VaultSecret -enginepath "engine/path" -secretpath "path/to/secret" -keyname "Administrator@domain.com"

if(Test-Path -Path $csvFilePath){
    # Import previous unlinked GPOs
    $unlinkedGPOs = Import-Csv -Path $csvFilePath
} else {
    # Create empty CSV w/ expected headers 
    $headers = '"DisplayName","DistinguishedName","UnlinkedDate","gPCFileSysPath","Created","GpoStatus"'
    $headers | Out-File -FilePath $csvFilePath -Encoding utf8 -Force

    $unlinkedGPOs = Import-Csv -Path $csvFilePath
}

# Get all GP objects
try {
    $allGPOs = Get-ADObject -Credential $AD_Creds -Filter { ObjectClass -eq 'groupPolicyContainer' } -Properties * -ErrorAction Stop
} catch {
    write-error $_
    throw
}


# Filter out GPOs tagged as Conflict objects (CNF)
$allGPOs = $allGPOs | Where-Object { $_.CN -notmatch "CNF:" }

# Filter out GPOs with "template" in the name
$allGPOs = $allGPOs | Where-Object { $_.DisplayName -notlike "*template*" }

# Get all OU objects
$allOUs = Get-ADOrganizationalUnit -Credential $AD_Creds -Filter * -Properties LinkedGroupPolicyObjects

# Get Domain object
$domain = Get-ADDomain -Credential $AD_Creds

# populate linked GPOs w/ DNs from domain and OU linked GPOs
$linkedGPOs = $allOUs.LinkedGroupPolicyObjects + $domain.LinkedGroupPolicyObjects

# Get all unlinked GPOs
# Site linked GPOs would ALWAYS be unlinked with the below method, but our environment does not have any
$gpoQuery = $allGPOs | Where-Object { $linkedGPOs -notcontains $_.DistinguishedName }

# remove GPOs from CSV if they are no longer unlinked (no longer part of the gpoquery results)
$unlinkedGPOs = $unlinkedGPOs | Where-Object { $_.DistinguishedName -in $gpoQuery.DistinguishedName }

# Filter out GPOs already in $unlinkedGPOs
[array]$newUnlinkedGPOs = $gpoQuery | Where-Object { ($_.DistinguishedName -notin $unlinkedGPOs.DistinguishedName) } 

# this is to resolve the "Flags" attribute of the object
$resolveFlag = @{
    0 = "AllSettingsEnabled"
    1 = "UserSettingsDisabled"
    2 = "ComputerSettingsDisabled"
    3 = "AllSettingsDisabled"
}

# Select applicable properties and add the UnlinkedDate and GpoStatus property to the object 
$newUnlinkedGPOs = $newUnlinkedGPOs | Select-Object DisplayName,DistinguishedName,@{Name='UnlinkedDate';Expression={Get-Date}},gPCFileSysPath,Created,@{Name='GpoStatus';Expression={$resolveFlag[$_.flags]}}
if($null -eq $newUnlinkedGPOs){
    Write-Output "0 unlinked GPOs found since last run"
} else {
    Write-Output "$($newUnlinkedGPOs.count) unlinked GPOs found since last run"
}

# Merge old and new unlinked GPO data
$unlinkedGPOs = $unlinkedGPOs + $newUnlinkedGPOs

# Determine GPOs unlinked > 210 days ("expired")
# specify array because if there is 1 result the for loop would error out
[array]$expiredGPOs = $unlinkedGPOs | Where-Object { ((Get-Date) - [DateTime]$_.UnlinkedDate).Days -gt 210 } 

# Loop through "expired" GPOs and backup/remove
foreach($GPO in $expiredGPOs){
    #get GUID from end of path
    $GpoID = $GPO.gPCFileSysPath.Split("\")[-1]

    # Remove the GPO
    Write-Output "Deleting Unlinked GPO: $($GPO.DisplayName) ($($GPO.DistinguishedName))"
    Remove-ADObject $GPO.DistinguishedName -Recursive -Confirm:$false -Credential $AD_Creds

    # mount SysVol path to avoid double hop error when cleaning up
    if(-Not (Test-Path("SysVol:"))){
        New-PSDrive -Credential $AD_Creds -Name "SysVol" -PSProvider FileSystem -Root '\\domain.com\SysVol\domain.com\Policies' | out-null
    }

    # remove SysVol folders/files
    Remove-Item -Path "SysVol:\$GpoID" -Recurse -Force
}

# remove deleted GPOs from the $unlinkedGPOs variable
$unlinkedGPOs = $unlinkedGPOs | Where-Object { $_.DistinguishedName -notin $expiredGPOs.DistinguishedName }

# Update the CSV
$unlinkedGPOs | Export-Csv -Path $csvFilePath -NoTypeInformation -Force

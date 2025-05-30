<#
.SYNOPSIS
    Checks for and updates the VMware Tools package in MECM if a newer version is available.

.DESCRIPTION
    This runbook compares the latest VMware Tools installer from the official VMware repository with the version currently available in the MECM file share. 
    If a newer version is found, it updates the installer on the shared drive, modifies the detection script and software version in MECM, redistributes content, 
    and redeploys the application to specific device collections. It optionally supports limiting deployment to QA and test collections using the -TestQA flag.

.PARAMETER TestQA
    A boolean switch that, when enabled, limits deployment to QA and test environments only
    If disabled (default), the script performs a full update and deployment process, including the primary production collection "VMWare Tools - Install".

.EXAMPLE
    .\Update-VMwareTools.ps1
    Executes the script to check for updates and deploy the latest VMware Tools package to all collections, including production.

.EXAMPLE
    .\Update-VMwareTools.ps1 -TestQA $true
    Runs the update and deployment process only for QA and testing environments.

.NOTES
    Author: Joey Eckelbarger
    Last Edit: 2025-04-01
    Version: 1.0 - Initial implementation for updating MECM with the latest VMware Tools package.
#>
param(
    [Boolean]$TestQA = $false # deploy only to TEST/QA/DEV collection(s)
)

$fileshare_sa   = Read-VaultSecret -enginepath "it_infra/kv" -secretpath "ad/domain.tld/fileshare_sa@domain.tld" -keyname "fileshare_sa@domain.tld"
$MECM_sa        = Read-VaultSecret -enginepath "it_infra/kv" -secretpath "ad/domain.tld/MECM_sa@domain.tld" -keyname "MECM_sa@domain.tld"

# clean up drives -- prevents the error about the disk being mapped already -- annoying quirk with AzureAutomation 
& { net use * /delete /y } | Out-null

New-PSDrive -Name "VMTools" -Root "\\fileshare\it_infra_apps\Installers\VMTools" -PSProvider "FileSystem" -Credential $fileshare_sa -ErrorAction Stop 

# download latest tools 
$tempDir             = New-TemporaryDirectory -suffix "vmwareTools"
$vmToolsRelativePath = Invoke-WebRequest -uri "https://packages.vmware.com/tools/releases/latest/windows/x64/" -UseBasicParsing | Select-Object -ExpandProperty Links | Select-Object -ExpandProperty href | Sort-object -Descending | Select-object -first 1
$vmToolsDownloadURL  = "https://packages.vmware.com/tools/releases/latest/windows/x64/$vmToolsRelativePath"

Invoke-WebRequest -uri $vmToolsDownloadURL -Outfile "$tempDir\setup64.exe" -ErrorAction Stop 

# Get + compare MECM VMware Tools version to latest version 
$latestToolsVersion = Get-Item "$tempDir\Setup64.exe" | Select -ExpandProperty VersionInfo | Select -ExpandProperty ProductVersion
[version]$latestToolsVersionWithoutRevision = ($latestToolsVersion -split "\." | Select-Object -SkipLast 1) -join "."
[version]$latestToolsVersion = $latestToolsVersion

$mecmToolsVersion   = Get-Item "VMTools:\Setup64.exe" | Select -ExpandProperty VersionInfo | Select -ExpandProperty ProductVersion
[version]$mecmToolsVersionWithoutRevision = ($mecmToolsVersion -split "\." | Select-Object -SkipLast 1) -join "."
[version]$mecmToolsVersion = $mecmToolsVersion

if($latestToolsVersion -gt $mecmToolsVersion -or $TestQA -eq $false){
    # we want the one w/o revision for updating detection/install methods
    $currentVersion = $mecmToolsVersionWithoutRevision
    $newVersion     = $latestToolsVersionWithoutRevision

    $CMApplicationName    = "VMware Tools"
    $CMDeploymentTypeName = "VMware tools x64 setup"

    Write-Output "New version $newVersion of VMware Tools was available, updating Application '$CMApplicationName' in MECM..."

    $primaryCollection = "VMWare Tools - Install"
    $testQACollections = "TestDev and QA","IT_INFRA_Testing"

    if($latestToolsVersion -eq $mecmToolsVersion -and $TestQA -eq $false){
        try {
            Write-Output "VMwareTools is up-to-date and only needs deployed to PROD"
            Connect-MECM {
                Get-CMApplication $CMApplicationName | New-CMApplicationDeployment -AvailableDateTime '01/01/2020 00:00:00' -CollectionName $primaryCollection -DeployAction Install -DeployPurpose Required  -UserNotification DisplaySoftwareCenterOnly -ErrorAction Stop
            }
            Write-Output "Created deployment to $primaryCollection"
        } catch {
            Throw $_ 
        }

        Exit 
    }

    Try {
        Copy-Item "$tempDir\setup64.exe" -destination "VMTools:\Setup64.exe" -Force -ErrorAction Stop
        Write-Output "Copied new setup64.exe to File share..." 
    } Catch {
        Throw $_ 
    }

    Connect-MECM

    Try {

        # get CM deployment script
        $CMDeploymentType = get-CMDeploymentType -ApplicationName $CMApplicationName -DeploymentTypeName  $CMDeploymentTypeName
        
        $ApplicationXML = [Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer]::DeserializeFromString($CMDeploymentType.SDMPackageXML, $true)
        $currentScriptText = $ApplicationXML.DeploymentTypes[0].Installer.DetectionScript.Text 
        
        # update the version in the detection script
        $updatedScriptText = $currentScriptText.Replace($currentVersion,$newVersion)
        Set-CMMsiDeploymentType -ApplicationName $CMApplicationName -DeploymentTypeName $CMDeploymentTypeName -ScriptText $updatedScriptText -ScriptLanguage PowerShell -ErrorAction Stop 
        Write-Output "Updated ScriptText replacing '$currentVersion' with '$newVersion'"

        # update version of the application itself
        Set-CMApplication $CMApplicationName -SoftwareVersion $newVersion -Description "Updated to $newVersion on $(Get-Date)"
        Write-Output "Updated Application version to $newVersion"

        # remove current deployments
        Get-CMApplication $CMApplicationName | Get-CMApplicationDeployment | Remove-CMApplicationDeployment -Force -ErrorAction Stop 
        Write-Output "Removed all deployments of $CMApplicationName"
        
        # update conent 
        Update-CMDistributionPoint -ApplicationName $CMApplicationName -DeploymentTypeName $CMDeploymentTypeName -ErrorAction Stop 
        Write-Output "Updated CM Distribution Points with $CMApplicationName"

        # Redeploy to collections 

        foreach($collection in $testQACollections){
            Get-CMApplication $CMApplicationName | New-CMApplicationDeployment -AvailableDateTime '01/01/2020 00:00:00' -CollectionName $collection -DeadlineDateTime '01/01/2020 00:00:00' -DeployAction Install -DeployPurpose Required -UserNotification DisplaySoftwareCenterOnly -ErrorAction Stop 
            Write-Output "Created deployment for $collection "
        }

    } Catch {
        Throw $_ 
    }
} else {
    Write-Output "No updates to be created. "
}

#Requires -RunAsAdministrator

<#
.DISCLAIMER
    This script is provided "as is" without warranty of any kind, express or implied. Use this script at your own risk. 
    While this solution has been leveraged in a PRODUCTION capacity by my team for over 5 months without issue, the author and contributors are not responsible for any damage or issues caused by the use of this script. 
    Always test scripts in a non-production environment before deploying them into a production setting.

.SYNOPSIS
    Adds a new assembly redirection for Newtonsoft.Json to XML configuration files for PowerShell executables to work-around assembly conflicts.

.DESCRIPTION
    The Add-JsonAssemblyRedirect script inserts a new assembly binding redirection for Newtonsoft.Json into XML configuration files associated with PowerShell executables. 
    This script is particularly useful for working around assembly conflicts when 2 imported modules different versions of the Newtonsoft.Json assembly.

    The script will backup the current configuration file to $ENV:temp, take ownership and grant your user FullControl, then insert the XML into the config, then rollback the ownership/permissions.

.NOTES
    Author: Joey Eckelbarger
    Last Edit: 07-12-2024
#>


[XML]$bindingRedirect = @"
      <assemblyBinding   xmlns="urn:schemas-microsoft-com:asm.v1">          
        <dependentAssembly>             
          <assemblyIdentity name="Newtonsoft.Json"   publicKeyToken="30ad4fe6b2a6aeed" culture="neutral" />             
          <bindingRedirect oldVersion="0.0.0.0-13.0.0.0"   newVersion="13.0.0.0" />           
        </dependentAssembly>         
      </assemblyBinding> 
"@

# Define list of potential configuration files to allow selection from. 

$configFilePaths = @(
    "C:\Packages\Plugins\Microsoft.Azure.Automation.HybridWorker.HybridWorkerForWindows\*\HybridWorkerPackage\HybridWorkerAgent\Orchestrator.Sandbox.exe.config", # Hybrid Worker PowerShell Executing Process Config
    "$PSHOME\powershell.exe.config",    # Windows PowerShell Process Config
    "$PSHOME\powershell_ise.exe.config" # Windows PowerShell ISE Process Config
    "Input Path To Configuration File"  # custom input, should always be the last index -1
)

[array]$configFilesOnHost = foreach($file in $configFilePaths){
    if($file -ne $configFilePaths[-1]){
        $file = Get-ChildItem $file -Recurse -ErrorAction Ignore

        # if present write full path to $configFilesOnHost
        if($file) { 
            $file.FullName 
        }
    } else {
        "Input Path To Configuration File"
    }
}


# write out options to user
foreach($file in $configFilesOnHost){
    Write-Output "[$($configFilesOnHost.IndexOf($file))] $file"
}

$select = Read-Host "`nSelect the config to apply the bindingRedirect for the NewtonSoft.Json assembly (versions 0-13 -> 13)"

# custom input option should always eval to the last index -1
if($configFilesOnHost[$select] -eq $configFilesOnHost[-1]){
    $inputPath = Read-Host "Input the full path to the config"

    $fullPath = (Get-ChildItem $inputPath -Recurse -ErrorAction Ignore).FullName

    # if file is present
    if($fullPath) { 
        $configFilesOnHost[$select] = $fullPath

        Write-Output "Found file"
    } else {
        Throw "File not found at $inputPath"
    }
}

# if there is a selection, continue
if($configFilesOnHost[$select]){
    $startTime = Get-Date # used to confirm .config is modified

    $appConfigPath = $configFilesOnHost[$select]

    # backup targeted config file
    Try {
        $backup = Copy-Item -Path $appConfigPath -Destination "$env:TEMP" -Force -PassThru -ErrorAction Stop
        Write-Output "`n`nCreated backup copy of the config $($backup.FullName)"
    } Catch {
        Throw "Failed to copy backup config to $($env:TEMP); halting execution..."
    }


    # take ownership + grant fullcontrol permissions to config file
    Try {
        $originalACL = Get-ACL $appConfigPath -ErrorAction Stop
        Write-Output "`nRetrieved permissions on file $appConfigPath"
        $newACL = $originalACL

        $objUser    = New-Object System.Security.Principal.NTAccount($env:USERDOMAIN, $env:USERNAME)
        $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($objUser, "FullControl","Allow")

        $newACL.SetOwner($objUser)
        $newACL.AddAccessRule($accessRule)

        Set-ACL $appConfigPath -AclObject $newACL -ErrorAction Stop

        Write-Output "Temporarily took ownership and granted FullControl permissions to $($env:USERNAME) on $appConfigPath"
    } Catch {
        Write-Error "Permissions failed to be retrieved or failed to be set on $($appConfigPath); halting execution..."
        Throw $_
    }


    # import the selected configuration file, check for bindingRedirects, insert the bindingRedirect if one does not already exist for NewtonSoft.Json assembly. 
    Try {
        $appConfig = [XML](Get-Content $appConfigPath -ErrorAction Stop)

        # check for binding redirects of NewtonSoft.Json
        $NewtonsoftJsonRedirects = $appconfig.configuration.runtime.assemblyBinding.dependentAssembly | Where-Object { $_.ChildNodes.name -Contains "Newtonsoft.Json" -and $_.ChildNodes.name -contains "bindingRedirect" }

        # if there are NO bindingRedirects AND NO binding redirects of NewtonSoft.Json, insert them 
        if(-Not $appconfig.configuration.runtime.assemblyBinding -and -Not $NewtonsoftJsonRedirects){
            Write-Output "`n`nInserting redirect into XML..."

            $importedNode = $appconfig.ImportNode($bindingRedirect.assemblyBinding, $true)
            $appconfig.configuration.runtime.InsertAfter($importedNode,$appConfig.configuration.runtime.AppContextSwitchOverrides[-1]) | Out-Null

        # if there is an assemblyBinding within the XML but not for Newtonsoft.Json, we  need to append the XML under dependentAssembly key
        } elseif($appconfig.configuration.runtime.assemblyBinding -and -Not $NewtonsoftJsonRedirects){
            
            Write-Output "`n`nThere are bindingRedirects defined in the configuration, but not for NewtonSoft.Json. Inserting redirect into XML..."
            
            $importedNode = $appconfig.ImportNode($bindingRedirect.assemblyBinding.dependentAssembly, $true)
            $appconfig.configuration.runtime.assemblyBinding.AppendChild($importedNode)  | Out-Null
            
        # if there is already a newtonsoft.json redirect, lets throw an error 
        } elseif($NewtonsoftJsonRedirects) {
            Throw "It appears there is already a binding redirect ($($NewtonsoftJsonRedirects.bindingRedirect.oldVersion) -> $($NewtonsoftJsonRedirects.bindingRedirect.newVersion)) for Newtonsoft.Json in $appConfigPath "
        }

        # save updated XML file. 
        Write-Output "Attempting to save new XML..."
        $appConfig.Save($appConfigPath) | Out-Null

        if((get-childitem $appConfigPath).LastWriteTime -gt $startTime){
            Write-Output "Configuration file successfully updated!"
        } else {
            Write-Error "Updated configuration file failed to save per LastWriteTime on the file..."
        }

    } Catch {
        Throw $_
    } 
    
    # roll back ownership/permissions 
    Try {
        Set-ACL $appConfigPath -AclObject $originalACL -ErrorAction Stop
        Write-Output "`n`nRolled back ownership and permissions on the file $appConfigPath"
    } catch {
        Write-Error "Failed to rollback permissions on $appConfigPath -- set ownership to TrustedInstaller, remove FullControl from $($env:USER)"
        Throw $_
    }

} else {
    Throw "Invalid input"
}

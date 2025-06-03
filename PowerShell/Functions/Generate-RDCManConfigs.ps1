#Requires ActiveDirectory 
<#
.SYNOPSIS
    Generates RDCMan (.rdg) configuration files for each Active Directory domain by querying domain controllers and their associated servers.

.DESCRIPTION
    This script automates the creation of RDCMan (Remote Desktop Connection Manager) configuration files for each domain specified by the user. It queries each provided domain controller for all enabled Windows Server computers and organizes them into groups that reflect their AD path structure. The script creates folders and server nodes within the RDCMan configuration XML and saves each domain's configuration as a separate .rdg file in the specified directory.

.PARAMETER RDCManPath
    Specifies the directory path where the generated RDCMan configuration (.rdg) files will be saved. The directory must exist; otherwise, the script will terminate with an error.

.PARAMETER adServers
    A comma-separated list of fully qualified domain names (FQDNs) for domain controllers. Only one domain controller is needed per domain. These are used to query the Active Directory for server information.

.EXAMPLE
    PS C:\> .\Generate-RDCManConfigs.ps1
    Provide a DIRECTORY to save RDCMan configurations after being generated: C:\RDCConfigs
    Provide a comma-separated list of Domain Controller FQDNs. Only 1 DC from each domain is needed: dc1.contoso.com,dc2.fabrikam.com

    This example prompts the user for input and generates RDCMan configuration files in the specified directory for the domains `contoso.com` and `fabrikam.com`.

.NOTES
    Author: Joey Eckelbarger
#>

$RDCManPath = Read-Host "Provide a DIRECTORY to save RDCMan configurations after being generated"

if(-Not (Test-Path($RDCManPath))){
    Throw "invalid path"
}

[array]$domainNames = $(Read-Host "Provide a comma-separated list of Domains:") -split ","

foreach($domain in $domainNames){

    $Credential = Get-Credential -Message "Input the username/password to be used to authenticate to this domain. `nLeave blank if your current user context is fine. `n`nFormat: DOMAIN\USERNAME or USERNAME@DOMAIN.TLD"

[xml]$RDCManConfigurationXML = @"
<?xml version="1.0" encoding="utf-8"?>
<RDCMan programVersion="2.93" schemaVersion="3">
    <file>
    <credentialsProfiles />
    <properties>
        <expanded>True</expanded>
        <name>CONFIGNAME</name>
    </properties>
    </file>
    <connected />
    <favorites />
    <recentlyUsed />
</RDCMan>
"@

[xml]$groupXML = @"
    <group>
        <properties>
        <expanded>False</expanded>
        <name>GROUPNAME</name>
        </properties>
    </group>
"@

[xml]$serverXML = @"
    <server>
        <properties>
        <displayName>SERVERDISPLAYNAME</displayName>
        <name>SERVERNAME</name>
        </properties>
    </server>
"@

    $servers = Get-ADComputer -Filter 'operatingsystem -like "*server*" -and enabled -eq "true"' -server $domain -Properties Name,CanonicalName,operatingsystem | Sort-Object CanonicalName

    $domainName = $servers[0].CanonicalName.Split("/")[0]

    Write-output "Found $($servers.count) servers in $domainName"

    $RDCManConfigurationXML.RDCMan.file.properties.name = $domainName
    
    foreach($server in $servers){
        $server | Add-Member -NotePropertyName Path -NotePropertyValue $server.CanonicalName.Replace("$domainName/","").Replace("/$($server.name)","") -Force
    }
    
    $serversGroupedByPath = $servers | Group-Object Path 
    
    foreach($server in $servers){
        $foundNode    = @()
        $parentFolder = $null
        $remainingSubfoldersNeeded = $null
    
        $name = $server.Name
        [array]$path = $server.CanonicalName.Replace("$domainName/","").Replace("/$name","").Split("/")
    
        # Use an XPath expression to see if a node matches the fullPath we have already
        $nodeXpathFilterArray = @()
        
        foreach($folder in $path) {
            $nodeXpathFilterArray += if($folder -eq $path[-1]){
                "//properties[name='$($folder)']"
            } else {
                "//group[properties[name='$($folder)']]"
            }
    
            $nodeXpathFilter = $nodeXpathFilterArray -join ""
            $node = $RDCManConfigurationXML.SelectSingleNode($nodeXpathFilter)
    
            if($node){
                $foundNode += $node
            } elseif($foundNode) {
                $start = $path.indexof($folder)
                $end   = ($path.Count - 1)
    
                $remainingSubfoldersNeeded = $path[$start..$end]
                break
            }
        }
    
        if($remainingSubfoldersNeeded -or $foundNode){
            $path = $remainingSubfoldersNeeded
            $parentNode = $foundNode[-1]
    
            # this is where we want to insert our XML
            if($parentNode.server){
                $anchorNode  = $parentNode.server | Select-Object -Last 1  
            } elseif($parentNode.group){
                $anchorNode  = $parentNode.group | Select-Object -Last 1  
            } else {
                $anchorNode  = $parentNode.ParentNode.properties
                $parentNode  = $parentNode.ParentNode
            }
    
        } else {
            # "properties" is a child of "file"
            # this is where we want to insert our XML
            $parentNode  = $RDCManConfigurationXML.RDCMan.file
            if($RDCManConfigurationXML.RDCMan.file.group){
                $anchorNode  = $parentNode.group | Select -last 1 # We'll insert after this
            } else {
                $anchorNode  = $parentNode.properties  # We'll insert after this
            }
        }
    
        if($remainingSubfoldersNeeded -or -Not $foundNode){
            foreach($subfolder in $path){
                $groupXML.group.properties.name = $subfolder
        
                $importedNode = $RDCManConfigurationXML.ImportNode($groupXML.DocumentElement, $true)
        
                # updating parent/anchor nodes because we need to nest subfolders when looping 
                $parentNode = $parentNode.InsertAfter($importedNode, $anchorNode)
                $anchorNode = $parentNode.properties  # We'll insert after this on the next loop if theres a subfolder
        
                $parentFolder = $subfolder
            }
        }
    
        $serverXML.server.properties.name        = "$($name).$($domainName)"
        $serverXML.server.properties.displayName = $name 
        $importedNode = $RDCManConfigurationXML.ImportNode($serverXML.DocumentElement, $true)
    
        [void]$parentNode.InsertAfter($importedNode, $anchorNode)  
    }
    
    Write-output "Saving $domainName.rdg...."
    $RDCManConfigurationXML.Save("$($RDCManPath)\$domainName.rdg")
}


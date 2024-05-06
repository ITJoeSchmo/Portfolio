<#
 .Synopsis
  Authenticate with HashiVault.

 .Description
  Authenticate with HashiVault. 
  This function grabs access token for use in other functions using AppRole auth. 
  MUST be ran before any other functions.

 .Parameter Credential
  Credential object for authenticating with the HashiVault API

 .Parameter VaultAddress
  Address to vault instance. Remove the trailing / 

 .Example
   # Connect to HashiVault

   $vaultCredential = Get-Credential 
   Connect-Vault -VaultAddress "https://vault-tst.com" -Credential $vaultCredential -AuthType LDAP

#>
function Connect-Vault {
    param (
        [Parameter(Mandatory=$true)][PSCredential]$Credential,
        [Parameter(Mandatory=$true)][string]$VaultAddress,
        [ValidateSet("AppRole","LDAP")]
        [Parameter(Mandatory=$false)][string]$AuthType = "AppRole" # Default auth type = AppRole
    )

    # ensure SSL (https) is used
    $VaultAddress = $VaultAddress.Replace("http://","https://")
    # remove trailing slash if present
    if($vaultaddress.EndsWith("/")) {  $VaultAddress = $VaultAddress.TrimEnd("/") }

    # set variable in script scope so it is accessible outside this func
    $script:VaultAddress = $VaultAddress

    switch ($AuthType) {
        "AppRole" {  
            $url = "$VaultAddress/v1/auth/approle/login"

            $Body = @{
                "role_id" = $Credential.UserName
                "secret_id" = $($Credential.GetNetworkCredential().Password)
            } | ConvertTo-Json
        }

        "LDAP"{  
            $username = $Credential.UserName

            $url = "$VaultAddress/v1/auth/ldap/login/$username"

            $Body = @{
                "password" = $($Credential.GetNetworkCredential().Password)
            } | ConvertTo-Json
        }
    }

    try {
        $auth = (Invoke-RestMethod -Method POST -Uri $url -Body $Body -ErrorVariable RestError)
        $script:Token = $auth.auth.client_token | ConvertTo-SecureString -AsPlainText -Force
        if($script:token) { write-output "Access token received" }
    } catch {
        write-output $_.Exception $_.ErrorDetails.Message
        throw "Authentication failed, unable to obtain access token."
    }
}

<#
 .Synopsis
  Write/update secrets in HashiVault

 .Description
  Write/update secrets in HashiVault

 .Parameter EnginePath
  Path to secret engine 

 .Parameter SecretPath
  Path to secret  

 .Parameter Data
  Hashtable containing key/value pairs to update
  or
  PSCredential (username should be set to the key name of the pair to be updated). 

  *Use Hashtable if you need to update multiple key/value pairs in 1 execution. 
  
 .Parameter Append
  Default value: $true

  $True  = retain the key/value pairs already in the specified secret path 
  $False = overwrite all key/value pairs with only the passed $data

 .Example
   # Write secrets from hashtable
   $data = @{
    "Administrator@Primary.Domain.Com"          = "sqyt7$ghSKGq&^GM"
    "ExchangeServiceAccount@Primary.Domain.Com" = "l07gm5&F7@VWlDJA"
   }

   Set-VaultSecret -EnginePath "test_secrets" -secretPath "ad/Primary.Domain.Com" -data $data -Append $true

 .Example
   # Write a secret using PSCredential type
   # Ideally, you're not defining these in-script like below, but for example's sake:

   $username = "Administrator@Primary.Domain.Com"
   $password = "sqyt7$ghSKGq&^GM" | ConvertTo-SecureString -AsPlainText -Force
   
   $credential = [PSCredential]::New($username,$password)

   UserName                       Password
   --------                       --------
   Administrator@Primary.Doma...  System.Security.SecureString

   Set-VaultSecret -EnginePath "test_secrets" -secretPath "ad/Primary.Domain.Com" -data $data -Append $true

#>
function Set-VaultSecret {
    [Alias("Write-VaultSecret")]
    param (
        [Parameter(Mandatory=$true)] [string]$EnginePath,   # KV Engine Path
        [Parameter(Mandatory=$true)] [string]$SecretPath,   # Path to secret
        [Parameter(Mandatory=$true)] $Data,                 # Secret data as Key-Value pairs
        [Parameter(Mandatory=$false)][boolean]$Append=$true # Append (retain other k/v pairs) or overwrite secrets (only retain new data)
    )

    # loop through required variables @ script scope, if null throw an error
    foreach($var in ($script:Token, $script:VaultAddress)){
        if($null -eq $var) { throw "Token or Vault Address is null - please authenticate with Connect-Vault first" }
    }
    
    switch($data.GetType().Name){
        {$_ -in @("PSCredential","Hashtable")}{

            if($_ -eq "PSCredential"){
                $Data = @{
                    $Data.UserName = $Data.GetNetworkCredential().Password
                }
            }

            continue
        }
        
        default{
            Throw "`$Data was not a [Hashtable] or [PSCredential]"
        }
    }

    # check if secret exists, if so we want to query the current keys so we can be additive vs overwriting all 
    $secretList = Get-VaultSecretList -EnginePath $EnginePath -SecretPath $SecretPath

    if($secretPath.Contains("/")){ # if the secret path is a nested folder
        $childrenFolders = $SecretPath.Split("/")
        $bottomLevelFolder = $childrenFolders[-1] # we need to grab the last parent folder of the secrets we are looking for to determine if they exist
    }

    # if the given secret path already exists, pull in current data for appending
    if(($SecretPath -in $secretList -and $Append) -or ($bottomLevelFolder -in $secretList -and $Append)){
        Write-Verbose "Found secret $secretPath, pulling in current key/value pairs so new key/value pairs can be appended..."
        $currentData = Get-VaultSecret -EnginePath $EnginePath -SecretPath $SecretPath -OutputType Hashtable

        # pipe through CurrentData, and any keys not defined in $data hashtable are added to $data hashtable
        # this overwrites old data with new data by key and retains old data with new data                              
        $currentData.keys | Where-Object { $_ -notin $Data.keys } | ForEach-Object { 
            $Data[$_] =  $currentData[$_] 
        }

        $currentData = $null
    }

    $url = "$script:VaultAddress/v1/$EnginePath/data/$SecretPath"

    $headers = @{
        'X-Vault-Token' = $([PSCredential]::new("token", $($script:Token)).GetNetworkCredential().Password)
    }

    $body = @{
        "data" = $Data
    } | ConvertTo-Json

    try {
        $response = (Invoke-RestMethod -Method POST -Uri $url -Headers $headers -Body $body).data

        return $response
    } catch {
        write-error $_ 
    } finally {
        # nulling out the data variable as it is scoped outside the function so it will be persistent + updated to have stored keys
        $global:Data,$headers = $null 
    }
}

<#
 .Synopsis
  List all available secrets in engine/secret path or list all "subkeys" which are the KEYS in the KEY/VALUE pairs in the specified path.
  KEEP IN MIND A "SECRET" IS A SUBFOLDER THAT HOLDS THE ACTUAL KEY/VALUE PAIRS WHICH ARE THE "REAL" SECRETS.

 .Description
  List all available secrets in engine/secret path or list all "subkeys" which are the KEYS in the KEY/VALUE pairs in the specified path.
  KEEP IN MIND A "SECRET" IS A SUBFOLDER THAT HOLDS THE ACTUAL KEY/VALUE PAIRS WHICH ARE THE "REAL" SECRETS. 

 .Parameter EnginePath
  Path to secret engine 

 .Parameter ListSubkeys
  Including -ListSubkeys will return the KEYS of the KEY/VALUE pairs within the given $secretPath
  ***Does not return the secret value; it is returned as "null" from hashivault. 

 .Example
   Get-VaultSecretList -EnginePath "test_secrets"
   
   ad
   entra
   mfa

 .Example
   Get-VaultSecretList -EnginePath "test_secrets" -secretPath "ad"
   
   Primary.Domain.Com
   Secondary.Domain.Com
   Test.Domain.Com

   # these are essentially sub-folders under the path "ad" but Vault calls them a "secret"

 .Example
   Get-VaultSecretList -EnginePath "test_secrets" -secretPath "ad/Primary.Domain.Com" -ListSubkeys
   
   Administrator@Primary.Domain.Com
   ExchangeServiceAccount@Primary.Domain.Com
   DisasterRecoveryAdmin@Primary.Domain.Com

   # this only returns the KEYs of the KEY/VALUE pairs within the given Secret path. 
#>
function Get-VaultSecretList {
    [Alias("Read-VaultSecretList")]
    param (
        [Parameter(Mandatory=$true)] [string]$EnginePath,
        [Parameter(Mandatory=$false)][string]$SecretPath, # used when there are nested folders
        [Parameter(Mandatory=$false)][switch]$ListSubkeys # this means include the KEYs within the folder (not the passwords/values)
    )

    foreach( $var in ($script:Token, $script:VaultAddress)){
        if($null -eq $var) { throw "Token or Vault Address is null - please authenticate with Connect-Vault first" }
    }

    $headers = @{
        'X-Vault-Token' = $([PSCredential]::new("token", $($script:Token)).GetNetworkCredential().Password)
    }

    if($SecretPath){
        if($SecretPath.Contains("/") -and (-Not $ListSubkeys.IsPresent)){
            $splitString = $SecretPath.Split("/")
            $removeLastSplit = $splitString[0..$($splitString.Count - 2)] # index starts @ 1 for .count so we need -2
            $SecretPath = $removeLastSplit -join "/" # path with bottomLevelFolder removed
        } elseif (-Not $ListSubkeys.IsPresent) { # if the SecretPath provided is not a nested folder, it doesnt need defined. Decided to suppress output and just workaround instead of informing user
            #Write-Warning "-SecretPath parameter should be used when the secret path is a nested folder, nulling the defined path as it is not a nested folder (no /s in path)"
            $SecretPath = $null
        }
    }

    if($ListSubkeys.IsPresent){
        $url = "$script:VaultAddress/v1/$EnginePath/subkeys/$SecretPath"
        $subkeys = (Invoke-RestMethod -Method GET -Uri $url -Headers $headers).data.subkeys
        $subkeys = $subkeys.PSObject.Properties | Where-Object { -not $_.Value } | Select-Object -ExpandProperty Name
        return @($subkeys)
    } else {
        $url = "$script:VaultAddress/v1/$EnginePath/metadata/$SecretPath`?list=true"

        return @((Invoke-RestMethod -Method GET -Uri $url -Headers $headers).data.keys)
    }
}

<#
 .Synopsis
   Return the specified secret(s) from HashiVault

 .Parameter EnginePath
   Path to secret engine 

 .Parameter SecretPath
   Path to secret  
   KEEP IN MIND A "SECRET" IS A SUBFOLDER THAT HOLDS THE ACTUAL KEY/VALUE PAIRS WHICH ARE THE "REAL" SECRETS. 

 .Parameter KeyName
   Key name of the secret key/value pair. 
   *Must be used to return a PSCredential object type.

 .Parameter OutputType
   Default: PSCredential
   "Hashtable" or "PSCredential"

   *Use Hashtable if you need to pull multiple secrets in plain text. 
   Storing secrets in PSCredential and then only decrypting the secret when used is best for security. 
   
 .Parameter Version
   Version number of the secret to return
   Without defining, the newest version will be returned.

 .Example
   $adminCredential = Get-VaultSecret -EnginePath "test_secrets" -secretPath "ad/Primary.Domain.Com" -KeyName "Administrator@Primary.Domain.Com"

   $adminCredential.GetNetworkCredential().Password 
   # use this to decrypt the secret when needing it as plain text vs storing as string
   
 .Example
   Get-VaultSecret -EnginePath "test_secrets" -secretPath "ad/Primary.Domain.Com" -KeyName "Administrator@Primary.Domain.Com"
   
   UserName                       Password
   ----                           -----
   Administrator@Primary.Doma...  System.Security.SecureString

 .Example
   Get-VaultSecret -EnginePath "test_secrets" -SecretPath "ad/Primary.Domain.Com" -KeyName "Administrator@Primary.Domain.Com" -Version 2 -OutputType "Hashtable"

   Name                           Value
   ----                           -----
   Administrator@Primary.Doma...  sqyt7$ghSKGq&^GM
#>
function Get-VaultSecret {
    [Alias("Read-VaultSecret")]
    param (
        [Parameter(Mandatory=$true)] [string]$EnginePath,
        [Parameter(Mandatory=$true)] [string]$SecretPath,
        [ValidateSet('Hashtable','PSCredential')]
        [Parameter(Mandatory=$false)][string]$OutputType = "PSCredential",
        [Parameter(Mandatory=$false)][string]$KeyName,      # specify key name if you do not want to return all  key/value pairs from the secret path 
        [Parameter(Mandatory=$false)][int32]$Version        # specify a version of secret, if not specified, it grabs the newest
    )

    # loop through required variables @ script scope, if null throw an error
    foreach( $var in ($script:Token, $script:VaultAddress)){
        if($null -eq $var) { throw "Token or Vault Address is null - please authenticate with Connect-Vault first" }
    }

    if($version){
        $url = "$script:VaultAddress/v1/$EnginePath/data/$($SecretPath)?version=$($Version)"
    } else {
        $url = "$script:VaultAddress/v1/$EnginePath/data/$($SecretPath)"
    }

    if($OutputType -eq "PSCredential" -and -Not $KeyName) {
        throw "Must specify keyname to return PSCredential object"
    }

    $headers = @{
        'X-Vault-Token' = $([PSCredential]::new("token", $($script:Token)).GetNetworkCredential().Password)
    }

    try {
        $response = (Invoke-RestMethod -Method GET -Uri $url -Headers $headers -ErrorVariable RestError).data.data  | ConvertTo-Json

        if($KeyName){
            return Convert-Secret -object $response -KeyName $KeyName -OutputType $OutputType
        } else {
            return Convert-Secret -object $response -OutputType $OutputType
        }
    } catch {
        write-error $_ 
    }
}

<#
 .Description
   Delete the secret subfolder in Vault or a specific key/value pair from a secret using -KeyName

 .Parameter EnginePath
   Path to secret engine 

 .Parameter SecretPath
   Path to secret  

 .Parameter KeyName
   Key name of the specific secret key/value pair to remove. 
   * NOT specifying a KeyName will delete the whole "secret" which is a subfolder holding k/v pairs. 

 .Example
   Remove-VaultSecret -EnginePath "test_secrets" -SecretPath "test" -KeyName "Key1"
#>
function Remove-VaultSecret {
    [Alias("Delete-VaultSecret")]
    param (
        [Parameter(Mandatory=$true)] [string]$EnginePath,
        [Parameter(Mandatory=$true)] [string]$SecretPath,
        [Parameter(Mandatory=$false)][string]$KeyName # clear only a specific key
    )

    # loop through required variables @ script scope, if null throw an error
    foreach( $var in ($script:Token, $script:VaultAddress)){
        if($null -eq $var) { throw "Token or Vault Address is null - please authenticate with Connect-Vault first" }
    }

    if($KeyName){
        $currentData = Get-VaultSecret -EnginePath $EnginePath -SecretPath $SecretPath -OutputType Hashtable
        $currentData.Remove($keyname)  

        Set-VaultSecret -EnginePath $EnginePath -SecretPath $SecretPath -Data $currentData -Append $false
    } else {
        $url = "$script:VaultAddress/v1/$EnginePath/data/$SecretPath"
        $headers = @{
            'X-Vault-Token' = $([PSCredential]::new("token", $($script:Token)).GetNetworkCredential().Password)
        }
    
        try {
            return Invoke-RestMethod -Method DELETE -Uri $url -Headers $headers
        } catch {
            write-error $_ 
        }
    }
}

# Function to Read Secret Metadata from Vault
function Get-VaultSecretMetadata {
    [Alias("Read-VaultSecretMetadata")]
    param (
        [Parameter(Mandatory=$true)] [string]$EnginePath,
        [Parameter(Mandatory=$true)] [string]$SecretPath
    )

    # loop through required variables @ script scope, if null throw an error
    foreach( $var in ($script:Token, $script:VaultAddress)){
        if($null -eq $var) { throw "Token or Vault Address is null - please authenticate with Connect-Vault first" }
    }

    $url = "$script:VaultAddress/v1/$EnginePath/metadata/$SecretPath"
    $headers = @{
        'X-Vault-Token' = $([PSCredential]::new("token", $($script:Token)).GetNetworkCredential().Password)
    }

    try {
        # this return will list metadeta AND applicable version metadata
        return (Invoke-RestMethod -Method GET -Uri $url -Headers $headers).data | Select-Object * -ExpandProperty versions
    } catch {
        write-output $_.Exception $_.ErrorDetails.Message 
    }
}

# Function to Delete Secret Metadata from Vault
function Remove-VaultSecretMetadata {
    [Alias("Delete-VaultSecretMetadata")]
    param (
        [Parameter(Mandatory=$true)] [string]$EnginePath,
        [Parameter(Mandatory=$true)] [string]$SecretPath
    )

    # loop through required variables @ script scope, if null throw an error
    foreach( $var in ($script:Token, $script:VaultAddress)){
        if($null -eq $var) { throw "Token or Vault Address is null - please authenticate with Connect-Vault first" }
    }

    $url = "$script:VaultAddress/v1/$EnginePath/metadata/$SecretPath"

    $headers = @{
        'X-Vault-Token' = $([PSCredential]::new("token", $($script:Token)).GetNetworkCredential().Password)
    }

    try{
        return Invoke-RestMethod -Method DELETE -Uri $url -Headers $headers
    } catch {
        write-output $_.Exception $_.ErrorDetails.Message 
    }
}

<#
 .Description
   Convert returned JSON data from API to PSCredential or Hashtable
   Not intended for use outside of the above functions.

 .Parameter object
   Variable containing the JSON data returned from the API call

 .Parameter KeyName
   Specific Key we want to return the Value of from the secret data

 .Parameter OutputType
   Default: PSCredential
   "Hashtable" or "PSCredential"

   Storing secrets in PSCredential and then only decrypting the secret when used is best for security. 
   Use Hashtable if you need to pull multiple secrets in plain text. 
#>
function Convert-Secret {
    param (
        [Parameter(Mandatory=$true)]$object,
        [Parameter(Mandatory=$false)][string]$KeyName,
        [ValidateSet('Hashtable','PSCredential')]
        [Parameter(Mandatory=$true)] [string]$OutputType
    )

    $secretData = (ConvertFrom-Json $object).psobject.properties
    $secretObject = @{}
    
    foreach($secret in $secretData){
        switch($OutputType){
            "Hashtable"{
                if($KeyName){
                    if($secret.Name -eq $KeyName){
                        $secretObject[$secret.Name] = $secret.Value 
                        break
                    }
                } else {

                    $secretObject[$secret.Name] = $secret.Value
                }
            }

            "PSCredential"{
                if($secret.Name -eq $KeyName){
                    $secretObject = [PSCredential]::new($secret.Name, ($secret.Value  | ConvertTo-SecureString -AsPlainText -Force))
                    
                    break
                }
            }
        }
    }
    
    # if secretobject is null/empty
    if(-Not $secretObject -or $secretObject.Count -eq 0){
        throw "No key named $keyname found under the specified secret/engine paths"
    }

    return $secretObject
}

Export-ModuleMember -Function @("Connect-Vault", "Get-VaultSecretList", "Set-VaultSecret", "Get-VaultSecret", "Remove-VaultSecret", "Get-VaultSecretMetadata", "Remove-VaultSecretMetadata") -Alias @("Write-VaultSecret", "Read-VaultSecret", "Read-VaultSecretList", "Delete-VaultSecretMetadata", "Read-VaultSecretMetadata", "Delete-VaultSecret")

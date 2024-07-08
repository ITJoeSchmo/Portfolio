# There is no native way to resolve these SKUs to their DisplayName, and there is not a public master list available of all SKU:display names 

# I looked at the API calls when looking at licensing in the UI of Azure to find this is what is resolving them on the back-end and can be replicated in-script. 
# Incredibly useful when tying together license data from Graph and such. 

Connect-AzAccount

#74658136-14ec-4630-ad9b-26e160ff0fc6 is the AppId to https://main.iam.ad.ext.azure.com/api/AccountSkus?backfillTenants=false
$Token = (Get-AzAccessToken -ResourceUrl "74658136-14ec-4630-ad9b-26e160ff0fc6").Token | ConvertTo-SecureString -AsPlainText -Force
   
$webData = Invoke-WebRequest -UseBasicParsing -Uri "https://main.iam.ad.ext.azure.com/api/AccountSkus?backfillTenants=false" `
    -Headers @{
        "Authorization"="Bearer $([PSCredential]::new("token", $($script:Token)).GetNetworkCredential().Password)"
    }

#convert JSON to objects
$licenseData = $webData.Content | ConvertFrom-Json 

#make definition hashtable
$resolveLicense = @{}

#populate SKU:name definitions
$licenseData | ForEach-Object { 
  $resolveLicense.Add($_.skuId, $_.name) 
}

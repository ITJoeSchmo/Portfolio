# There is no native way to resolve these SKUs to their DisplayName, and there is not a public master list available of all SKU:display names 

# I looked at the API calls when looking at licensing in the UI of Azure to find this is what is resolving them on the back-end and can be replicated in-script. 
# Incredibly useful when tying together license data from Graph and such. 

Connect-AzAccount
Connect-MgGraph 

#74658136-14ec-4630-ad9b-26e160ff0fc6 is the AppId to https://main.iam.ad.ext.azure.com/api/AccountSkus?backfillTenants=false
$Token = (Get-AzAccessToken -ResourceUrl "74658136-14ec-4630-ad9b-26e160ff0fc6" -AsSecureString).Token

$skuData        = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/subscribedSkus" -Method GET 
[array]$allSKUs = $skuData.Value.skuId + $skuData.Value.servicePlans.servicePlanId | Sort -unique

$Body = @{
      values = $allSKUs
} | ConvertTo-Json
$webData = Invoke-WebRequest -UseBasicParsing -Uri "https://main.iam.ad.ext.azure.com/api/Licenses/CatalogMetadata" -Method POST -ContentType "application/json" -Body $Body -Headers @{
      "Authorization"="Bearer $([PSCredential]::new("token", $($script:Token)).GetNetworkCredential().Password)"
}

$licenseData = $webData.Content | ConvertFrom-Json # convert JSON to objects
$licenseData = $licensedata.PSObject.Properties.Value # license data is actually nested under property where property name = sku ID, this un-tangles that
# populate SKU:name definitions
$resolveLicenseID = @{}
$licenseData | ForEach-Object { $resolveLicenseID[$_.id] = $_.displayName }

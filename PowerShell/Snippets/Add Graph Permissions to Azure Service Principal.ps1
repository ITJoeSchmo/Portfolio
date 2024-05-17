Connect-MgGraph -Scopes Application.Read.All, AppRoleAssignment.ReadWrite.All

# Define these variables
$ManagedIdentityName = "managed_identity_name"
$permissions         = "Mail.send", "AuditLog.Read.All", "Application.Read.All"
$graphAppId          = "00000003-0000-0000-c000-000000000000"

# Get service principal and roles
$getPerms = (Get-MgServicePrincipal -Filter "AppId eq '$graphAppId'").approles | Where {$_.Value -in $permissions}
$ManagedIdentity = (Get-MgServicePrincipal -Filter "DisplayName eq '$ManagedIdentityName'")
$GraphID = (Get-MgServicePrincipal -Filter "AppId eq '$graphAppId'").id

# Assign roles
foreach ($perm in $getPerms){
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentity.Id -PrincipalId $ManagedIdentity.Id -ResourceId $GraphID -AppRoleId $perm.id
}

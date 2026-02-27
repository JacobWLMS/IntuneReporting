#Requires -Modules Az.Resources, Microsoft.Graph.Applications

$MI = "f42f585e-5bae-463b-b425-f62b8f7d4689"
$DCR = "/subscriptions/1a51ea5e-d9ee-453e-94e5-cb61b5cd93cf/resourceGroups/ancIntuneReporting-Dev/providers/Microsoft.Insights/dataCollectionRules/graphreports-dcr"
$LAW = "/subscriptions/1a51ea5e-d9ee-453e-94e5-cb61b5cd93cf/resourceGroups/ancIntuneReporting-Dev/providers/Microsoft.OperationalInsights/workspaces/graphreports-law"

Connect-AzAccount
# DCR: Monitoring Metrics Publisher (data ingestion)
New-AzRoleAssignment -ObjectId $MI -RoleDefinitionName "Monitoring Metrics Publisher" -Scope $DCR -ErrorAction SilentlyContinue
# LAW: Log Analytics Reader (alert engine KQL queries)
New-AzRoleAssignment -ObjectId $MI -RoleDefinitionName "Log Analytics Reader" -Scope $LAW -ErrorAction SilentlyContinue

Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All","Application.Read.All" -NoWelcome
$Graph = (Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'").Id
# Graph API permissions:
#   dc377aa6 = DeviceManagementManagedDevices.Read.All
#   5ac13192 = DeviceManagementConfiguration.Read.All
#   06a5fe6d = DeviceManagementServiceConfig.Read.All
#   df021288 = User.Read.All
#   b0afded3 = AuditLog.Read.All
#   b633e1c5 = Mail.Send
"dc377aa6-52d8-4e23-b271-2a7ae04cedf3","5ac13192-7ace-4fcf-b828-1a26f28068ee","06a5fe6d-c49d-46a7-b082-56b1b14103c7","df021288-bdef-4463-88db-98f22de89214","b0afded3-3588-46d8-8b3d-9842eff778da","b633e1c5-b582-4048-a93e-9f11b44c7e96" | % {
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $MI -PrincipalId $MI -ResourceId $Graph -AppRoleId $_ -ErrorAction SilentlyContinue
}

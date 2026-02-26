#Requires -Modules Az.Resources, Microsoft.Graph.Applications

$MI = "f42f585e-5bae-463b-b425-f62b8f7d4689"
$DCR = "/subscriptions/1a51ea5e-d9ee-453e-94e5-cb61b5cd93cf/resourceGroups/ancIntuneReporting-Dev/providers/Microsoft.Insights/dataCollectionRules/graphreports-dcr"

Connect-AzAccount
New-AzRoleAssignment -ObjectId $MI -RoleDefinitionName "Monitoring Metrics Publisher" -Scope $DCR -ErrorAction SilentlyContinue

Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All","Application.Read.All" -NoWelcome
$Graph = (Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'").Id
"dc377aa6-52d8-4e23-b271-2a7ae04cedf3","5ac13192-7ace-4fcf-b828-1a26f28068ee","06a5fe6d-c49d-46a7-b082-56b1b14103c7" | % {
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $MI -PrincipalId $MI -ResourceId $Graph -AppRoleId $_ -ErrorAction SilentlyContinue
}

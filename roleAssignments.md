az role assignment create `
     --assignee-object-id "f42f585e-5bae-463b-b425-f62b8f7d4689" `
     --assignee-principal-type ServicePrincipal `
     --role "Monitoring Metrics Publisher" `
     --scope "/subscriptions/1a51ea5e-d9ee-453e-94e5-cb61b5cd93cf/resourceGroups/ancIntuneReporting-Dev/providers/Microsoft.Insights/dataCollectionRules/graphreports-dcr"
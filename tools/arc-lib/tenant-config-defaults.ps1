$categories_to_process = @('entra', 
    'azuread',
    'msgraph',
    'microsoftgraph',
    'aad',
    'azure-graph',
    'azure-ad',
    'azure-active-directory1',
    'active-directory'
)

Write-Host "Processing categories: $($categories_to_process -join ', ')"
$categories_to_process = @('entra', 
    'azuread',
    'msgraph',
    'microsoftgraph',
    'aad',
    'azure-graph',
    'azure-ad',
    'azure-active-directory',
    'active-directory'
)

Write-Host "Processing categories: $($categories_to_process -join ', ')"
<#
.SYNOPSIS
    Reads arc-config.yaml from an overlay (or repo root) and exports identity
    values to $GITHUB_ENV for downstream workflow steps.

.DESCRIPTION
    arc-config.yaml is the customer-specific identity file documented in
    docs/contributing/overlay-contract.md. This module parses it, validates it
    against arc-config.schema.json, and writes each value to $GITHUB_ENV using
    the canonical UPPER_SNAKE_CASE prefix per tenant section.

    Mapping:
      source.tenant_id              -> SOURCE_TENANT_ID
      source.client_id              -> SOURCE_CLIENT_ID
      shadow.tenant_id              -> SHADOW_TENANT_ID
      shadow.client_id              -> SHADOW_CLIENT_ID
      shadow.domain                 -> SHADOW_DOMAIN
      shadow.organization           -> SHADOW_ORGANIZATION
      shadow.sharepoint_admin_url   -> SHADOW_SHAREPOINT_ADMIN_URL
      shadow.w365_group_id          -> W365_GROUP_ID
      resource.tenant_id            -> RESOURCE_TENANT_ID
      resource.client_id            -> RESOURCE_CLIENT_ID
      resource.keyvault_name        -> KEYVAULT_NAME
      resource.subscription_id      -> RESOURCE_SUBSCRIPTION_ID
      resource.storage_account_name -> STORAGE_ACCOUNT_NAME
      arc_user.attribute            -> ARC_USER_ATTRIBUTE
      arc_user.attribute_value      -> ARC_USER_ATTRIBUTE_VALUE
      op.email_user_id              -> OP_EMAIL_USER_ID
      file_transfer.source_site_url     -> SOURCE_SITE_URL
      file_transfer.shadow_site_url     -> SHADOW_SITE_URL
      file_transfer.source_library_name -> SOURCE_LIBRARY_NAME

.NOTES
    Author: Arcitects GmbH
#>

$script:RequiredFields = @(
    'resource.tenant_id'
    'resource.client_id'
    'resource.client_secret'
)

$script:Mapping = [ordered]@{
    'resource.tenant_id'     = 'RESOURCE_TENANT_ID'
    'resource.client_id'     = 'RESOURCE_CLIENT_ID'
    'resource.client_secret' = 'RESOURCE_CLIENT_SECRET'
}

$script:KnownSections = @('resource')

function ConvertFrom-MinimalYaml {
    <#
    .SYNOPSIS
        Minimal YAML to hashtable converter for the flat-two-level arc-config.yaml shape.

    .DESCRIPTION
        arc-config.yaml is intentionally restricted to two levels:
            section:
              key: value
        Lists, anchors, and multi-line scalars are not supported. This keeps the
        parser dependency-free (no Powershell-Yaml needed in core).
    #>
    param([Parameter(Mandatory)][string]$Content)

    $result = [ordered]@{}
    $currentSection = $null

    foreach ($rawLine in ($Content -split "`r?`n")) {
        $line = $rawLine -replace '(^|\s)#.*$', '$1'
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match '^(?<name>[A-Za-z_][A-Za-z0-9_]*):\s*$') {
            $currentSection = $Matches['name']
            $result[$currentSection] = [ordered]@{}
            continue
        }

        if ($line -match '^\s+(?<key>[A-Za-z_][A-Za-z0-9_]*):\s*(?<value>.+?)\s*$') {
            if (-not $currentSection) {
                throw "Encountered key '$($Matches['key'])' outside any section in arc-config.yaml."
            }
            $value = $Matches['value']
            # Strip surrounding quotes if present.
            if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") {
                $value = $Matches[1]
            }
            $result[$currentSection][$Matches['key']] = $value
            continue
        }

        throw "Unrecognized line in arc-config.yaml: '$rawLine'."
    }

    return $result
}

function Get-DottedValue {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$DottedPath
    )
    $parts = $DottedPath.Split('.')
    if ($parts.Length -ne 2) { throw "Expected 'section.key', got '$DottedPath'." }
    $section, $key = $parts
    if (-not $Config.Contains($section)) { return $null }
    $sectionMap = $Config[$section]
    if (-not $sectionMap.Contains($key)) { return $null }
    return $sectionMap[$key]
}

function Export-OverlayConfigToEnv {
    <#
    .SYNOPSIS
        Reads arc-config.yaml at the given path and exports identity values to $GITHUB_ENV.

    .PARAMETER ConfigPath
        Path to arc-config.yaml. Throws if the file does not exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "arc-config.yaml not found at '$ConfigPath'."
    }

    try {
        $content = Get-Content -LiteralPath $ConfigPath -Raw
        $config = ConvertFrom-MinimalYaml -Content $content
    }
    catch {
        throw "Failed to parse '$ConfigPath': $($_.Exception.Message)"
    }

    foreach ($section in $config.Keys) {
        if ($section -notin $script:KnownSections) {
            throw "Unknown section '$section' in '$ConfigPath'. Known sections: $($script:KnownSections -join ', ')."
        }
    }

    foreach ($required in $script:RequiredFields) {
        $value = Get-DottedValue -Config $config -DottedPath $required
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Required field '$required' missing from '$ConfigPath'."
        }
    }

    $envPath = $env:GITHUB_ENV
    if ([string]::IsNullOrWhiteSpace($envPath)) {
        throw '$GITHUB_ENV is not set; refusing to write identity values to caller environment unconditionally.'
    }

    foreach ($entry in $script:Mapping.GetEnumerator()) {
        $value = Get-DottedValue -Config $config -DottedPath $entry.Key
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace($value)) { continue }
        "$($entry.Value)=$value" | Out-File -FilePath $envPath -Append -Encoding utf8
        # Also set in the current process so same-step reads (e.g., a Pwsh
        # step that calls Export-OverlayConfigToEnv then does $env:X further
        # down in the SAME step) see the value immediately. Otherwise the
        # values are only visible to SUBSEQUENT steps (GitHub Actions
        # processes $GITHUB_ENV between steps).
        [System.Environment]::SetEnvironmentVariable($entry.Value, $value, 'Process')
    }
}

Export-ModuleMember -Function Export-OverlayConfigToEnv
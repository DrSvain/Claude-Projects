<#
.SYNOPSIS
    Workload module: Intune Settings Catalog Policies

.DESCRIPTION
    Graph endpoint : /v1.0/deviceManagement/configurationPolicies
    Settings sub   : /v1.0/deviceManagement/configurationPolicies/{id}/settings

    This module handles ONLY policies with templateFamily == 'none'.
    Endpoint Security policies share the same endpoint but are handled by
    EndpointSecurity.psm1 (filter: templateFamily ne 'none').

    Export strategy:
      - List policies filtered to templateFamily eq 'none' (paged)
      - For each: fetch policy metadata + all settings pages (separate call)
      - Merge into a single export package
      - Save raw + import-ready JSON

    Restore strategy:
      - POST to /configurationPolicies
      - Settings are embedded in the POST body as the 'settings' array
      - The POST body format differs slightly from the GET response:
          GET  returns settingDefinitionId nested inside settingInstance
          POST accepts the same structure, so no transformation needed
      - templateReference is preserved when present (required for template-based policies)

    Known limitations:
      - Cross-tenant restore works for standard Settings Catalog policies.
      - Policies that reference custom ADMX templates (templateId != '') may
        fail if the same ADMX is not present in the target tenant.
      - Assignments are NOT restored.
#>

Set-StrictMode -Version Latest

$script:WorkloadKey  = 'SettingsCatalog'
$script:WorkloadName = 'Settings Catalog Policies'
$script:BaseUri      = 'https://graph.microsoft.com/v1.0/deviceManagement/configurationPolicies'

# Filter that restricts this module to Settings Catalog only (not Endpoint Security)
$script:ListFilter   = "templateReference/templateFamily eq 'none'"

# ---------------------------------------------------------------------------
#region Export
# ---------------------------------------------------------------------------

function Export-SettingsCatalog {
    <#
    .SYNOPSIS
        Exports all Settings Catalog policies (templateFamily == 'none').
    .OUTPUTS
        [hashtable]  ExportedCount, Warnings, IndexEntries
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ExportPath,
        [bool]$IncludeAssignments = $true,
        [bool]$ComputeChecksums   = $true,
        [int] $MaxRetries         = 3
    )

    $warnings     = [System.Collections.Generic.List[string]]::new()
    $indexEntries = [System.Collections.Generic.List[hashtable]]::new()
    $exported     = 0

    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Listing Settings Catalog policies..."

    $listUri = "$($script:BaseUri)?`$filter=$([Uri]::EscapeDataString($script:ListFilter))&`$orderby=name"

    try {
        $policies = Get-GraphAllPages -Uri $listUri -MaxRetries $MaxRetries
        Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Found $($policies.Count) policies"
    }
    catch {
        $msg = "[$script:WorkloadKey] Listing failed: $($_.Exception.Message)"
        Write-LogMessage -Level ERROR -Message $msg -ErrorRecord $_
        $warnings.Add($msg)
        return @{ ExportedCount = 0; Warnings = $warnings.ToArray(); IndexEntries = $indexEntries.ToArray() }
    }

    foreach ($p in $policies) {
        try {
            $entry = Export-SettingsCatalogPolicy `
                -Policy             $p `
                -ExportPath         $ExportPath `
                -IncludeAssignments $IncludeAssignments `
                -ComputeChecksums   $ComputeChecksums `
                -MaxRetries         $MaxRetries

            $indexEntries.Add($entry)
            $exported++
            Write-LogMessage -Level DEBUG -Message "[$script:WorkloadKey] Exported: $($p.name)"
        }
        catch {
            $msg = "[$script:WorkloadKey] Failed '$($p.name)': $($_.Exception.Message)"
            Write-LogMessage -Level WARN -Message $msg -ErrorRecord $_
            $warnings.Add($msg)
        }
    }

    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Export complete: $exported/$($policies.Count)"

    return @{
        ExportedCount = $exported
        Warnings      = $warnings.ToArray()
        IndexEntries  = $indexEntries.ToArray()
    }
}

function Export-SettingsCatalogPolicy {
    <#
    .SYNOPSIS
        Exports a single Settings Catalog policy: metadata + all settings pages.
    .OUTPUTS
        [hashtable]  Index entry
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Policy,
        [Parameter(Mandatory)][string]$ExportPath,
        [bool]$IncludeAssignments = $true,
        [bool]$ComputeChecksums   = $true,
        [int] $MaxRetries         = 3
    )

    $id       = $Policy.id
    $name     = $Policy.name
    $safeName = ConvertTo-SafeFileName -Name $name
    $fileBase = Join-Path $ExportPath "${safeName}_${id}"

    # Policy metadata (full detail)
    $full = Invoke-GraphRequestRetry `
        -Method     GET `
        -Uri        "$($script:BaseUri)/$id" `
        -MaxRetries $MaxRetries

    # Settings – paged, separate endpoint
    # These are NOT included in the policy object; must be fetched explicitly.
    $settings = @()
    try {
        $settings = Get-GraphAllPages `
            -Uri        "$($script:BaseUri)/$id/settings" `
            -MaxRetries $MaxRetries
        Write-LogMessage -Level DEBUG -Message "[$script:WorkloadKey] '$name': $($settings.Count) setting(s)"
    }
    catch {
        Write-LogMessage -Level WARN -Message "[$script:WorkloadKey] Settings fetch failed for '$name': $($_.Exception.Message)"
    }

    # Assignments (documentation only)
    $assignments = $null
    if ($IncludeAssignments) {
        try {
            $resp = Invoke-GraphRequestRetry `
                -Method     GET `
                -Uri        "$($script:BaseUri)/$id/assignments" `
                -MaxRetries $MaxRetries
            $assignments = $resp.value
        }
        catch {
            Write-LogMessage -Level DEBUG -Message "[$script:WorkloadKey] Assignments unavailable for '$name': $($_.Exception.Message)"
        }
    }

    # Detect template-based policies that may not be portable
    $templateId     = $full.templateReference.templateId
    $restoreWarning = $null
    if ($templateId -and $templateId -ne '' -and $templateId -ne '00000000-0000-0000-0000-000000000000') {
        $restoreWarning = "Template-based policy (templateId: $templateId). Ensure the same template is available in the target tenant."
    }

    # Raw export package
    $raw = [ordered]@{
        ExportedAt    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Workload      = $script:WorkloadKey
        DisplayName   = $name
        SourceId      = $id
        GraphEndpoint = $script:BaseUri
        Policy        = $full
        Settings      = $settings
        Assignments   = $assignments
    }
    $rawFile = "$fileBase.json"
    Save-JsonFile -Object $raw -Path $rawFile

    # Import-ready data (policy + embedded settings)
    $import     = Get-SettingsCatalogImportData -Policy $full -Settings $settings
    $importFile = "$fileBase.import.json"
    Save-JsonFile -Object $import -Path $importFile

    $checksum = if ($ComputeChecksums) { Get-SHA256 -FilePath $rawFile } else { $null }

    return @{
        DisplayName    = $name
        SourceId       = $id
        Category       = $script:WorkloadKey
        CategoryLabel  = $script:WorkloadName
        ODataType      = $null            # Settings Catalog uses 'name', not @odata.type
        GraphEndpoint  = $script:BaseUri
        CreatedDate    = $full.createdDateTime
        ModifiedDate   = $full.lastModifiedDateTime
        SettingsCount  = $settings.Count
        FileName       = Split-Path $rawFile    -Leaf
        ImportFileName = Split-Path $importFile -Leaf
        Checksum       = $checksum
        HasAssignments = ($null -ne $assignments -and $assignments.Count -gt 0)
        RestoreWarning = $restoreWarning
    }
}

#endregion

# ---------------------------------------------------------------------------
#region Import (Restore)
# ---------------------------------------------------------------------------

function Get-SettingsCatalogImportData {
    <#
    .SYNOPSIS
        Builds a POST-ready body for creating a Settings Catalog policy.

    .DESCRIPTION
        POST body structure:
            {
                "name":              "...",
                "description":       "...",
                "platforms":         "windows10",
                "technologies":      "mdm",
                "templateReference": { "templateId": "..." },
                "settings":          [ ... ]     ← embedded from /settings
            }

        Removed fields:
            id, createdDateTime, lastModifiedDateTime, settingCount,
            @odata.context, @odata.etag, isAssigned,
            roleScopeTagIds (scope tags are tenant-specific)

        Settings are included as-is from the /settings sub-endpoint.
        The API accepts the GET format in POST without transformation.

    .OUTPUTS
        [hashtable]  Ready for POST to /configurationPolicies
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Policy,
        [object[]]$Settings = @()
    )

    $extra = @(
        'settingCount'
        'isAssigned'
        'roleScopeTagIds'
    )

    $body = Remove-GraphMetaProperties -InputObject $Policy -ExtraProperties $extra

    # Embed settings into the body (required for POST)
    if ($Settings -and $Settings.Count -gt 0) {
        # Strip read-only fields from each setting
        $cleanSettings = foreach ($s in $Settings) {
            $cs = ConvertTo-Hashtable -InputObject $s
            $cs.Remove('id')
            $cs
        }
        $body['settings'] = @($cleanSettings)
    }
    else {
        $body['settings'] = @()
    }

    return $body
}

function Import-SettingsCatalogPolicy {
    <#
    .SYNOPSIS
        Creates a new Settings Catalog policy in the current tenant.
    .OUTPUTS
        [hashtable]  Success, NewId, DisplayName, Error
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$ImportData,
        [int]$MaxRetries = 3
    )

    $name = if ($ImportData.name) { $ImportData.name } else { '<unnamed>' }
    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Importing: $name ($($ImportData.settings.Count) setting(s))"

    try {
        $resp = Invoke-GraphRequestRetry `
            -Method     POST `
            -Uri        $script:BaseUri `
            -Body       $ImportData `
            -MaxRetries $MaxRetries

        Write-LogMessage -Level SUCCESS -Message "[$script:WorkloadKey] Created: $name (new id: $($resp.id))"
        return @{ Success = $true; NewId = $resp.id; DisplayName = $name; Error = $null }
    }
    catch {
        Write-LogMessage -Level ERROR -Message "[$script:WorkloadKey] Import failed for '$name': $($_.Exception.Message)"
        return @{ Success = $false; NewId = $null; DisplayName = $name; Error = $_.Exception.Message }
    }
}

function Get-ExistingSettingsCatalogPolicies {
    <#
    .SYNOPSIS
        Returns name → id lookup for existing Settings Catalog policies.
        Used by RestoreEngine for conflict detection.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([int]$MaxRetries = 3)

    $map = @{}
    try {
        $listUri = "$($script:BaseUri)?`$filter=$([Uri]::EscapeDataString($script:ListFilter))&`$select=id,name"
        $list    = Get-GraphAllPages -Uri $listUri -MaxRetries $MaxRetries

        foreach ($p in $list) {
            if ($p.name) {
                $map[$p.name.ToLowerInvariant()] = $p.id
            }
        }
    }
    catch {
        Write-LogMessage -Level WARN -Message "[$script:WorkloadKey] Existing-policy lookup failed: $($_.Exception.Message)"
    }
    return $map
}

#endregion

Export-ModuleMember -Function `
    Export-SettingsCatalog, `
    Export-SettingsCatalogPolicy, `
    Get-SettingsCatalogImportData, `
    Import-SettingsCatalogPolicy, `
    Get-ExistingSettingsCatalogPolicies

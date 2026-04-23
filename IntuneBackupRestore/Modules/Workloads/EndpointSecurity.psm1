<#
.SYNOPSIS
    Workload module: Intune Endpoint Security Policies

.DESCRIPTION
    Graph endpoint : /v1.0/deviceManagement/configurationPolicies
    Filter         : templateReference/templateFamily ne 'none'

    Modern Endpoint Security policies are stored in the same API surface as
    Settings Catalog policies but are identified by a non-'none' templateFamily.

    Known templateFamily values (may expand with future Intune releases):
        endpointSecurityAntivirus
        endpointSecurityDiskEncryption
        endpointSecurityFirewall
        endpointSecurityEndpointDetectionAndResponse
        endpointSecurityAttackSurfaceReduction
        endpointSecurityAccountProtection
        baseline  (Security Baselines)

    Export strategy:
      - List policies with templateFamily ne 'none' (paged)
      - Fetch metadata + settings pages per policy
      - Save raw + import-ready JSON

    Restore strategy:
      - POST to /configurationPolicies
      - templateReference MUST be included (links to security template)
      - Settings embedded in the body (same format as Settings Catalog)

    Known limitations:
      - Security Baselines (templateFamily = 'baseline') reference a specific
        baseline template version. If a newer baseline version exists in the
        target tenant, Intune will use it; settings still apply correctly.
      - Legacy Endpoint Security policies created via /deviceManagement/intents
        (older API, pre-2022) are NOT covered by this module.
      - Assignments are NOT restored.
#>

Set-StrictMode -Version Latest

$script:WorkloadKey  = 'EndpointSecurity'
$script:WorkloadName = 'Endpoint Security Policies'
$script:BaseUri      = 'https://graph.microsoft.com/v1.0/deviceManagement/configurationPolicies'
$script:ListFilter   = "templateReference/templateFamily ne 'none'"

# Human-readable labels for known templateFamily values
$script:FamilyLabels = @{
    endpointSecurityAntivirus                       = 'Antivirus'
    endpointSecurityDiskEncryption                  = 'Disk Encryption'
    endpointSecurityFirewall                        = 'Firewall'
    endpointSecurityEndpointDetectionAndResponse    = 'EDR'
    endpointSecurityAttackSurfaceReduction          = 'Attack Surface Reduction'
    endpointSecurityAccountProtection               = 'Account Protection'
    baseline                                        = 'Security Baseline'
}

# ---------------------------------------------------------------------------
#region Export
# ---------------------------------------------------------------------------

function Export-EndpointSecurity {
    <#
    .SYNOPSIS
        Exports all Endpoint Security policies (templateFamily != 'none').
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

    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Listing Endpoint Security policies..."

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
            $entry = Export-EndpointSecurityPolicy `
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

function Export-EndpointSecurityPolicy {
    <#
    .SYNOPSIS
        Exports a single Endpoint Security policy.
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

    $id           = $Policy.id
    $name         = $Policy.name
    $templateFamily = $Policy.templateReference.templateFamily
    $templateId     = $Policy.templateReference.templateId
    $safeName     = ConvertTo-SafeFileName -Name $name
    $fileBase     = Join-Path $ExportPath "${safeName}_${id}"

    # Full policy detail
    $full = Invoke-GraphRequestRetry `
        -Method     GET `
        -Uri        "$($script:BaseUri)/$id" `
        -MaxRetries $MaxRetries

    # Settings pages
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

    # Assignments
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

    # Baseline warning: the templateId may resolve to a different version in the target
    $restoreWarning = $null
    if ($templateFamily -eq 'baseline') {
        $restoreWarning = "Security Baseline policy. Target tenant will use its current baseline version for templateId $templateId."
    }

    $familyLabel = if ($script:FamilyLabels[$templateFamily]) {
        $script:FamilyLabels[$templateFamily]
    } else {
        $templateFamily
    }

    # Raw export
    $raw = [ordered]@{
        ExportedAt      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Workload        = $script:WorkloadKey
        DisplayName     = $name
        SourceId        = $id
        TemplateFamily  = $templateFamily
        TemplateId      = $templateId
        FamilyLabel     = $familyLabel
        GraphEndpoint   = $script:BaseUri
        Policy          = $full
        Settings        = $settings
        Assignments     = $assignments
    }
    $rawFile = "$fileBase.json"
    Save-JsonFile -Object $raw -Path $rawFile

    # Import-ready
    $import     = Get-EndpointSecurityImportData -Policy $full -Settings $settings
    $importFile = "$fileBase.import.json"
    Save-JsonFile -Object $import -Path $importFile

    $checksum = if ($ComputeChecksums) { Get-SHA256 -FilePath $rawFile } else { $null }

    return @{
        DisplayName    = $name
        SourceId       = $id
        Category       = $script:WorkloadKey
        CategoryLabel  = "$($script:WorkloadName) – $familyLabel"
        TemplateFamily = $templateFamily
        TemplateId     = $templateId
        ODataType      = $null
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

function Get-EndpointSecurityImportData {
    <#
    .SYNOPSIS
        Builds a POST-ready body for creating an Endpoint Security policy.

    .DESCRIPTION
        templateReference is KEPT and REQUIRED.
        Without it the API cannot link the policy to its security template.

        Removed:
            id, createdDateTime, lastModifiedDateTime, settingCount,
            @odata.context, @odata.etag, isAssigned, roleScopeTagIds

        Settings from /settings are embedded as the 'settings' array.
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

    # Embed cleaned settings
    if ($Settings -and $Settings.Count -gt 0) {
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

function Import-EndpointSecurityPolicy {
    <#
    .SYNOPSIS
        Creates a new Endpoint Security policy in the current tenant.
    .OUTPUTS
        [hashtable]  Success, NewId, DisplayName, Error
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$ImportData,
        [int]$MaxRetries = 3
    )

    $name   = if ($ImportData.name) { $ImportData.name } else { '<unnamed>' }
    $family = if ($ImportData.templateReference.templateFamily) {
        $ImportData.templateReference.templateFamily
    } else { 'unknown' }

    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Importing: $name (family: $family)"

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

function Get-ExistingEndpointSecurityPolicies {
    <#
    .SYNOPSIS
        Returns name → id lookup for existing ES policies.
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
            if ($p.name) { $map[$p.name.ToLowerInvariant()] = $p.id }
        }
    }
    catch {
        Write-LogMessage -Level WARN -Message "[$script:WorkloadKey] Existing-policy lookup failed: $($_.Exception.Message)"
    }
    return $map
}

#endregion

Export-ModuleMember -Function `
    Export-EndpointSecurity, `
    Export-EndpointSecurityPolicy, `
    Get-EndpointSecurityImportData, `
    Import-EndpointSecurityPolicy, `
    Get-ExistingEndpointSecurityPolicies

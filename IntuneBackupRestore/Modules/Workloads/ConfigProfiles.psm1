<#
.SYNOPSIS
    Workload module: Intune Device Configuration Profiles

.DESCRIPTION
    Graph endpoint : /v1.0/deviceManagement/deviceConfigurations

    Export strategy:
      - List all profiles (paged, ordered by displayName)
      - For each: fetch full detail + assignments
      - Save <Name>_<Id>.json          (raw)
      - Save <Name>_<Id>.import.json   (cleaned, ready for POST)

    Restore strategy:
      - POST to /deviceConfigurations with cleaned body
      - Always creates a NEW profile (safe default)
      - @odata.type MUST be preserved – it drives platform-specific validation

    Known limitations:
      - OMA-URI custom profiles: if a URI value references a tenant-specific
        GUID (e.g. an app GUID) the value is exported as-is and flagged in
        the index. Manual correction is required after restore.
      - Hardware-bound profile types (windowsDomainJoinConfiguration,
        sharedPCConfiguration) are exported but may fail to restore if the
        target environment has different infrastructure.
      - Assignments are NOT restored.
#>

Set-StrictMode -Version Latest

$script:WorkloadKey  = 'ConfigProfiles'
$script:WorkloadName = 'Device Configuration Profiles'
$script:BaseUri      = 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations'

# Profile types that are typically non-portable across tenants.
# These are still exported but flagged with a warning in the index.
$script:NonPortableTypes = @(
    '#microsoft.graph.windowsDomainJoinConfiguration'
    '#microsoft.graph.windows10NetworkBoundaryConfiguration'
    '#microsoft.graph.windowsWifiEnterpriseEAPConfiguration'
)

# ---------------------------------------------------------------------------
#region Export
# ---------------------------------------------------------------------------

function Export-ConfigProfiles {
    <#
    .SYNOPSIS
        Exports all device configuration profiles.
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

    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Listing device configuration profiles..."

    try {
        $profiles = Get-GraphAllPages `
            -Uri        "$($script:BaseUri)?`$orderby=displayName" `
            -MaxRetries $MaxRetries

        Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Found $($profiles.Count) profiles"
    }
    catch {
        $msg = "[$script:WorkloadKey] Listing failed: $($_.Exception.Message)"
        Write-LogMessage -Level ERROR -Message $msg -ErrorRecord $_
        $warnings.Add($msg)
        return @{ ExportedCount = 0; Warnings = $warnings.ToArray(); IndexEntries = $indexEntries.ToArray() }
    }

    foreach ($p in $profiles) {
        try {
            $entry = Export-ConfigProfile `
                -Profile            $p `
                -ExportPath         $ExportPath `
                -IncludeAssignments $IncludeAssignments `
                -ComputeChecksums   $ComputeChecksums `
                -MaxRetries         $MaxRetries

            $indexEntries.Add($entry)

            if ($entry.RestoreWarning) {
                $warnings.Add("[$script:WorkloadKey] '$($p.displayName)': $($entry.RestoreWarning)")
            }

            $exported++
            Write-LogMessage -Level DEBUG -Message "[$script:WorkloadKey] Exported: $($p.displayName)"
        }
        catch {
            $msg = "[$script:WorkloadKey] Failed '$($p.displayName)': $($_.Exception.Message)"
            Write-LogMessage -Level WARN -Message $msg -ErrorRecord $_
            $warnings.Add($msg)
        }
    }

    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Export complete: $exported/$($profiles.Count)"

    return @{
        ExportedCount = $exported
        Warnings      = $warnings.ToArray()
        IndexEntries  = $indexEntries.ToArray()
    }
}

function Export-ConfigProfile {
    <#
    .SYNOPSIS
        Exports a single device configuration profile.
    .OUTPUTS
        [hashtable]  Index entry
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Profile,
        [Parameter(Mandatory)][string]$ExportPath,
        [bool]$IncludeAssignments = $true,
        [bool]$ComputeChecksums   = $true,
        [int] $MaxRetries         = 3
    )

    $id       = $Profile.id
    $name     = $Profile.displayName
    $odataType = $Profile.'@odata.type'
    $safeName = ConvertTo-SafeFileName -Name $name
    $fileBase = Join-Path $ExportPath "${safeName}_${id}"

    # Full detail – list response can omit complex nested properties
    $full = Invoke-GraphRequestRetry `
        -Method     GET `
        -Uri        "$($script:BaseUri)/$id" `
        -MaxRetries $MaxRetries

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
            Write-LogMessage -Level DEBUG -Message "[$script:WorkloadKey] assignments unavailable for '$name': $($_.Exception.Message)"
        }
    }

    # Detect OMA-URI custom profiles that may contain tenant-specific GUIDs
    $hasOmaUri = $odataType -eq '#microsoft.graph.windows10CustomConfiguration' -or
                 $odataType -eq '#microsoft.graph.androidCustomConfiguration'  -or
                 $odataType -eq '#microsoft.graph.iosCustomConfiguration'      -or
                 $odataType -eq '#microsoft.graph.macOSCustomConfiguration'

    # Detect non-portable types
    $restoreWarning = $null
    if ($odataType -in $script:NonPortableTypes) {
        $restoreWarning = "Profile type '$odataType' is hardware/infrastructure-bound and may not restore cleanly."
        Write-LogMessage -Level WARN -Message "[$script:WorkloadKey] Non-portable type: $name ($odataType)"
    }
    if ($hasOmaUri) {
        $restoreWarning = (($restoreWarning ? "$restoreWarning " : '') +
            "Custom OMA-URI profile: check values for tenant-specific GUIDs before restore.")
    }

    # Raw export package
    $raw = [ordered]@{
        ExportedAt   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Workload     = $script:WorkloadKey
        DisplayName  = $name
        SourceId     = $id
        ODataType    = $odataType
        GraphEndpoint= $script:BaseUri
        Profile      = $full
        Assignments  = $assignments
    }
    $rawFile = "$fileBase.json"
    Save-JsonFile -Object $raw -Path $rawFile

    # Import-ready data
    $import     = Get-ConfigProfileImportData -Profile $full
    $importFile = "$fileBase.import.json"
    Save-JsonFile -Object $import -Path $importFile

    $checksum = if ($ComputeChecksums) { Get-SHA256 -FilePath $rawFile } else { $null }

    return @{
        DisplayName    = $name
        SourceId       = $id
        Category       = $script:WorkloadKey
        CategoryLabel  = $script:WorkloadName
        ODataType      = $odataType
        GraphEndpoint  = $script:BaseUri
        CreatedDate    = $full.createdDateTime
        ModifiedDate   = $full.lastModifiedDateTime
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

function Get-ConfigProfileImportData {
    <#
    .SYNOPSIS
        Produces a restore-ready hashtable from a raw device configuration profile.

    .DESCRIPTION
        Removed fields (system-managed):
            id, createdDateTime, lastModifiedDateTime, version,
            @odata.context, @odata.etag,
            supportsScopeTags               (read-only computed flag)
            deviceManagementApplicabilityRuleOsEdition   (read-only)
            deviceManagementApplicabilityRuleOsVersion   (read-only)
            deviceManagementApplicabilityRuleDeviceMode  (read-only)

        KEPT:
            @odata.type  – CRITICAL for correct platform routing on POST.
                           Stripping it causes a 400 Bad Request.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Profile
    )

    $extra = @(
        'supportsScopeTags'
        'deviceManagementApplicabilityRuleOsEdition'
        'deviceManagementApplicabilityRuleOsVersion'
        'deviceManagementApplicabilityRuleDeviceMode'
    )

    return Remove-GraphMetaProperties -InputObject $Profile -ExtraProperties $extra
}

function Import-ConfigProfile {
    <#
    .SYNOPSIS
        Creates a new device configuration profile in the current tenant.
    .OUTPUTS
        [hashtable]  Success, NewId, DisplayName, Error
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$ImportData,
        [int]$MaxRetries = 3
    )

    $name = if ($ImportData.displayName) { $ImportData.displayName } else { '<unnamed>' }
    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Importing: $name ($($ImportData.'@odata.type'))"

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

function Get-ExistingConfigProfiles {
    <#
    .SYNOPSIS
        Returns a lookup-table of existing profiles (lower-case name → id).
        Used by RestoreEngine for conflict detection.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([int]$MaxRetries = 3)

    $map = @{}
    try {
        $list = Get-GraphAllPages `
            -Uri        "$($script:BaseUri)?`$select=id,displayName" `
            -MaxRetries $MaxRetries

        foreach ($p in $list) {
            $map[$p.displayName.ToLowerInvariant()] = $p.id
        }
    }
    catch {
        Write-LogMessage -Level WARN -Message "[$script:WorkloadKey] Existing-profile lookup failed: $($_.Exception.Message)"
    }
    return $map
}

#endregion

Export-ModuleMember -Function `
    Export-ConfigProfiles, `
    Export-ConfigProfile, `
    Get-ConfigProfileImportData, `
    Import-ConfigProfile, `
    Get-ExistingConfigProfiles

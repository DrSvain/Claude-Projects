<#
.SYNOPSIS
    Workload module: Intune App Protection Policies (MAM).

.DESCRIPTION
    Graph endpoint : /deviceAppManagement/managedAppPolicies
    The collection is heavily polymorphic. Common derived types:
      * iosManagedAppProtection
      * androidManagedAppProtection
      * mdmWindowsInformationProtectionPolicy
      * windowsManagedAppProtection
      * targetedManagedAppConfiguration  (returned by managedAppPolicies)

    For RESTORE, each derived type lives at a dedicated collection:
        /deviceAppManagement/iosManagedAppProtections
        /deviceAppManagement/androidManagedAppProtections
        /deviceAppManagement/mdmWindowsInformationProtectionPolicies
        /deviceAppManagement/windowsInformationProtectionPolicies (legacy, often deprecated)

    Get-AppProtectionPostUri maps @odata.type -> POST collection. Unknown
    types fall back to /deviceAppManagement/managedAppPolicies which the
    service rejects unless the type is a recognized one.

.NOTES
    Apps targeted by the policy (apps[]) are kept in the import body. Their
    'mobileAppIdentifier' references App Store / Play Store package names,
    which are tenant-portable.
#>

Set-StrictMode -Version Latest

$script:WorkloadKey  = 'AppProtection'
$script:WorkloadName = 'App Protection Policies'
$script:RelPath      = '/deviceAppManagement/managedAppPolicies'

function _AP2_BaseUri { (Get-GraphRoot -WorkloadKey $script:WorkloadKey) + $script:RelPath }

# ---------------------------------------------------------------------------
#region Type → POST collection mapping
# ---------------------------------------------------------------------------

$script:PostCollectionByType = @{
    '#microsoft.graph.iosManagedAppProtection'                = '/deviceAppManagement/iosManagedAppProtections'
    '#microsoft.graph.androidManagedAppProtection'            = '/deviceAppManagement/androidManagedAppProtections'
    '#microsoft.graph.windowsManagedAppProtection'            = '/deviceAppManagement/windowsManagedAppProtections'
    '#microsoft.graph.mdmWindowsInformationProtectionPolicy'  = '/deviceAppManagement/mdmWindowsInformationProtectionPolicies'
    '#microsoft.graph.windowsInformationProtectionPolicy'     = '/deviceAppManagement/windowsInformationProtectionPolicies'
    '#microsoft.graph.targetedManagedAppConfiguration'        = '/deviceAppManagement/targetedManagedAppConfigurations'
}

function Get-AppProtectionPostUri {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ODataType)
    if ($script:PostCollectionByType.ContainsKey($ODataType)) {
        return (Get-GraphRoot -WorkloadKey $script:WorkloadKey) + $script:PostCollectionByType[$ODataType]
    }
    return _AP2_BaseUri
}

# ---------------------------------------------------------------------------
#region Export
# ---------------------------------------------------------------------------

function Export-AppProtectionPolicies {
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

    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Listing app protection policies..."

    try {
        $list = Get-GraphAllPages -Uri "$(_AP2_BaseUri)" -MaxRetries $MaxRetries
        Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Found $($list.Count) policy/policies"
    }
    catch {
        $msg = "[$script:WorkloadKey] Listing failed: $($_.Exception.Message)"
        Write-LogMessage -Level ERROR -Message $msg
        $warnings.Add($msg)
        return @{ ExportedCount = 0; Warnings = $warnings.ToArray(); IndexEntries = $indexEntries.ToArray() }
    }

    foreach ($p in $list) {
        try {
            $entry = Export-AppProtectionPolicy -Policy $p -ExportPath $ExportPath `
                -IncludeAssignments $IncludeAssignments -ComputeChecksums $ComputeChecksums `
                -MaxRetries $MaxRetries
            $indexEntries.Add($entry)
            $exported++
        }
        catch {
            $msg = "[$script:WorkloadKey] Failed '$($p.displayName)': $($_.Exception.Message)"
            Write-LogMessage -Level WARN -Message $msg
            $warnings.Add($msg)
        }
    }

    return @{ ExportedCount = $exported; Warnings = $warnings.ToArray(); IndexEntries = $indexEntries.ToArray() }
}

function Export-AppProtectionPolicy {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Policy,
        [Parameter(Mandatory)][string]$ExportPath,
        [bool]$IncludeAssignments = $true,
        [bool]$ComputeChecksums   = $true,
        [int] $MaxRetries         = 3
    )

    $id        = $Policy.id
    $name      = if ($Policy.displayName) { $Policy.displayName } else { 'AppProtection' }
    $odataType = $Policy.'@odata.type'
    $safeName  = ConvertTo-SafeFileName -Name $name
    $fileBase  = Join-Path $ExportPath "${safeName}_${id}"

    # Policy detail. The right way is to GET via the derived collection because
    # /managedAppPolicies/{id} returns minimal data for derived types.
    $derivedRoot = Get-AppProtectionPostUri -ODataType $odataType
    $detail = $null
    try {
        $detail = Invoke-GraphRequestRetry -Method GET -Uri "$derivedRoot/$id" -MaxRetries $MaxRetries
    }
    catch {
        Write-LogMessage -Level DEBUG -Message "[$script:WorkloadKey] Derived GET failed for '$name', falling back to base."
        $detail = Invoke-GraphRequestRetry -Method GET -Uri "$(_AP2_BaseUri)/$id" -MaxRetries $MaxRetries
    }

    # Apps + assignments live on dedicated subpaths for some derived types.
    $apps = $null
    try {
        $resp = Invoke-GraphRequestRetry -Method GET -Uri "$derivedRoot/$id/apps" -MaxRetries $MaxRetries
        $apps = $resp.value
    } catch { }

    $portable = $script:PostCollectionByType.ContainsKey($odataType)
    $warning  = if (-not $portable) { "Polymorphic type '$odataType' has no dedicated POST collection. Restore not supported for this type." } else { $null }

    $raw = [ordered]@{
        ExportedAt    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Workload      = $script:WorkloadKey
        DisplayName   = $name
        SourceId      = $id
        ODataType     = $odataType
        GraphEndpoint = $derivedRoot
        Policy        = $detail
        Apps          = $apps
    }
    $rawFile = "$fileBase.json"
    Save-JsonFile -Object $raw -Path $rawFile

    $importBody = Get-AppProtectionImportData -Policy $detail -Apps $apps
    $importFile = "$fileBase.import.json"
    Save-JsonFile -Object $importBody -Path $importFile

    $assignmentInfo = @{ HasAssignments=$false; AssignmentCount=0 }
    if ($IncludeAssignments) {
        $assignmentInfo = Export-IntuneAssignments -WorkloadKey $script:WorkloadKey `
            -ObjectId $id -OutFileBase $fileBase -MaxRetries $MaxRetries
    }

    $checksum = if ($ComputeChecksums) { Get-SHA256 -FilePath $rawFile } else { $null }

    return @{
        DisplayName    = $name
        SourceId       = $id
        Category       = $script:WorkloadKey
        CategoryLabel  = $script:WorkloadName
        ODataType      = $odataType
        GraphEndpoint  = $derivedRoot
        CreatedDate    = $detail.createdDateTime
        ModifiedDate   = $detail.lastModifiedDateTime
        FileName       = Split-Path $rawFile    -Leaf
        ImportFileName = Split-Path $importFile -Leaf
        Checksum       = $checksum
        HasAssignments = $assignmentInfo.HasAssignments
        EndpointVersion = Get-EndpointVersion -WorkloadKey $script:WorkloadKey
        RestoreWarning = $warning
    }
}

#endregion

# ---------------------------------------------------------------------------
#region Import (Restore)
# ---------------------------------------------------------------------------

function Get-AppProtectionImportData {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Policy,
        [object[]]$Apps = @()
    )

    $extra = @(
        'deployedAppCount'        # service-managed counter
        'isAssigned'              # service-managed
        'roleScopeTagIds'         # tenant-specific
        'deployedAppHash'
    )

    $body = Remove-GraphMetaProperties -InputObject $Policy -ExtraProperties $extra

    if ($Apps -and $Apps.Count -gt 0) {
        $cleanApps = foreach ($a in $Apps) {
            $h = ConvertTo-Hashtable -InputObject $a
            $h.Remove('id')
            $h.Remove('version')
            $h
        }
        $body['apps'] = @($cleanApps)
    }
    return $body
}

function Import-AppProtectionPolicy {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$ImportData,
        [int]$MaxRetries = 3
    )

    $name      = if ($ImportData.displayName) { $ImportData.displayName } else { '<unnamed>' }
    $odataType = [string]$ImportData['@odata.type']
    if (-not $script:PostCollectionByType.ContainsKey($odataType)) {
        return @{ Success=$false; NewId=$null; DisplayName=$name; Error="Unsupported app-protection derived type: $odataType" }
    }

    $postUri = Get-AppProtectionPostUri -ODataType $odataType
    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Importing: $name -> $postUri"

    try {
        $resp = Invoke-GraphRequestRetry -Method POST -Uri $postUri -Body $ImportData -MaxRetries $MaxRetries
        Write-LogMessage -Level SUCCESS -Message "[$script:WorkloadKey] Created: $name (id: $($resp.id))"
        return @{ Success=$true; NewId=$resp.id; DisplayName=$name; Error=$null }
    }
    catch {
        Write-LogMessage -Level ERROR -Message "[$script:WorkloadKey] Import failed for '$name': $($_.Exception.Message)"
        return @{ Success=$false; NewId=$null; DisplayName=$name; Error=$_.Exception.Message }
    }
}

function Get-ExistingAppProtectionPolicies {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([int]$MaxRetries = 3)

    $map = @{}
    try {
        $list = Get-GraphAllPages -Uri "$(_AP2_BaseUri)?`$select=id,displayName" -MaxRetries $MaxRetries
        foreach ($p in $list) {
            if ($p.displayName) { $map[$p.displayName.ToLowerInvariant()] = $p.id }
        }
    }
    catch {
        Write-LogMessage -Level WARN -Message "[$script:WorkloadKey] Existing-policy lookup failed: $($_.Exception.Message)"
    }
    return $map
}

#endregion

Export-ModuleMember -Function `
    Export-AppProtectionPolicies, `
    Export-AppProtectionPolicy, `
    Get-AppProtectionImportData, `
    Import-AppProtectionPolicy, `
    Get-ExistingAppProtectionPolicies, `
    Get-AppProtectionPostUri

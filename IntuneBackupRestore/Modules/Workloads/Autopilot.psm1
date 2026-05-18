<#
.SYNOPSIS
    Workload module: Windows Autopilot deployment profiles.

.DESCRIPTION
    Graph endpoint : /deviceManagement/windowsAutopilotDeploymentProfiles

    Backup strategy:
      - List all profiles (paged)
      - Persist raw + import-ready JSON, plus optional assignments sidecar

    Restore strategy:
      - POST to /windowsAutopilotDeploymentProfiles
      - templateReference, lastModifiedDateTime, status etc. stripped.
      - The deviceType / @odata.type discriminator is preserved (required).
      - Hardware-bound metadata such as enrolledDeviceCount is excluded.

    Known limitations (documented in README):
      - "Restorable" but with caveats: assigned hardware hashes from the
        source tenant cannot be transferred. Operators must re-upload device
        identifiers in the target tenant after restore.
      - The Self-deploying / Pre-provisioning profiles will be created but
        require Azure AD Premium and an active enrollment service in the
        target tenant.
#>

Set-StrictMode -Version Latest

$script:WorkloadKey  = 'Autopilot'
$script:WorkloadName = 'Autopilot Deployment Profiles'
$script:RelPath      = '/deviceManagement/windowsAutopilotDeploymentProfiles'

function _AP_BaseUri { (Get-GraphRoot -WorkloadKey $script:WorkloadKey) + $script:RelPath }

# ---------------------------------------------------------------------------
#region Export
# ---------------------------------------------------------------------------

function Export-AutopilotProfiles {
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

    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Listing Autopilot deployment profiles..."

    try {
        $profiles = Get-GraphAllPages -Uri "$(_AP_BaseUri)?`$orderby=displayName" -MaxRetries $MaxRetries
        Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Found $($profiles.Count) profile(s)"
    }
    catch {
        $msg = "[$script:WorkloadKey] Listing failed: $($_.Exception.Message)"
        Write-LogMessage -Level ERROR -Message $msg -ErrorRecord $_
        $warnings.Add($msg)
        return @{ ExportedCount = 0; Warnings = $warnings.ToArray(); IndexEntries = $indexEntries.ToArray() }
    }

    foreach ($p in $profiles) {
        try {
            $entry = Export-AutopilotProfile -Profile $p -ExportPath $ExportPath `
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

function Export-AutopilotProfile {
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
    $safeName = ConvertTo-SafeFileName -Name $name
    $fileBase = Join-Path $ExportPath "${safeName}_${id}"

    $full = Invoke-GraphRequestRetry -Method GET -Uri "$(_AP_BaseUri)/$id" -MaxRetries $MaxRetries

    $raw = [ordered]@{
        ExportedAt    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Workload      = $script:WorkloadKey
        DisplayName   = $name
        SourceId      = $id
        ODataType     = $full.'@odata.type'
        GraphEndpoint = (_AP_BaseUri)
        Profile       = $full
    }
    $rawFile = "$fileBase.json"
    Save-JsonFile -Object $raw -Path $rawFile

    $importBody = Get-AutopilotProfileImportData -Profile $full
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
        ODataType      = $full.'@odata.type'
        GraphEndpoint  = (_AP_BaseUri)
        CreatedDate    = $full.createdDateTime
        ModifiedDate   = $full.lastModifiedDateTime
        FileName       = Split-Path $rawFile    -Leaf
        ImportFileName = Split-Path $importFile -Leaf
        Checksum       = $checksum
        HasAssignments = $assignmentInfo.HasAssignments
        EndpointVersion = Get-EndpointVersion -WorkloadKey $script:WorkloadKey
        RestoreWarning = 'Hardware identifier uploads from source tenant are NOT carried over. After restore, re-import device hashes if needed.'
    }
}

#endregion

# ---------------------------------------------------------------------------
#region Import (Restore)
# ---------------------------------------------------------------------------

function Get-AutopilotProfileImportData {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][object]$Profile)

    $extra = @(
        'roleScopeTagIds'         # tenant-specific
        'enrolledDeviceCount'     # computed
        'managementServiceAppId'  # populated by service
    )
    return Remove-GraphMetaProperties -InputObject $Profile -ExtraProperties $extra
}

function Import-AutopilotProfile {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$ImportData,
        [int]$MaxRetries = 3
    )

    $name = if ($ImportData.displayName) { $ImportData.displayName } else { '<unnamed>' }
    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Importing: $name"

    try {
        $resp = Invoke-GraphRequestRetry -Method POST -Uri (_AP_BaseUri) -Body $ImportData -MaxRetries $MaxRetries
        Write-LogMessage -Level SUCCESS -Message "[$script:WorkloadKey] Created: $name (id: $($resp.id))"
        return @{ Success=$true; NewId=$resp.id; DisplayName=$name; Error=$null }
    }
    catch {
        Write-LogMessage -Level ERROR -Message "[$script:WorkloadKey] Import failed for '$name': $($_.Exception.Message)"
        return @{ Success=$false; NewId=$null; DisplayName=$name; Error=$_.Exception.Message }
    }
}

function Update-AutopilotProfile {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$ImportData,
        [Parameter(Mandatory)][string]   $ExistingId,
        [int]$MaxRetries = 3
    )
    $name = if ($ImportData.displayName) { $ImportData.displayName } else { '<unnamed>' }
    try {
        Invoke-GraphRequestRetry -Method PATCH -Uri "$(_AP_BaseUri)/$ExistingId" -Body $ImportData -MaxRetries $MaxRetries | Out-Null
        Write-LogMessage -Level SUCCESS -Message "[$script:WorkloadKey] Updated: $name (id: $ExistingId)"
        return @{ Success=$true; NewId=$ExistingId; DisplayName=$name; Error=$null }
    }
    catch {
        Write-LogMessage -Level ERROR -Message "[$script:WorkloadKey] Update failed for '$name': $($_.Exception.Message)"
        return @{ Success=$false; NewId=$null; DisplayName=$name; Error=$_.Exception.Message }
    }
}

function Get-ExistingAutopilotProfiles {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([int]$MaxRetries = 3)

    $map = @{}
    try {
        $list = Get-GraphAllPages -Uri "$(_AP_BaseUri)?`$select=id,displayName" -MaxRetries $MaxRetries
        foreach ($p in $list) {
            if ($p.displayName) { $map[$p.displayName.ToLowerInvariant()] = $p.id }
        }
    }
    catch {
        Write-LogMessage -Level WARN -Message "[$script:WorkloadKey] Existing-profile lookup failed: $($_.Exception.Message)"
    }
    return $map
}

#endregion

Export-ModuleMember -Function `
    Export-AutopilotProfiles, `
    Export-AutopilotProfile, `
    Get-AutopilotProfileImportData, `
    Import-AutopilotProfile, `
    Update-AutopilotProfile, `
    Get-ExistingAutopilotProfiles

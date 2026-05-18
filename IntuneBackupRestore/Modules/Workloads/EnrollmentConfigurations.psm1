<#
.SYNOPSIS
    Workload module: Intune Device Enrollment Configurations
    (Enrollment Status Page, enrollment platform restrictions, Windows Hello,
    enrollment notifications.)

.DESCRIPTION
    Graph endpoint : /deviceManagement/deviceEnrollmentConfigurations

    The collection is polymorphic — entries are derived types such as:
      * deviceEnrollmentLimitConfiguration
      * deviceEnrollmentPlatformRestrictionsConfiguration
      * deviceEnrollmentWindowsHelloForBusinessConfiguration
      * windows10EnrollmentCompletionPageConfiguration  (a.k.a. Enrollment Status Page)
      * deviceEnrollmentNotificationConfiguration

    The @odata.type discriminator is REQUIRED on POST – without it Graph
    returns 400 Bad Request.

    Restore behaviour:
      - The default tenant always carries built-in defaults that cannot be
        deleted/recreated; these are flagged backup-only via 'priority'/
        'isDefault'.
      - Newly created configs land at priority N; admins must reorder them
        in the UI afterwards.
#>

Set-StrictMode -Version Latest

$script:WorkloadKey  = 'EnrollmentConfigurations'
$script:WorkloadName = 'Enrollment Configurations'
$script:RelPath      = '/deviceManagement/deviceEnrollmentConfigurations'

function _EC_BaseUri { (Get-GraphRoot -WorkloadKey $script:WorkloadKey) + $script:RelPath }

# ---------------------------------------------------------------------------
#region Export
# ---------------------------------------------------------------------------

function Export-EnrollmentConfigurations {
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

    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Listing enrollment configurations..."

    try {
        $items = Get-GraphAllPages -Uri "$(_EC_BaseUri)?`$orderby=priority" -MaxRetries $MaxRetries
        Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Found $($items.Count) configuration(s)"
    }
    catch {
        $msg = "[$script:WorkloadKey] Listing failed: $($_.Exception.Message)"
        Write-LogMessage -Level ERROR -Message $msg
        $warnings.Add($msg)
        return @{ ExportedCount = 0; Warnings = $warnings.ToArray(); IndexEntries = $indexEntries.ToArray() }
    }

    foreach ($e in $items) {
        try {
            $entry = Export-EnrollmentConfiguration -Item $e -ExportPath $ExportPath `
                -IncludeAssignments $IncludeAssignments -ComputeChecksums $ComputeChecksums `
                -MaxRetries $MaxRetries
            $indexEntries.Add($entry)
            $exported++
        }
        catch {
            $msg = "[$script:WorkloadKey] Failed '$($e.displayName)': $($_.Exception.Message)"
            Write-LogMessage -Level WARN -Message $msg
            $warnings.Add($msg)
        }
    }

    return @{ ExportedCount = $exported; Warnings = $warnings.ToArray(); IndexEntries = $indexEntries.ToArray() }
}

function Export-EnrollmentConfiguration {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][string]$ExportPath,
        [bool]$IncludeAssignments = $true,
        [bool]$ComputeChecksums   = $true,
        [int] $MaxRetries         = 3
    )

    $id        = $Item.id
    $name      = if ($Item.displayName) { $Item.displayName } else { 'EnrollmentConfig' }
    $odataType = $Item.'@odata.type'
    $safeName  = ConvertTo-SafeFileName -Name $name
    $fileBase  = Join-Path $ExportPath "${safeName}_${id}"

    $full = Invoke-GraphRequestRetry -Method GET -Uri "$(_EC_BaseUri)/$id" -MaxRetries $MaxRetries

    $warning = $null
    if ($Item.PSObject.Properties['isDefault'] -and $Item.isDefault) {
        $warning = 'Default tenant configuration — cannot be recreated. Backup is for documentation only.'
    }

    $raw = [ordered]@{
        ExportedAt    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Workload      = $script:WorkloadKey
        DisplayName   = $name
        SourceId      = $id
        ODataType     = $odataType
        GraphEndpoint = (_EC_BaseUri)
        Configuration = $full
    }
    $rawFile = "$fileBase.json"
    Save-JsonFile -Object $raw -Path $rawFile

    $importBody = Get-EnrollmentConfigurationImportData -Configuration $full
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
        GraphEndpoint  = (_EC_BaseUri)
        CreatedDate    = $full.createdDateTime
        ModifiedDate   = $full.lastModifiedDateTime
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

function Get-EnrollmentConfigurationImportData {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][object]$Configuration)

    $extra = @(
        'priority'        # service-assigned ordering, must be re-set in UI
        'isDefault'       # tenant default flag
        'roleScopeTagIds' # tenant-specific
        'deviceEnrollmentConfigurationType' # alias of @odata.type
    )

    return Remove-GraphMetaProperties -InputObject $Configuration -ExtraProperties $extra
}

function Import-EnrollmentConfiguration {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$ImportData,
        [int]$MaxRetries = 3
    )

    $name = if ($ImportData.displayName) { $ImportData.displayName } else { '<unnamed>' }
    if ($ImportData['isDefault'] -eq $true) {
        return @{ Success=$false; NewId=$null; DisplayName=$name; Error='Default enrollment configurations cannot be recreated.' }
    }
    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Importing: $name ($($ImportData.'@odata.type'))"

    try {
        $resp = Invoke-GraphRequestRetry -Method POST -Uri (_EC_BaseUri) -Body $ImportData -MaxRetries $MaxRetries
        Write-LogMessage -Level SUCCESS -Message "[$script:WorkloadKey] Created: $name (id: $($resp.id))"
        return @{ Success=$true; NewId=$resp.id; DisplayName=$name; Error=$null }
    }
    catch {
        Write-LogMessage -Level ERROR -Message "[$script:WorkloadKey] Import failed for '$name': $($_.Exception.Message)"
        return @{ Success=$false; NewId=$null; DisplayName=$name; Error=$_.Exception.Message }
    }
}

function Get-ExistingEnrollmentConfigurations {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([int]$MaxRetries = 3)

    $map = @{}
    try {
        $list = Get-GraphAllPages -Uri "$(_EC_BaseUri)?`$select=id,displayName" -MaxRetries $MaxRetries
        foreach ($e in $list) {
            if ($e.displayName) { $map[$e.displayName.ToLowerInvariant()] = $e.id }
        }
    }
    catch {
        Write-LogMessage -Level WARN -Message "[$script:WorkloadKey] Existing-config lookup failed: $($_.Exception.Message)"
    }
    return $map
}

#endregion

Export-ModuleMember -Function `
    Export-EnrollmentConfigurations, `
    Export-EnrollmentConfiguration, `
    Get-EnrollmentConfigurationImportData, `
    Import-EnrollmentConfiguration, `
    Get-ExistingEnrollmentConfigurations

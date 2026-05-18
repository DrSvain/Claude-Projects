<#
.SYNOPSIS
    Workload module: Mobile App Configuration policies.

.DESCRIPTION
    Handles two related Graph collections:
      * /deviceAppManagement/mobileAppConfigurations
            App configuration for managed devices (MDM)
      * /deviceAppManagement/targetedManagedAppConfigurations
            App configuration for managed apps (MAM, Intune App Configuration
            policy for managed apps)

    Both are exported into the same backup folder. Index entries record which
    collection they originated from (via ODataType) so restore picks the
    correct POST endpoint.
#>

Set-StrictMode -Version Latest

$script:WorkloadKey  = 'AppConfiguration'
$script:WorkloadName = 'App Configuration Policies'
$script:RelMobile    = '/deviceAppManagement/mobileAppConfigurations'
$script:RelTargeted  = '/deviceAppManagement/targetedManagedAppConfigurations'

function _ACFG_BaseMobile   { (Get-GraphRoot -WorkloadKey $script:WorkloadKey) + $script:RelMobile }
function _ACFG_BaseTargeted { (Get-GraphRoot -WorkloadKey $script:WorkloadKey) + $script:RelTargeted }

# ---------------------------------------------------------------------------
#region Export
# ---------------------------------------------------------------------------

function Export-AppConfigurationPolicies {
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

    foreach ($section in @(
        @{ Uri = (_ACFG_BaseMobile);   Source = 'mobileAppConfigurations'        ; Label='MDM' }
        @{ Uri = (_ACFG_BaseTargeted); Source = 'targetedManagedAppConfigurations'; Label='MAM' }
    )) {
        Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Listing $($section.Label) app configurations..."

        try {
            $list = Get-GraphAllPages -Uri $section.Uri -MaxRetries $MaxRetries
            Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] $($section.Label) count: $($list.Count)"
        }
        catch {
            $msg = "[$script:WorkloadKey] $($section.Label) listing failed: $($_.Exception.Message)"
            Write-LogMessage -Level ERROR -Message $msg
            $warnings.Add($msg)
            continue
        }

        foreach ($c in $list) {
            try {
                $entry = Export-AppConfiguration -Configuration $c -SourceCollection $section.Source `
                    -ExportPath $ExportPath -IncludeAssignments $IncludeAssignments `
                    -ComputeChecksums $ComputeChecksums -MaxRetries $MaxRetries
                $indexEntries.Add($entry)
                $exported++
            }
            catch {
                $msg = "[$script:WorkloadKey] Failed '$($c.displayName)': $($_.Exception.Message)"
                Write-LogMessage -Level WARN -Message $msg
                $warnings.Add($msg)
            }
        }
    }

    return @{ ExportedCount = $exported; Warnings = $warnings.ToArray(); IndexEntries = $indexEntries.ToArray() }
}

function Export-AppConfiguration {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][ValidateSet('mobileAppConfigurations','targetedManagedAppConfigurations')]
        [string]$SourceCollection,
        [Parameter(Mandatory)][string]$ExportPath,
        [bool]$IncludeAssignments = $true,
        [bool]$ComputeChecksums   = $true,
        [int] $MaxRetries         = 3
    )

    $id        = $Configuration.id
    $name      = if ($Configuration.displayName) { $Configuration.displayName } else { 'AppConfig' }
    $odataType = $Configuration.'@odata.type'
    $safeName  = ConvertTo-SafeFileName -Name $name
    $fileBase  = Join-Path $ExportPath "${safeName}_${id}"

    $baseUri = if ($SourceCollection -eq 'mobileAppConfigurations') { _ACFG_BaseMobile } else { _ACFG_BaseTargeted }
    $full = Invoke-GraphRequestRetry -Method GET -Uri "$baseUri/$id" -MaxRetries $MaxRetries

    $raw = [ordered]@{
        ExportedAt       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Workload         = $script:WorkloadKey
        SourceCollection = $SourceCollection
        DisplayName      = $name
        SourceId         = $id
        ODataType        = $odataType
        GraphEndpoint    = $baseUri
        Configuration    = $full
    }
    $rawFile = "$fileBase.json"
    Save-JsonFile -Object $raw -Path $rawFile

    $importBody = Get-AppConfigurationImportData -Configuration $full -SourceCollection $SourceCollection
    $importFile = "$fileBase.import.json"
    Save-JsonFile -Object $importBody -Path $importFile

    $assignmentInfo = @{ HasAssignments=$false; AssignmentCount=0 }
    if ($IncludeAssignments) {
        # AssignmentEngine map points to mobileAppConfigurations only; for the
        # targeted MAM collection we still try its own /assignments endpoint.
        $assignmentInfo = Export-IntuneAssignments -WorkloadKey $script:WorkloadKey `
            -ObjectId $id -OutFileBase $fileBase -MaxRetries $MaxRetries
    }

    $checksum = if ($ComputeChecksums) { Get-SHA256 -FilePath $rawFile } else { $null }

    return @{
        DisplayName    = $name
        SourceId       = $id
        Category       = $script:WorkloadKey
        CategoryLabel  = "$script:WorkloadName ($SourceCollection)"
        ODataType      = $odataType
        SourceCollection = $SourceCollection
        GraphEndpoint  = $baseUri
        CreatedDate    = $full.createdDateTime
        ModifiedDate   = $full.lastModifiedDateTime
        FileName       = Split-Path $rawFile    -Leaf
        ImportFileName = Split-Path $importFile -Leaf
        Checksum       = $checksum
        HasAssignments = $assignmentInfo.HasAssignments
        EndpointVersion = Get-EndpointVersion -WorkloadKey $script:WorkloadKey
        RestoreWarning = $null
    }
}

#endregion

# ---------------------------------------------------------------------------
#region Import (Restore)
# ---------------------------------------------------------------------------

function Get-AppConfigurationImportData {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][string]$SourceCollection
    )

    $extra = @(
        'roleScopeTagIds'
        'deployedAppCount'
        'isAssigned'
    )
    $body = Remove-GraphMetaProperties -InputObject $Configuration -ExtraProperties $extra

    # Persist source collection so Import-AppConfiguration knows where to POST.
    # Tag is ignored by Graph if accidentally posted but we strip it anyway.
    $body['_sourceCollection'] = $SourceCollection
    return $body
}

function Import-AppConfiguration {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$ImportData,
        [int]$MaxRetries = 3
    )

    $name      = if ($ImportData.displayName) { $ImportData.displayName } else { '<unnamed>' }
    $sourceCol = [string]$ImportData['_sourceCollection']
    $ImportData.Remove('_sourceCollection')

    $postUri = if ($sourceCol -eq 'targetedManagedAppConfigurations') { _ACFG_BaseTargeted } else { _ACFG_BaseMobile }
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

function Get-ExistingAppConfigurations {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([int]$MaxRetries = 3)

    $map = @{}
    foreach ($uri in @((_ACFG_BaseMobile), (_ACFG_BaseTargeted))) {
        try {
            $list = Get-GraphAllPages -Uri "$uri`?`$select=id,displayName" -MaxRetries $MaxRetries
            foreach ($c in $list) {
                if ($c.displayName) { $map[$c.displayName.ToLowerInvariant()] = $c.id }
            }
        }
        catch {
            Write-LogMessage -Level WARN -Message "[$script:WorkloadKey] Existing-config lookup failed for $uri : $($_.Exception.Message)"
        }
    }
    return $map
}

#endregion

Export-ModuleMember -Function `
    Export-AppConfigurationPolicies, `
    Export-AppConfiguration, `
    Get-AppConfigurationImportData, `
    Import-AppConfiguration, `
    Get-ExistingAppConfigurations

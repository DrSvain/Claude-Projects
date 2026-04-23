<#
.SYNOPSIS
    Workload module: Intune Compliance Policies

.DESCRIPTION
    Graph endpoint : /v1.0/deviceManagement/deviceCompliancePolicies

    Export strategy:
      - List all policies (paged)
      - For each: fetch full detail + scheduledActionsForRule (expanded) + assignments
      - Save one raw JSON file (<Name>_<Id>.json)          – full source data
      - Save one import-ready JSON file (<Name>_<Id>.import.json)

    Restore strategy:
      - POST to /deviceCompliancePolicies with cleaned body
      - Always creates a NEW policy (updates are not attempted in v1.0)
      - Notification template references are cleared – they are tenant-specific

    Known limitations documented in README:
      - Notification message templates must be recreated manually in the target tenant
      - Assignments are NOT restored (group IDs are tenant-specific)
#>

Set-StrictMode -Version Latest

$script:WorkloadKey  = 'CompliancePolicies'
$script:WorkloadName = 'Compliance Policies'
$script:BaseUri      = 'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies'

# ---------------------------------------------------------------------------
#region Export
# ---------------------------------------------------------------------------

function Export-CompliancePolicies {
    <#
    .SYNOPSIS
        Exports every compliance policy in the connected tenant.

    .OUTPUTS
        [hashtable]
            ExportedCount [int]
            Warnings      [string[]]
            IndexEntries  [hashtable[]]
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

    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Listing compliance policies..."

    try {
        $policies = Get-GraphAllPages -Uri "$($script:BaseUri)?`$orderby=displayName" -MaxRetries $MaxRetries
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
            $entry = Export-CompliancePolicy `
                -Policy             $p `
                -ExportPath         $ExportPath `
                -IncludeAssignments $IncludeAssignments `
                -ComputeChecksums   $ComputeChecksums `
                -MaxRetries         $MaxRetries

            $indexEntries.Add($entry)
            $exported++
            Write-LogMessage -Level DEBUG -Message "[$script:WorkloadKey] Exported: $($p.displayName)"
        }
        catch {
            $msg = "[$script:WorkloadKey] Failed '$($p.displayName)': $($_.Exception.Message)"
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

function Export-CompliancePolicy {
    <#
    .SYNOPSIS
        Exports a single compliance policy: raw + import-ready JSON files.
    .OUTPUTS
        [hashtable]  Index entry (DisplayName, SourceId, Category, …, FileName, ImportFileName, Checksum)
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
    $name     = $Policy.displayName
    $safeName = ConvertTo-SafeFileName -Name $name
    $fileBase = Join-Path $ExportPath "${safeName}_${id}"

    # Full detail (list view may omit properties)
    $full = Invoke-GraphRequestRetry -Method GET -Uri "$($script:BaseUri)/$id" -MaxRetries $MaxRetries

    # Scheduled actions (notification rules)
    $scheduled = $null
    try {
        $resp = Invoke-GraphRequestRetry `
            -Method     GET `
            -Uri        "$($script:BaseUri)/$id/scheduledActionsForRule?`$expand=scheduledActionConfigurations" `
            -MaxRetries $MaxRetries
        $scheduled = $resp.value
    }
    catch {
        Write-LogMessage -Level DEBUG -Message "[$script:WorkloadKey] scheduledActionsForRule not retrievable for '$name': $($_.Exception.Message)"
    }

    # Assignments (documentation only)
    $assignments = $null
    if ($IncludeAssignments) {
        try {
            $resp = Invoke-GraphRequestRetry -Method GET -Uri "$($script:BaseUri)/$id/assignments" -MaxRetries $MaxRetries
            $assignments = $resp.value
        }
        catch {
            Write-LogMessage -Level DEBUG -Message "[$script:WorkloadKey] assignments not retrievable for '$name': $($_.Exception.Message)"
        }
    }

    # Raw export package
    $rawPackage = [ordered]@{
        ExportedAt       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Workload         = $script:WorkloadKey
        DisplayName      = $name
        SourceId         = $id
        GraphEndpoint    = $script:BaseUri
        Policy           = $full
        ScheduledActions = $scheduled
        Assignments      = $assignments
    }
    $rawFile = "$fileBase.json"
    Save-JsonFile -Object $rawPackage -Path $rawFile

    # Import-ready data
    $import     = Get-CompliancePolicyImportData -Policy $full -ScheduledActions $scheduled
    $importFile = "$fileBase.import.json"
    Save-JsonFile -Object $import -Path $importFile

    $checksum = if ($ComputeChecksums) { Get-SHA256 -FilePath $rawFile } else { $null }

    return @{
        DisplayName    = $name
        SourceId       = $id
        Category       = $script:WorkloadKey
        CategoryLabel  = $script:WorkloadName
        ODataType      = $full.'@odata.type'
        GraphEndpoint  = $script:BaseUri
        CreatedDate    = $full.createdDateTime
        ModifiedDate   = $full.lastModifiedDateTime
        FileName       = Split-Path $rawFile    -Leaf
        ImportFileName = Split-Path $importFile -Leaf
        Checksum       = $checksum
        HasAssignments = ($null -ne $assignments -and $assignments.Count -gt 0)
    }
}

#endregion

# ---------------------------------------------------------------------------
#region Import (Restore)
# ---------------------------------------------------------------------------

function Get-CompliancePolicyImportData {
    <#
    .SYNOPSIS
        Produces a restore-ready body from a raw compliance policy.

    .DESCRIPTION
        Removed fields:
            id, createdDateTime, lastModifiedDateTime, version,
            @odata.context, @odata.etag
        Kept:
            @odata.type   (polymorphism – different for iOS/Android/Windows/macOS)

        scheduledActionsForRule is merged back in but:
            - Rule id / config id stripped
            - notificationTemplateId blanked (tenant-specific)
            - notificationMessageCCList emptied  (tenant-specific)

    .OUTPUTS
        [hashtable]  Ready to POST to $BaseUri
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Policy,
        [object[]]$ScheduledActions = $null
    )

    $body = Remove-GraphMetaProperties -InputObject $Policy

    # Re-embed cleaned scheduledActionsForRule
    if ($ScheduledActions -and $ScheduledActions.Count -gt 0) {
        $cleanedRules = foreach ($rule in $ScheduledActions) {
            $r = ConvertTo-Hashtable -InputObject $rule
            $r.Remove('id')

            if ($r.scheduledActionConfigurations) {
                $r.scheduledActionConfigurations = @(
                    foreach ($cfg in $r.scheduledActionConfigurations) {
                        $c = ConvertTo-Hashtable -InputObject $cfg
                        $c.Remove('id')
                        $c['notificationTemplateId']    = ''
                        $c['notificationMessageCCList'] = @()
                        $c
                    }
                )
            }
            $r
        }
        $body['scheduledActionsForRule'] = @($cleanedRules)
    }

    return $body
}

function Import-CompliancePolicy {
    <#
    .SYNOPSIS
        Creates a new compliance policy in the current tenant from import data.
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
    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Importing: $name"

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

function Get-ExistingCompliancePolicies {
    <#
    .SYNOPSIS
        Returns a lookup-table of existing policies (lower-case name → id).
        Used by the RestoreEngine for conflict detection.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([int]$MaxRetries = 3)

    $map = @{}
    try {
        $list = Get-GraphAllPages -Uri "$($script:BaseUri)?`$select=id,displayName" -MaxRetries $MaxRetries
        foreach ($p in $list) {
            $map[$p.displayName.ToLowerInvariant()] = $p.id
        }
    }
    catch {
        Write-LogMessage -Level WARN -Message "[$script:WorkloadKey] Existing-policy lookup failed: $($_.Exception.Message)"
    }
    return $map
}

#endregion

Export-ModuleMember -Function `
    Export-CompliancePolicies, `
    Export-CompliancePolicy, `
    Get-CompliancePolicyImportData, `
    Import-CompliancePolicy, `
    Get-ExistingCompliancePolicies

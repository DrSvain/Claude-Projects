<#
.SYNOPSIS
    Workload module: Proactive Remediations (deviceHealthScripts).

.DESCRIPTION
    Graph endpoint : /beta/deviceManagement/deviceHealthScripts
    NOTE: This collection ONLY exists on the beta endpoint. The
    Helpers.psm1::BetaOnlyWorkloads list pins this workload to 'beta'.

    Each Proactive Remediation is a pair of scripts:
      - detectionScriptContent      (base64 PowerShell)
      - remediationScriptContent    (base64 PowerShell)

    Backup writes a sidecar .detection.ps1 / .remediation.ps1 (decoded UTF-8)
    next to the JSON for human readability and source control friendliness.

    Restore re-uploads the base64 script content as-is.

    Restore requires Endpoint Analytics licensing in the target tenant.
    Without it, POST returns 403 with a clear license-error body.
#>

Set-StrictMode -Version Latest

$script:WorkloadKey  = 'ProactiveRemediations'
$script:WorkloadName = 'Proactive Remediations'
$script:RelPath      = '/deviceManagement/deviceHealthScripts'

function _PR_BaseUri { (Get-GraphRoot -WorkloadKey $script:WorkloadKey) + $script:RelPath }

# ---------------------------------------------------------------------------
#region Export
# ---------------------------------------------------------------------------

function Export-ProactiveRemediations {
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

    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Listing proactive remediation scripts (beta)..."

    try {
        $list = Get-GraphAllPages -Uri "$(_PR_BaseUri)?`$orderby=displayName" -MaxRetries $MaxRetries
        Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Found $($list.Count) script pair(s)"
    }
    catch {
        $msg = "[$script:WorkloadKey] Listing failed (Endpoint Analytics license required): $($_.Exception.Message)"
        Write-LogMessage -Level WARN -Message $msg
        $warnings.Add($msg)
        return @{ ExportedCount = 0; Warnings = $warnings.ToArray(); IndexEntries = $indexEntries.ToArray() }
    }

    foreach ($s in $list) {
        try {
            $entry = Export-ProactiveRemediation -Script $s -ExportPath $ExportPath `
                -IncludeAssignments $IncludeAssignments -ComputeChecksums $ComputeChecksums `
                -MaxRetries $MaxRetries
            $indexEntries.Add($entry)
            $exported++
        }
        catch {
            $msg = "[$script:WorkloadKey] Failed '$($s.displayName)': $($_.Exception.Message)"
            Write-LogMessage -Level WARN -Message $msg
            $warnings.Add($msg)
        }
    }

    return @{ ExportedCount = $exported; Warnings = $warnings.ToArray(); IndexEntries = $indexEntries.ToArray() }
}

function Export-ProactiveRemediation {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Script,
        [Parameter(Mandatory)][string]$ExportPath,
        [bool]$IncludeAssignments = $true,
        [bool]$ComputeChecksums   = $true,
        [int] $MaxRetries         = 3
    )

    $id       = $Script.id
    $name     = $Script.displayName
    $safeName = ConvertTo-SafeFileName -Name $name
    $fileBase = Join-Path $ExportPath "${safeName}_${id}"

    $full = Invoke-GraphRequestRetry -Method GET -Uri "$(_PR_BaseUri)/$id" -MaxRetries $MaxRetries

    # Decode and persist plain-text script bodies for source control / review.
    if ($full.detectionScriptContent) {
        try {
            $bytes = [Convert]::FromBase64String($full.detectionScriptContent)
            $text  = [System.Text.Encoding]::UTF8.GetString($bytes)
            Set-Content -Path "$fileBase.detection.ps1" -Value $text -Encoding UTF8 -Force
        } catch { }
    }
    if ($full.remediationScriptContent) {
        try {
            $bytes = [Convert]::FromBase64String($full.remediationScriptContent)
            $text  = [System.Text.Encoding]::UTF8.GetString($bytes)
            Set-Content -Path "$fileBase.remediation.ps1" -Value $text -Encoding UTF8 -Force
        } catch { }
    }

    $raw = [ordered]@{
        ExportedAt    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Workload      = $script:WorkloadKey
        DisplayName   = $name
        SourceId      = $id
        GraphEndpoint = (_PR_BaseUri)
        Script        = $full
    }
    $rawFile = "$fileBase.json"
    Save-JsonFile -Object $raw -Path $rawFile

    $importBody = Get-ProactiveRemediationImportData -Script $full
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
        GraphEndpoint  = (_PR_BaseUri)
        CreatedDate    = $full.createdDateTime
        ModifiedDate   = $full.lastModifiedDateTime
        FileName       = Split-Path $rawFile    -Leaf
        ImportFileName = Split-Path $importFile -Leaf
        Checksum       = $checksum
        HasAssignments = $assignmentInfo.HasAssignments
        EndpointVersion = Get-EndpointVersion -WorkloadKey $script:WorkloadKey
        RestoreWarning = 'Requires Endpoint Analytics license in target tenant. POST will fail with 403 if license is missing.'
    }
}

#endregion

# ---------------------------------------------------------------------------
#region Import (Restore)
# ---------------------------------------------------------------------------

function Get-ProactiveRemediationImportData {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][object]$Script)

    $extra = @(
        'highestAvailableVersion'
        'isGlobalScript'
        'deviceHealthScriptType'  # alias of @odata.type
        'roleScopeTagIds'
    )
    return Remove-GraphMetaProperties -InputObject $Script -ExtraProperties $extra
}

function Import-ProactiveRemediation {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$ImportData,
        [int]$MaxRetries = 3
    )

    $name = if ($ImportData.displayName) { $ImportData.displayName } else { '<unnamed>' }
    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Importing: $name"

    try {
        $resp = Invoke-GraphRequestRetry -Method POST -Uri (_PR_BaseUri) -Body $ImportData -MaxRetries $MaxRetries
        Write-LogMessage -Level SUCCESS -Message "[$script:WorkloadKey] Created: $name (id: $($resp.id))"
        return @{ Success=$true; NewId=$resp.id; DisplayName=$name; Error=$null }
    }
    catch {
        Write-LogMessage -Level ERROR -Message "[$script:WorkloadKey] Import failed for '$name': $($_.Exception.Message)"
        return @{ Success=$false; NewId=$null; DisplayName=$name; Error=$_.Exception.Message }
    }
}

function Get-ExistingProactiveRemediations {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([int]$MaxRetries = 3)

    $map = @{}
    try {
        $list = Get-GraphAllPages -Uri "$(_PR_BaseUri)?`$select=id,displayName" -MaxRetries $MaxRetries
        foreach ($s in $list) {
            if ($s.displayName) { $map[$s.displayName.ToLowerInvariant()] = $s.id }
        }
    }
    catch {
        Write-LogMessage -Level DEBUG -Message "[$script:WorkloadKey] Existing-script lookup failed: $($_.Exception.Message)"
    }
    return $map
}

#endregion

Export-ModuleMember -Function `
    Export-ProactiveRemediations, `
    Export-ProactiveRemediation, `
    Get-ProactiveRemediationImportData, `
    Import-ProactiveRemediation, `
    Get-ExistingProactiveRemediations

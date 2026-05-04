<#
.SYNOPSIS
    Workload module: Group Policy Administrative Templates (ADMX).

.DESCRIPTION
    Graph endpoint : /beta/deviceManagement/groupPolicyConfigurations
    NOTE: This collection is BETA-ONLY. Pinned to 'beta' in Helpers.psm1.

    A groupPolicyConfiguration is an envelope; the actual settings live in
    /definitionValues, where each entry references a definition (an ADMX
    template setting) and provides a value.

    Backup strategy:
      1. List all configurations (paged).
      2. For each, GET the configuration metadata.
      3. GET .../definitionValues?$expand=definition,presentationValues($expand=presentation)
         which returns a denormalized snapshot suitable for human review.
      4. Persist raw + import-ready JSON.

    Restore strategy (best-effort, see Known Limitations):
      1. POST the configuration envelope -> get new id.
      2. For each backed-up definitionValue, POST to
         /groupPolicyConfigurations/{newId}/definitionValues with a body that
         references definitions by definitionId. Definition ids are global
         per ADMX schema and are usually identical across tenants for the
         same Microsoft-published template; custom ADMX uploads may differ
         and will fail to resolve. We log per-setting outcomes and keep
         going.
#>

Set-StrictMode -Version Latest

$script:WorkloadKey  = 'AdministrativeTemplates'
$script:WorkloadName = 'Administrative Templates'
$script:RelPath      = '/deviceManagement/groupPolicyConfigurations'

function _AT_BaseUri { (Get-GraphRoot -WorkloadKey $script:WorkloadKey) + $script:RelPath }

# ---------------------------------------------------------------------------
#region Export
# ---------------------------------------------------------------------------

function Export-AdministrativeTemplates {
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

    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Listing administrative templates (beta)..."

    try {
        $list = Get-GraphAllPages -Uri "$(_AT_BaseUri)?`$orderby=displayName" -MaxRetries $MaxRetries
        Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Found $($list.Count) configuration(s)"
    }
    catch {
        $msg = "[$script:WorkloadKey] Listing failed: $($_.Exception.Message)"
        Write-LogMessage -Level ERROR -Message $msg
        $warnings.Add($msg)
        return @{ ExportedCount = 0; Warnings = $warnings.ToArray(); IndexEntries = $indexEntries.ToArray() }
    }

    foreach ($c in $list) {
        try {
            $entry = Export-AdministrativeTemplate -Configuration $c -ExportPath $ExportPath `
                -IncludeAssignments $IncludeAssignments -ComputeChecksums $ComputeChecksums `
                -MaxRetries $MaxRetries
            $indexEntries.Add($entry)
            $exported++
        }
        catch {
            $msg = "[$script:WorkloadKey] Failed '$($c.displayName)': $($_.Exception.Message)"
            Write-LogMessage -Level WARN -Message $msg
            $warnings.Add($msg)
        }
    }

    return @{ ExportedCount = $exported; Warnings = $warnings.ToArray(); IndexEntries = $indexEntries.ToArray() }
}

function Export-AdministrativeTemplate {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][string]$ExportPath,
        [bool]$IncludeAssignments = $true,
        [bool]$ComputeChecksums   = $true,
        [int] $MaxRetries         = 3
    )

    $id       = $Configuration.id
    $name     = $Configuration.displayName
    $safeName = ConvertTo-SafeFileName -Name $name
    $fileBase = Join-Path $ExportPath "${safeName}_${id}"

    $full = Invoke-GraphRequestRetry -Method GET -Uri "$(_AT_BaseUri)/$id" -MaxRetries $MaxRetries

    # Pull the definitionValues with their settings expanded.
    $defValues = @()
    try {
        $expand   = '$expand=definition,presentationValues($expand=presentation)'
        $valUri   = "$(_AT_BaseUri)/$id/definitionValues?$expand"
        $defValues = Get-GraphAllPages -Uri $valUri -MaxRetries $MaxRetries
    }
    catch {
        Write-LogMessage -Level WARN -Message "[$script:WorkloadKey] definitionValues fetch failed for '$name': $($_.Exception.Message)"
    }

    $raw = [ordered]@{
        ExportedAt       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Workload         = $script:WorkloadKey
        DisplayName      = $name
        SourceId         = $id
        GraphEndpoint    = (_AT_BaseUri)
        Configuration    = $full
        DefinitionValues = $defValues
    }
    $rawFile = "$fileBase.json"
    Save-JsonFile -Object $raw -Path $rawFile

    $importBody = Get-AdministrativeTemplateImportData -Configuration $full -DefinitionValues $defValues
    $importFile = "$fileBase.import.json"
    Save-JsonFile -Object $importBody -Path $importFile

    $assignmentInfo = @{ HasAssignments=$false; AssignmentCount=0 }
    if ($IncludeAssignments) {
        $assignmentInfo = Export-IntuneAssignments -WorkloadKey $script:WorkloadKey `
            -ObjectId $id -OutFileBase $fileBase -MaxRetries $MaxRetries
    }

    $checksum = if ($ComputeChecksums) { Get-SHA256 -FilePath $rawFile } else { $null }

    $hasCustomAdmx = $false
    foreach ($dv in $defValues) {
        if ($dv.definition -and $dv.definition.classType -eq 'user' -and $dv.definition.policyType -eq 'admxIngested') {
            $hasCustomAdmx = $true; break
        }
    }
    $warning = if ($hasCustomAdmx) { 'References ingested ADMX templates; ensure the same ADMX is uploaded in target tenant before restore.' } else { $null }

    return @{
        DisplayName    = $name
        SourceId       = $id
        Category       = $script:WorkloadKey
        CategoryLabel  = $script:WorkloadName
        ODataType      = $full.'@odata.type'
        GraphEndpoint  = (_AT_BaseUri)
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

function Get-AdministrativeTemplateImportData {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [object[]]$DefinitionValues = @()
    )

    $extra = @('roleScopeTagIds')
    $body = Remove-GraphMetaProperties -InputObject $Configuration -ExtraProperties $extra

    if ($DefinitionValues -and $DefinitionValues.Count -gt 0) {
        $cleanValues = foreach ($dv in $DefinitionValues) {
            $h = ConvertTo-Hashtable -InputObject $dv
            $h.Remove('id')
            # Definition is referenced by id only on POST; expanded form (definition, presentationValues)
            # is descriptive and stripped here.
            if ($h.definition -and $h.definition.id) {
                $h['definition@odata.bind'] = "https://graph.microsoft.com/beta/deviceManagement/groupPolicyDefinitions('$($h.definition.id)')"
            }
            $h.Remove('definition')

            if ($h.presentationValues) {
                $cleanPV = foreach ($pv in $h.presentationValues) {
                    $p = ConvertTo-Hashtable -InputObject $pv
                    $p.Remove('id')
                    if ($p.presentation -and $p.presentation.id) {
                        $p['presentation@odata.bind'] = "https://graph.microsoft.com/beta/deviceManagement/groupPolicyDefinitions('$($h['definition@odata.bind'] -replace ".*'(.+)'.*",'$1')')/presentations('$($p.presentation.id)')"
                    }
                    $p.Remove('presentation')
                    $p
                }
                $h.presentationValues = @($cleanPV)
            }
            $h
        }
        $body['_definitionValues'] = @($cleanValues)
    }

    return $body
}

function Import-AdministrativeTemplate {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$ImportData,
        [int]$MaxRetries = 3
    )

    $name = if ($ImportData.displayName) { $ImportData.displayName } else { '<unnamed>' }
    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Importing: $name"

    $defValues = @()
    if ($ImportData.ContainsKey('_definitionValues')) {
        $defValues = $ImportData['_definitionValues']
        $ImportData.Remove('_definitionValues')
    }

    try {
        $resp = Invoke-GraphRequestRetry -Method POST -Uri (_AT_BaseUri) -Body $ImportData -MaxRetries $MaxRetries
        $newId = $resp.id
        Write-LogMessage -Level SUCCESS -Message "[$script:WorkloadKey] Created envelope: $name (id: $newId)"

        # Now POST each definitionValue. Soft-fail per setting.
        $errors = [System.Collections.Generic.List[string]]::new()
        foreach ($dv in $defValues) {
            try {
                Invoke-GraphRequestRetry `
                    -Method POST `
                    -Uri    "$(_AT_BaseUri)/$newId/definitionValues" `
                    -Body   $dv `
                    -MaxRetries $MaxRetries | Out-Null
            }
            catch {
                $errors.Add($_.Exception.Message)
                Write-LogMessage -Level WARN -Message "[$script:WorkloadKey] Setting failed in '$name': $($_.Exception.Message)"
            }
        }

        if ($errors.Count -gt 0) {
            return @{
                Success     = $true   # envelope created
                NewId       = $newId
                DisplayName = $name
                Error       = "Some definitionValues failed: $($errors.Count) error(s)"
            }
        }
        return @{ Success=$true; NewId=$newId; DisplayName=$name; Error=$null }
    }
    catch {
        Write-LogMessage -Level ERROR -Message "[$script:WorkloadKey] Import failed for '$name': $($_.Exception.Message)"
        return @{ Success=$false; NewId=$null; DisplayName=$name; Error=$_.Exception.Message }
    }
}

function Get-ExistingAdministrativeTemplates {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([int]$MaxRetries = 3)

    $map = @{}
    try {
        $list = Get-GraphAllPages -Uri "$(_AT_BaseUri)?`$select=id,displayName" -MaxRetries $MaxRetries
        foreach ($c in $list) {
            if ($c.displayName) { $map[$c.displayName.ToLowerInvariant()] = $c.id }
        }
    }
    catch {
        Write-LogMessage -Level DEBUG -Message "[$script:WorkloadKey] Existing-template lookup failed: $($_.Exception.Message)"
    }
    return $map
}

#endregion

Export-ModuleMember -Function `
    Export-AdministrativeTemplates, `
    Export-AdministrativeTemplate, `
    Get-AdministrativeTemplateImportData, `
    Import-AdministrativeTemplate, `
    Get-ExistingAdministrativeTemplates

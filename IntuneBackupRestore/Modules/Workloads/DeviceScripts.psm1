<#
.SYNOPSIS
    Workload module: Intune Device Management Scripts

.DESCRIPTION
    Graph endpoint : /v1.0/deviceManagement/deviceManagementScripts

    Export strategy:
      - List all scripts (paged)
      - For each: fetch full detail (scriptContent is included on individual GET)
      - Decode Base64 scriptContent → save as <Name>_<Id>.ps1  (human-readable)
      - Save <Name>_<Id>.json          (raw, with Base64 scriptContent)
      - Save <Name>_<Id>.import.json   (cleaned, Base64 scriptContent kept)

    Restore strategy:
      - POST to /deviceManagementScripts
      - scriptContent MUST be Base64-encoded UTF-16LE (PowerShell default)
        or UTF-8 depending on the script's original encoding.
      - The import body uses the stored Base64 value from the export file.
        If the admin edited the .ps1 file, a separate re-encode step is noted.

    Known limitations:
      - scriptContent encoding: the tool preserves the original Base64 exactly.
        If a script was originally UTF-16LE the re-import will also use UTF-16LE.
      - runAsAccount (system / user) and enforceSignatureCheck are preserved.
      - Assignments are NOT restored.
      - Detection scripts (deviceHealthScripts / Proactive Remediations) use a
        different endpoint and are NOT covered here (license-gated in many tenants).
#>

Set-StrictMode -Version Latest

$script:WorkloadKey  = 'DeviceScripts'
$script:WorkloadName = 'Device Management Scripts'
$script:BaseUri      = 'https://graph.microsoft.com/v1.0/deviceManagement/deviceManagementScripts'

# ---------------------------------------------------------------------------
#region Base64 helpers
# ---------------------------------------------------------------------------

function ConvertFrom-Base64Script {
    <#
    .SYNOPSIS
        Decodes a Base64 scriptContent string to a readable PowerShell string.
        Tries UTF-16LE first (PowerShell default), falls back to UTF-8.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Base64Content
    )

    try {
        $bytes = [Convert]::FromBase64String($Base64Content)

        # Detect UTF-16LE BOM (FF FE)
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            return [System.Text.Encoding]::Unicode.GetString($bytes)
        }

        # Default: UTF-8
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    catch {
        Write-LogMessage -Level WARN -Message "[$script:WorkloadKey] Base64 decode failed: $($_.Exception.Message)"
        return $null
    }
}

function ConvertTo-Base64Script {
    <#
    .SYNOPSIS
        Re-encodes a plain-text PowerShell script string to Base64 UTF-8.
        Used when the admin edits the .ps1 file before restore.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ScriptContent
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($ScriptContent)
    return [Convert]::ToBase64String($bytes)
}

#endregion

# ---------------------------------------------------------------------------
#region Export
# ---------------------------------------------------------------------------

function Export-DeviceScripts {
    <#
    .SYNOPSIS
        Exports all Device Management Scripts.
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

    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Listing device management scripts..."

    try {
        # Note: scriptContent is NOT returned in the list response.
        # It is only available via GET /deviceManagementScripts/{id}
        $scripts = Get-GraphAllPages `
            -Uri        "$($script:BaseUri)?`$orderby=displayName" `
            -MaxRetries $MaxRetries

        Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Found $($scripts.Count) script(s)"
    }
    catch {
        $msg = "[$script:WorkloadKey] Listing failed: $($_.Exception.Message)"
        Write-LogMessage -Level ERROR -Message $msg -ErrorRecord $_
        $warnings.Add($msg)
        return @{ ExportedCount = 0; Warnings = $warnings.ToArray(); IndexEntries = $indexEntries.ToArray() }
    }

    foreach ($s in $scripts) {
        try {
            $entry = Export-DeviceScript `
                -Script             $s `
                -ExportPath         $ExportPath `
                -IncludeAssignments $IncludeAssignments `
                -ComputeChecksums   $ComputeChecksums `
                -MaxRetries         $MaxRetries

            $indexEntries.Add($entry)
            $exported++
            Write-LogMessage -Level DEBUG -Message "[$script:WorkloadKey] Exported: $($s.displayName)"
        }
        catch {
            $msg = "[$script:WorkloadKey] Failed '$($s.displayName)': $($_.Exception.Message)"
            Write-LogMessage -Level WARN -Message $msg -ErrorRecord $_
            $warnings.Add($msg)
        }
    }

    Write-LogMessage -Level INFO -Message "[$script:WorkloadKey] Export complete: $exported/$($scripts.Count)"

    return @{
        ExportedCount = $exported
        Warnings      = $warnings.ToArray()
        IndexEntries  = $indexEntries.ToArray()
    }
}

function Export-DeviceScript {
    <#
    .SYNOPSIS
        Exports a single Device Management Script.
        Saves JSON (raw), import-ready JSON, and decoded .ps1 file.
    .OUTPUTS
        [hashtable]  Index entry
    #>
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

    # Individual GET is required – scriptContent is omitted from list responses
    $full = Invoke-GraphRequestRetry `
        -Method     GET `
        -Uri        "$($script:BaseUri)/$id" `
        -MaxRetries $MaxRetries

    # Decode scriptContent to a human-readable .ps1 file
    $scriptText = $null
    $ps1File    = $null
    if ($full.scriptContent) {
        $scriptText = ConvertFrom-Base64Script -Base64Content $full.scriptContent
        if ($scriptText) {
            $ps1FileName = if ($full.fileName) {
                ConvertTo-SafeFileName -Name ([System.IO.Path]::GetFileNameWithoutExtension($full.fileName))
            } else {
                $safeName
            }
            $ps1File = Join-Path $ExportPath "${ps1FileName}_${id}.ps1"
            Set-Content -Path $ps1File -Value $scriptText -Encoding UTF8 -Force
        }
    }

    # Assignments (documentation)
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

    # Raw export package
    $raw = [ordered]@{
        ExportedAt    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Workload      = $script:WorkloadKey
        DisplayName   = $name
        SourceId      = $id
        GraphEndpoint = $script:BaseUri
        ScriptFile    = if ($ps1File) { Split-Path $ps1File -Leaf } else { $null }
        Script        = $full
        Assignments   = $assignments
    }
    $rawFile = "$fileBase.json"
    Save-JsonFile -Object $raw -Path $rawFile

    # Import-ready JSON
    $import     = Get-DeviceScriptImportData -Script $full
    $importFile = "$fileBase.import.json"
    Save-JsonFile -Object $import -Path $importFile

    $checksum = if ($ComputeChecksums) { Get-SHA256 -FilePath $rawFile } else { $null }

    return @{
        DisplayName    = $name
        SourceId       = $id
        Category       = $script:WorkloadKey
        CategoryLabel  = $script:WorkloadName
        ODataType      = $null
        GraphEndpoint  = $script:BaseUri
        CreatedDate    = $full.createdDateTime
        ModifiedDate   = $full.lastModifiedDateTime
        FileName       = Split-Path $rawFile    -Leaf
        ImportFileName = Split-Path $importFile -Leaf
        ScriptFile     = if ($ps1File) { Split-Path $ps1File -Leaf } else { $null }
        Checksum       = $checksum
        HasAssignments = ($null -ne $assignments -and $assignments.Count -gt 0)
        RestoreWarning = $null
        RunAsAccount   = $full.runAsAccount
        EnforceSignature = $full.enforceSignatureCheck
    }
}

#endregion

# ---------------------------------------------------------------------------
#region Import (Restore)
# ---------------------------------------------------------------------------

function Get-DeviceScriptImportData {
    <#
    .SYNOPSIS
        Produces a POST-ready body from a raw device management script.

    .DESCRIPTION
        Removed:
            id, createdDateTime, lastModifiedDateTime, @odata.context, @odata.etag

        Preserved (all required for POST):
            displayName, description, scriptContent (Base64), fileName,
            runAsAccount, enforceSignatureCheck, runAs32Bit

        scriptContent: the original Base64 value is kept as-is.
        If the admin wants to use the edited .ps1 file instead, they must
        call ConvertTo-Base64Script on the edited content and replace
        the scriptContent field before calling Import-DeviceScript.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Script
    )

    return Remove-GraphMetaProperties -InputObject $Script
}

function Import-DeviceScript {
    <#
    .SYNOPSIS
        Creates a new Device Management Script in the current tenant.
    .PARAMETER ImportData
        Hashtable from Get-DeviceScriptImportData (or with manually replaced scriptContent).
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

    # Validate scriptContent is present and non-empty
    if (-not $ImportData.scriptContent) {
        $err = "scriptContent is missing or empty – cannot import '$name'."
        Write-LogMessage -Level ERROR -Message "[$script:WorkloadKey] $err"
        return @{ Success = $false; NewId = $null; DisplayName = $name; Error = $err }
    }

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

function Get-ExistingDeviceScripts {
    <#
    .SYNOPSIS
        Returns displayName → id lookup for existing scripts.
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

        foreach ($s in $list) {
            if ($s.displayName) { $map[$s.displayName.ToLowerInvariant()] = $s.id }
        }
    }
    catch {
        Write-LogMessage -Level WARN -Message "[$script:WorkloadKey] Existing-scripts lookup failed: $($_.Exception.Message)"
    }
    return $map
}

#endregion

Export-ModuleMember -Function `
    Export-DeviceScripts, `
    Export-DeviceScript, `
    Get-DeviceScriptImportData, `
    Import-DeviceScript, `
    Get-ExistingDeviceScripts, `
    ConvertFrom-Base64Script, `
    ConvertTo-Base64Script

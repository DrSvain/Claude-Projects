<#
.SYNOPSIS
    Shared helper functions for the Intune Backup & Restore Tool.

.DESCRIPTION
    Provides:
      - Get-DefaultAppConfig      : Default settings object
      - Invoke-GraphRequestRetry  : HTTP wrapper with exponential-backoff retry
      - Get-GraphAllPages         : Transparent paging via @odata.nextLink
      - Save-JsonFile             : Serialize object → UTF-8 JSON file
      - Read-JsonFile             : Parse UTF-8 JSON file → PSObject
      - ConvertTo-SafeFileName    : Make a display name safe for the file system
      - Get-SHA256                : SHA-256 hash of a file or string
      - Remove-GraphMetaProperties: Strip read-only / system fields before import
      - ConvertTo-Hashtable       : Deep PSObject → Hashtable (for API bodies)
      - Get-GraphRoot             : Resolve v1.0/beta base URL per workload
      - Get-EndpointVersion       : Return 'v1.0' or 'beta' for a workload key
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
#region Default Configuration
# ---------------------------------------------------------------------------

function Get-DefaultAppConfig {
    <#
    .SYNOPSIS
        Returns a PSCustomObject with factory-default application settings.
        Used when AppConfig.json is missing or cannot be parsed.
    #>
    [OutputType([PSCustomObject])]
    param()

    return [PSCustomObject]@{
        DefaultBackupPath    = ''
        LogDirectory         = ''
        LogLevel             = 'INFO'
        MaxRetries           = 3
        RetryDelaySeconds    = 2
        IncludeAssignments   = $true
        ComputeChecksums     = $true
        GraphApiVersion      = 'v1.0'
        PageSize             = 100
        ConfirmModuleInstall = $true
        ConfirmRestore       = $true
        ModuleInstallScope   = 'CurrentUser'
    }
}

#endregion

# ---------------------------------------------------------------------------
#region Graph API Helpers
# ---------------------------------------------------------------------------

function Invoke-GraphRequestRetry {
    <#
    .SYNOPSIS
        Wraps Invoke-MgGraphRequest with exponential-backoff retry.

    .DESCRIPTION
        Retries on:
          429 Too Many Requests – honours Retry-After header if present.
          503 / 504 / 500      – transient server errors.

        Non-retryable errors (4xx except 429) are rethrown immediately.

    .PARAMETER Method
        HTTP verb: GET | POST | PATCH | PUT | DELETE

    .PARAMETER Uri
        Full Graph URI including version segment, e.g.
        https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies

    .PARAMETER Body
        Optional request body. Hashtables and PSObjects are serialized to JSON.
        Plain strings are sent as-is.

    .PARAMETER MaxRetries
        How many times to retry after a retryable failure (default: 3).

    .PARAMETER RetryDelaySeconds
        Base delay in seconds before the first retry.
        Each subsequent retry doubles the delay (exponential backoff).

    .OUTPUTS
        PSObject returned by Invoke-MgGraphRequest.
    #>
    [CmdletBinding()]
    [OutputType([PSObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [object]$Body = $null,

        [int]$MaxRetries        = 3,
        [int]$RetryDelaySeconds = 2
    )

    $attempt   = 0
    $lastError = $null

    while ($attempt -le $MaxRetries) {
        try {
            $params = @{
                Method      = $Method
                Uri         = $Uri
                OutputType  = 'PSObject'
                ErrorAction = 'Stop'
            }

            if ($Body -and ($Method -in 'POST', 'PATCH', 'PUT')) {
                $json                = if ($Body -is [string]) { $Body }
                                       else { $Body | ConvertTo-Json -Depth 20 -Compress -EnumsAsStrings }
                $params['Body']        = $json
                $params['ContentType'] = 'application/json'
            }

            return Invoke-MgGraphRequest @params
        }
        catch {
            $lastError  = $_
            $statusCode = _Get-HttpStatusCode -ErrorRecord $_

            $shouldRetry  = $false
            $waitSeconds  = $RetryDelaySeconds * [Math]::Pow(2, $attempt)

            switch ($statusCode) {
                429 {
                    # Honour Retry-After header when available
                    $retryAfter = _Get-RetryAfterSeconds -ErrorRecord $_
                    $waitSeconds  = if ($retryAfter -gt 0) { $retryAfter } else { [Math]::Max($waitSeconds, 30) }
                    $shouldRetry  = $true
                    Write-LogMessage -Level WARN -Message "Graph throttled (429). Waiting $waitSeconds s (attempt $($attempt+1)/$MaxRetries). URI: $Uri"
                }
                { $_ -in 500, 503, 504 } {
                    $shouldRetry = $true
                    Write-LogMessage -Level WARN -Message "Graph server error ($statusCode). Waiting $waitSeconds s (attempt $($attempt+1)/$MaxRetries). URI: $Uri"
                }
                default {
                    # Not retryable
                    throw $lastError
                }
            }

            if ($shouldRetry -and $attempt -lt $MaxRetries) {
                Start-Sleep -Seconds $waitSeconds
                $attempt++
                continue
            }

            throw $lastError
        }
    }

    throw $lastError
}

function Get-GraphAllPages {
    <#
    .SYNOPSIS
        Fetches all items from a paged Graph collection.
        Follows @odata.nextLink transparently until exhausted.

    .PARAMETER Uri
        Initial collection URI.

    .OUTPUTS
        [object[]] Combined value array from all pages.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [int]$MaxRetries        = 3,
        [int]$RetryDelaySeconds = 2
    )

    $all        = [System.Collections.Generic.List[object]]::new()
    $currentUri = $Uri
    $page       = 0

    do {
        $page++
        Write-LogMessage -Level DEBUG -Message "Graph paging: page $page – $currentUri"

        $response = Invoke-GraphRequestRetry `
            -Method             GET `
            -Uri                $currentUri `
            -MaxRetries         $MaxRetries `
            -RetryDelaySeconds  $RetryDelaySeconds

        if ($null -ne $response.value) {
            $all.AddRange([object[]]$response.value)
        }
        elseif ($page -eq 1 -and $null -ne $response) {
            # Single-object endpoint (not a collection)
            $all.Add($response)
        }

        $currentUri = $response.'@odata.nextLink'
    }
    while (-not [string]::IsNullOrEmpty($currentUri))

    Write-LogMessage -Level DEBUG -Message "Graph paging complete: $($all.Count) item(s) across $page page(s)."
    return $all.ToArray()
}

#endregion

# ---------------------------------------------------------------------------
#region File Utilities
# ---------------------------------------------------------------------------

function Save-JsonFile {
    <#
    .SYNOPSIS
        Serializes $Object to indented UTF-8 JSON and saves it to $Path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Path,

        [int]$Depth = 20
    )

    $json = $Object | ConvertTo-Json -Depth $Depth -EnumsAsStrings
    Set-Content -Path $Path -Value $json -Encoding UTF8 -Force
}

function Read-JsonFile {
    <#
    .SYNOPSIS
        Reads and parses a UTF-8 JSON file.
        Returns $null if the file is missing or unparseable (logs a warning).
    #>
    [CmdletBinding()]
    [OutputType([PSObject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        Write-LogMessage -Level WARN -Message "JSON file not found: $Path"
        return $null
    }

    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        return ($raw | ConvertFrom-Json -Depth 20)
    }
    catch {
        Write-LogMessage -Level ERROR -Message "Failed to parse JSON file '$Path': $($_.Exception.Message)"
        return $null
    }
}

#endregion

# ---------------------------------------------------------------------------
#region String / Path Utilities
# ---------------------------------------------------------------------------

function ConvertTo-SafeFileName {
    <#
    .SYNOPSIS
        Replaces characters that are invalid in file-system paths with
        underscores and trims the result to $MaxLength.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [int]$MaxLength = 100
    )

    # Replace all NTFS-invalid characters
    $safe = $Name -replace '[\\/:*?"<>|]', '_'
    $safe = $safe -replace '\s+', '_'
    $safe = $safe.Trim('_. ')

    if ($safe.Length -gt $MaxLength) {
        $safe = $safe.Substring(0, $MaxLength).TrimEnd('_. ')
    }

    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = 'unnamed'
    }

    return $safe
}

#endregion

# ---------------------------------------------------------------------------
#region Checksum
# ---------------------------------------------------------------------------

function Get-SHA256 {
    <#
    .SYNOPSIS
        Returns the SHA-256 hex digest.
        Accepts either -FilePath (file on disk) or -InputString (in-memory).
    #>
    [CmdletBinding(DefaultParameterSetName = 'File')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'File')]
        [string]$FilePath,

        [Parameter(Mandatory, ParameterSetName = 'String')]
        [string]$InputString
    )

    try {
        if ($PSCmdlet.ParameterSetName -eq 'File') {
            return (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash
        }
        else {
            $sha   = [System.Security.Cryptography.SHA256]::Create()
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
            $hash  = $sha.ComputeHash($bytes)
            return ([System.BitConverter]::ToString($hash) -replace '-', '')
        }
    }
    catch {
        Write-LogMessage -Level WARN -Message "Checksum failed: $($_.Exception.Message)"
        return $null
    }
    finally {
        if ($sha) { $sha.Dispose() }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region Data Transformation
# ---------------------------------------------------------------------------

function Remove-GraphMetaProperties {
    <#
    .SYNOPSIS
        Removes standard read-only and system-managed Graph properties from
        a hashtable or PSObject so it can be used as a POST/PATCH body.

    .DESCRIPTION
        Always removed:
            id, createdDateTime, lastModifiedDateTime, modifiedDateTime,
            version, @odata.context, @odata.etag

        Additional properties to remove can be passed via -ExtraProperties.

        The @odata.type field is intentionally KEPT because it is required
        for correct polymorphic deserialization on POST (e.g. deviceConfigurations).

    .OUTPUTS
        [hashtable] Clean copy – the original object is not modified.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [string[]]$ExtraProperties = @()
    )

    # Normalise to hashtable via JSON round-trip for reliable deep copy
    $json = $InputObject | ConvertTo-Json -Depth 20 -EnumsAsStrings
    $ht   = $json | ConvertFrom-Json -AsHashtable -Depth 20

    $remove = @(
        'id'
        'createdDateTime'
        'lastModifiedDateTime'
        'modifiedDateTime'
        'version'
        '@odata.context'
        '@odata.etag'
    ) + $ExtraProperties

    foreach ($key in $remove) {
        $ht.Remove($key)
    }

    return $ht
}

function ConvertTo-Hashtable {
    <#
    .SYNOPSIS
        Deep-converts a PSObject (e.g. from ConvertFrom-Json) to a Hashtable.
        Necessary when building dynamic POST/PATCH bodies.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object]$InputObject
    )

    $json = $InputObject | ConvertTo-Json -Depth 20 -EnumsAsStrings
    return ($json | ConvertFrom-Json -AsHashtable -Depth 20)
}

#endregion

# ---------------------------------------------------------------------------
#region Endpoint resolution (v1.0 / beta)
# ---------------------------------------------------------------------------

# Default per-workload endpoint family. Workloads may override these via
# AppConfig.json -> EndpointVersions. Categories that only exist on the beta
# endpoint default to 'beta' here so that an empty config still works.
$script:DefaultEndpointVersions = @{
    CompliancePolicies       = 'v1.0'
    ConfigProfiles           = 'v1.0'
    SettingsCatalog          = 'v1.0'
    EndpointSecurity         = 'v1.0'
    DeviceScripts            = 'v1.0'
    Autopilot                = 'v1.0'
    EnrollmentConfigurations = 'v1.0'
    AppProtection            = 'v1.0'
    AppConfiguration         = 'v1.0'
    ProactiveRemediations    = 'beta'
    AdministrativeTemplates  = 'beta'
    Assignment               = 'v1.0'   # used by AssignmentEngine
}

# Workloads that have NO v1.0 surface; force beta regardless of config.
$script:BetaOnlyWorkloads = @(
    'ProactiveRemediations'
    'AdministrativeTemplates'
)

function Get-EndpointVersion {
    <#
    .SYNOPSIS
        Returns 'v1.0' or 'beta' for a workload key.

    .DESCRIPTION
        Resolution order:
          1. If $WorkloadKey is in $BetaOnlyWorkloads → always 'beta'.
          2. AppConfig.json -> EndpointVersions[$WorkloadKey] if set.
          3. AppConfig.json -> UseBetaWherePossible = $true → 'beta'.
          4. $DefaultEndpointVersions[$WorkloadKey].
          5. Fallback: 'v1.0'.

        Reads from $script:GraphEndpointConfig which is set by Set-GraphEndpointConfig
        (called from Main.ps1 after AppConfig.json is loaded).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$WorkloadKey
    )

    if ($script:BetaOnlyWorkloads -contains $WorkloadKey) {
        return 'beta'
    }

    $cfg = $script:GraphEndpointConfig
    if ($cfg) {
        if ($cfg.EndpointVersions -and $cfg.EndpointVersions[$WorkloadKey]) {
            $v = [string]$cfg.EndpointVersions[$WorkloadKey]
            if ($v -in 'v1.0','beta') { return $v }
        }
        if ($cfg.UseBetaWherePossible) {
            return 'beta'
        }
    }

    if ($script:DefaultEndpointVersions.ContainsKey($WorkloadKey)) {
        return $script:DefaultEndpointVersions[$WorkloadKey]
    }
    return 'v1.0'
}

function Get-GraphRoot {
    <#
    .SYNOPSIS
        Returns the Graph base URL for a workload, e.g.
        'https://graph.microsoft.com/v1.0' or '.../beta'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$WorkloadKey
    )
    $version = Get-EndpointVersion -WorkloadKey $WorkloadKey
    return "https://graph.microsoft.com/$version"
}

function Set-GraphEndpointConfig {
    <#
    .SYNOPSIS
        Stores endpoint preferences for Get-EndpointVersion / Get-GraphRoot
        to consult. Called from Main.ps1 once AppConfig.json is loaded and
        again whenever the Settings tab saves changes.

    .PARAMETER UseBetaWherePossible
        Global override – when $true, all non-locked workloads return 'beta'.

    .PARAMETER EndpointVersions
        Hashtable WorkloadKey -> 'v1.0'|'beta' (per-workload override).
    #>
    [CmdletBinding()]
    param(
        [bool]$UseBetaWherePossible = $false,
        [hashtable]$EndpointVersions = $null
    )
    $script:GraphEndpointConfig = @{
        UseBetaWherePossible = $UseBetaWherePossible
        EndpointVersions     = $EndpointVersions
    }
}

#endregion

# ---------------------------------------------------------------------------
#region Private helpers  (not exported)
# ---------------------------------------------------------------------------

function _Get-HttpStatusCode {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    # Try known exception types first
    $ex = $ErrorRecord.Exception
    if ($ex.Response -ne $null) {
        try { return [int]$ex.Response.StatusCode } catch { }
    }
    # Fallback: parse message text
    if ($ErrorRecord.Exception.Message -match '\b(\d{3})\b') {
        return [int]$Matches[1]
    }
    return 0
}

function _Get-RetryAfterSeconds {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    try {
        $headers = $ErrorRecord.Exception.Response.Headers
        $value   = $headers['Retry-After']
        if ($value) { return [int]$value }
    }
    catch { }
    return 0
}

#endregion

Export-ModuleMember -Function `
    Get-DefaultAppConfig, `
    Invoke-GraphRequestRetry, `
    Get-GraphAllPages, `
    Save-JsonFile, `
    Read-JsonFile, `
    ConvertTo-SafeFileName, `
    Get-SHA256, `
    Remove-GraphMetaProperties, `
    ConvertTo-Hashtable, `
    Get-EndpointVersion, `
    Get-GraphRoot, `
    Set-GraphEndpointConfig

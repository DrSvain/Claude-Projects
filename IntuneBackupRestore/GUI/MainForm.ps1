<#
.SYNOPSIS
    Main WinForms window for the Intune Backup & Restore Tool.

.DESCRIPTION
    Builds and displays the main application window.
    Responsibilities:
      - Create the Form with header, TabControl and StatusBar.
      - Dot-source all Tab_*.ps1 files and add their TabPages.
      - Run a 250 ms Timer to:
          * Drain the shared LogQueue → Log tab RichTextBox
          * Update progress bars and status labels
          * Detect completed background runspaces
      - Provide Start-BackgroundOperation / Stop-BackgroundOperation for
        Backup and Restore tabs to launch work without blocking the UI.
#>

Set-StrictMode -Version Latest

# Module-level references shared across tab files
$script:GlobalState  = $null
$script:AppVersion   = '1.0.0'
$script:AppName      = 'Intune Backup & Restore Tool'
$script:LogFilePath  = $null
$script:ScriptRoot   = $null

# UI control references used by the timer and background-op helpers
$script:UIRefs = @{
    Form                = $null
    TabControl          = $null
    StatusLabel         = $null
    StatusRightLabel    = $null
    LogRichTextBox      = $null
    BackupProgressBar   = $null
    BackupStatusLabel   = $null
    RestoreProgressBar  = $null
    RestoreStatusLabel  = $null
    BtnConnect          = $null
    BtnDisconnect       = $null
    BtnStartBackup      = $null
    BtnStartRestore     = $null
}

# Active background runspace
$script:ActiveRunspace  = $null   # hashtable: PS, Runspace, AsyncResult, OperationType

# ---------------------------------------------------------------------------
#region Entry point
# ---------------------------------------------------------------------------

function Start-MainWindow {
    <#
    .SYNOPSIS
        Builds the main form and starts the WinForms message loop.
        Called from Main.ps1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]                    $XamlPath,     # kept for API compat, not used (WinForms)
        [Parameter(Mandatory)][System.Collections.Hashtable]$GlobalState,
        [Parameter(Mandatory)][string]                    $AppVersion,
        [Parameter(Mandatory)][string]                    $AppName,
        [Parameter(Mandatory)][object]                    $AppConfig,
        [Parameter(Mandatory)][string]                    $LogFilePath
    )

    $script:GlobalState = $GlobalState
    $script:AppVersion  = $AppVersion
    $script:AppName     = $AppName
    $script:LogFilePath = $LogFilePath
    $script:ScriptRoot  = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    # Dot-source tab files (they live alongside this file)
    $guiDir = $PSScriptRoot
    foreach ($tabFile in @('Tab_Connection','Tab_Prerequisites','Tab_Backup','Tab_Restore','Tab_Log','Tab_Settings')) {
        $tabPath = Join-Path $guiDir "$tabFile.ps1"
        if (Test-Path $tabPath) {
            . $tabPath
        } else {
            Write-Warning "Tab file not found: $tabPath"
        }
    }

    # Register the GUI log control (will be set after Log tab is created)
    Register-LogQueue -Queue $GlobalState.LogQueue

    # ── Build Main Form ───────────────────────────────────────────────────
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "$AppName  v$AppVersion"
    $form.Size            = [System.Drawing.Size]::new(1050, 720)
    $form.MinimumSize     = [System.Drawing.Size]::new(800, 580)
    $form.StartPosition   = 'CenterScreen'
    $form.Font            = [System.Drawing.Font]::new('Segoe UI', 9)
    $form.BackColor       = [System.Drawing.Color]::FromArgb(245, 245, 245)

    $script:UIRefs.Form = $form

    # ── Header Panel ─────────────────────────────────────────────────────
    $header = New-Object System.Windows.Forms.Panel
    $header.Dock      = 'Top'
    $header.Height    = 56
    $header.BackColor = [System.Drawing.Color]::FromArgb(31, 78, 121)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text      = $AppName
    $lblTitle.Font      = [System.Drawing.Font]::new('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::White
    $lblTitle.AutoSize  = $true
    $lblTitle.Location  = [System.Drawing.Point]::new(14, 16)

    $lblVer = New-Object System.Windows.Forms.Label
    $lblVer.Text      = "v$AppVersion"
    $lblVer.Font      = [System.Drawing.Font]::new('Segoe UI', 8)
    $lblVer.ForeColor = [System.Drawing.Color]::FromArgb(180, 210, 240)
    $lblVer.AutoSize  = $true
    $lblVer.Location  = [System.Drawing.Point]::new(14, 38)

    # Tenant info strip (right side of header)
    $lblTenantStrip = New-Object System.Windows.Forms.Label
    $lblTenantStrip.Name      = 'lblTenantStrip'
    $lblTenantStrip.Text      = 'Not connected'
    $lblTenantStrip.Font      = [System.Drawing.Font]::new('Segoe UI', 8)
    $lblTenantStrip.ForeColor = [System.Drawing.Color]::FromArgb(180, 210, 240)
    $lblTenantStrip.AutoSize  = $true
    $lblTenantStrip.Anchor    = 'Top,Right'
    $lblTenantStrip.Location  = [System.Drawing.Point]::new($form.Width - 400, 20)

    $header.Controls.AddRange(@($lblTitle, $lblVer, $lblTenantStrip))
    $form.Controls.Add($header)

    # ── Status Bar ────────────────────────────────────────────────────────
    $statusBar = New-Object System.Windows.Forms.StatusStrip
    $statusBar.BackColor = [System.Drawing.Color]::FromArgb(224, 224, 224)

    $statusLeft = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLeft.Text   = 'Ready'
    $statusLeft.Spring = $true
    $statusLeft.TextAlign = 'MiddleLeft'

    $statusRight = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusRight.Text      = ''
    $statusRight.Alignment = 'Right'

    $statusBar.Items.AddRange(@($statusLeft, $statusRight))
    $form.Controls.Add($statusBar)

    $script:UIRefs.StatusLabel      = $statusLeft
    $script:UIRefs.StatusRightLabel = $statusRight

    # ── TabControl ────────────────────────────────────────────────────────
    $tabCtrl = New-Object System.Windows.Forms.TabControl
    $tabCtrl.Dock     = 'Fill'
    $tabCtrl.Font     = [System.Drawing.Font]::new('Segoe UI', 9)
    $tabCtrl.Padding  = [System.Drawing.Point]::new(10, 4)

    $script:UIRefs.TabControl = $tabCtrl

    # Build each tab (functions defined in Tab_*.ps1 files)
    $tabCtrl.TabPages.Add((Initialize-TabConnection   -UIRefs $script:UIRefs -GlobalState $GlobalState))
    $tabCtrl.TabPages.Add((Initialize-TabPrerequisites -UIRefs $script:UIRefs -GlobalState $GlobalState))
    $tabCtrl.TabPages.Add((Initialize-TabBackup        -UIRefs $script:UIRefs -GlobalState $GlobalState))
    $tabCtrl.TabPages.Add((Initialize-TabRestore       -UIRefs $script:UIRefs -GlobalState $GlobalState))
    $tabCtrl.TabPages.Add((Initialize-TabLog           -UIRefs $script:UIRefs -GlobalState $GlobalState))
    $tabCtrl.TabPages.Add((Initialize-TabSettings      -UIRefs $script:UIRefs -GlobalState $GlobalState -AppConfig $AppConfig -LogFilePath $LogFilePath))

    $form.Controls.Add($tabCtrl)

    # ── 250 ms UI refresh Timer ───────────────────────────────────────────
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({ Update-UIFromTimer })
    $timer.Start()

    # ── Form events ───────────────────────────────────────────────────────
    $form.Add_FormClosing({
        param($sender, $e)
        $timer.Stop()
        $timer.Dispose()
        _Stop-ActiveRunspace
        Write-LogMessage -Level INFO -Message 'Application closed.'
    })

    $form.Add_Shown({
        Update-StatusBar -Text 'Ready. Use the Connection tab to sign in.'
        # Seed environment info in Prerequisites tab
        if (Get-Command -Name 'Refresh-EnvInfo' -ErrorAction SilentlyContinue) {
            Refresh-EnvInfo
        }
    })

    # ── Show ──────────────────────────────────────────────────────────────
    [System.Windows.Forms.Application]::Run($form)
}

#endregion

# ---------------------------------------------------------------------------
#region Timer callback
# ---------------------------------------------------------------------------

function Update-UIFromTimer {
    <#
    .SYNOPSIS
        Runs every 250 ms on the UI thread.
        Drains the log queue, updates progress, checks runspace completion.
    #>

    # 1. Drain log queue → Log tab RichTextBox
    if ($script:UIRefs.LogRichTextBox -and $script:GlobalState) {
        $item = $null
        $rtb  = $script:UIRefs.LogRichTextBox
        while ($script:GlobalState.LogQueue.TryDequeue([ref]$item)) {
            try {
                $color = switch ($item.Level) {
                    'DEBUG'   { [System.Drawing.Color]::Gray }
                    'INFO'    { [System.Drawing.Color]::Black }
                    'SUCCESS' { [System.Drawing.Color]::FromArgb(0, 128, 0) }
                    'WARN'    { [System.Drawing.Color]::FromArgb(180, 100, 0) }
                    'ERROR'   { [System.Drawing.Color]::Red }
                    'FATAL'   { [System.Drawing.Color]::DarkMagenta }
                    default   { [System.Drawing.Color]::Black }
                }
                $rtb.SelectionStart  = $rtb.TextLength
                $rtb.SelectionLength = 0
                $rtb.SelectionColor  = $color
                $rtb.AppendText("$($item.Formatted)`r`n")
                $rtb.SelectionColor  = $rtb.ForeColor
                $rtb.ScrollToCaret()
            }
            catch { }
        }
    }

    # 2. Backup progress
    if ($script:GlobalState.IsBackupRunning) {
        if ($script:UIRefs.BackupProgressBar) {
            $val = [Math]::Min(100, [Math]::Max(0, $script:GlobalState.BackupProgress))
            $script:UIRefs.BackupProgressBar.Value = $val
        }
        if ($script:UIRefs.BackupStatusLabel) {
            $script:UIRefs.BackupStatusLabel.Text = $script:GlobalState.BackupProgressText
        }
        Update-StatusBar -Text $script:GlobalState.BackupProgressText
    }

    # 3. Restore progress
    if ($script:GlobalState.IsRestoreRunning) {
        if ($script:UIRefs.RestoreProgressBar) {
            $val = [Math]::Min(100, [Math]::Max(0, $script:GlobalState.RestoreProgress))
            $script:UIRefs.RestoreProgressBar.Value = $val
        }
        if ($script:UIRefs.RestoreStatusLabel) {
            $script:UIRefs.RestoreStatusLabel.Text = $script:GlobalState.RestoreProgressText
        }
        Update-StatusBar -Text $script:GlobalState.RestoreProgressText
    }

    # 4. Check runspace completion
    if ($script:ActiveRunspace -and $script:ActiveRunspace.AsyncResult.IsCompleted) {
        _Complete-RunspaceOperation
    }

    # 5. Tenant strip in header
    try {
        $strip = $script:UIRefs.Form.Controls['lblTenantStrip'] |
                 ForEach-Object { $_ } |
                 Where-Object { $_ -is [System.Windows.Forms.Label] }
        if (-not $strip) {
            $strip = $script:UIRefs.Form.Controls |
                     Where-Object { $_ -is [System.Windows.Forms.Panel] } |
                     ForEach-Object { $_.Controls } |
                     Where-Object { $_ -is [System.Windows.Forms.Label] -and $_.Name -eq 'lblTenantStrip' }
        }
        if ($strip -and $script:GlobalState.IsConnected) {
            $strip.Text = "Tenant: $($script:GlobalState.TenantDisplayName)  |  $($script:GlobalState.ConnectedUser)"
        }
        elseif ($strip) {
            $strip.Text = 'Not connected'
        }
    }
    catch { }
}

#endregion

# ---------------------------------------------------------------------------
#region Background runspace helpers
# ---------------------------------------------------------------------------

function Start-BackgroundOperation {
    <#
    .SYNOPSIS
        Launches a scriptblock in a background runspace.
        The runspace imports all tool modules and Microsoft.Graph.Authentication
        so it can reuse the Graph auth context from the main thread.

    .PARAMETER ScriptBlock
        The code to execute. Receives $GlobalState as $args[0].

    .PARAMETER OperationType
        'Backup' or 'Restore' – used to toggle button states.

    .PARAMETER AdditionalArgs
        Extra arguments appended after $GlobalState.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]  $OperationType  = 'Generic',
        [object[]]$AdditionalArgs = @()
    )

    if ($script:ActiveRunspace) {
        [System.Windows.Forms.MessageBox]::Show(
            'Another operation is already running. Please wait for it to complete.',
            $script:AppName, 'OK', 'Warning') | Out-Null
        return
    }

    $modulesRoot = Join-Path $script:ScriptRoot 'Modules'

    # Build the runspace script that imports modules then calls the payload
    $bootstrapScript = {
        param($GlobalState, $ModulesRoot, $Payload, $ExtraArgs)

        # Import tool modules (order matters)
        $mods = @(
            'Logging', 'Helpers', 'Prerequisites', 'GraphConnection',
            'BackupEngine', 'RestoreEngine'
        )
        foreach ($m in $mods) {
            $path = Join-Path $ModulesRoot "$m.psm1"
            if (Test-Path $path) { Import-Module $path -Force -Global }
        }

        $wlDir = Join-Path $ModulesRoot 'Workloads'
        foreach ($wl in Get-ChildItem -Path $wlDir -Filter '*.psm1' -ErrorAction SilentlyContinue) {
            Import-Module $wl.FullName -Force -Global
        }

        # Reuse Graph auth context (static .NET object shared across runspaces)
        if (Get-Module -Name 'Microsoft.Graph.Authentication' -ListAvailable) {
            Import-Module 'Microsoft.Graph.Authentication' -Force
        }

        # Point logging at the shared queue
        Initialize-LoggingForRunspace `
            -LogQueue  $GlobalState.LogQueue `
            -LogFile   $GlobalState.LogFilePath `
            -LogLevel  $GlobalState.LogLevel

        # Execute caller's payload
        & $Payload $GlobalState $ExtraArgs
    }

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript($bootstrapScript) | Out-Null
    $ps.AddArgument($script:GlobalState) | Out-Null
    $ps.AddArgument($modulesRoot)        | Out-Null
    $ps.AddArgument($ScriptBlock)        | Out-Null
    $ps.AddArgument($AdditionalArgs)     | Out-Null

    $asyncResult = $ps.BeginInvoke()

    $script:ActiveRunspace = @{
        PS            = $ps
        Runspace      = $rs
        AsyncResult   = $asyncResult
        OperationType = $OperationType
    }

    # Disable action buttons while running
    _Set-OperationButtons -Enabled $false
    Write-LogMessage -Level INFO -Message "Background operation started: $OperationType"
}

function _Complete-RunspaceOperation {
    if (-not $script:ActiveRunspace) { return }

    $ps   = $script:ActiveRunspace.PS
    $rs   = $script:ActiveRunspace.Runspace
    $type = $script:ActiveRunspace.OperationType

    try {
        # Collect any terminating errors from the runspace
        $ps.EndInvoke($script:ActiveRunspace.AsyncResult) | Out-Null

        if ($ps.HadErrors) {
            foreach ($err in $ps.Streams.Error) {
                Write-LogMessage -Level ERROR -Message "Runspace error: $($err.Exception.Message)"
            }
        }
    }
    catch {
        Write-LogMessage -Level ERROR -Message "Background operation '$type' threw: $($_.Exception.Message)"
    }
    finally {
        try { $ps.Dispose()  } catch { }
        try { $rs.Dispose()  } catch { }
        $script:ActiveRunspace = $null
        _Set-OperationButtons -Enabled $true

        # Final status
        if ($type -eq 'Backup') {
            Update-StatusBar -Text $script:GlobalState.BackupProgressText
            if ($script:UIRefs.BtnStartBackup) { $script:UIRefs.BtnStartBackup.Text = 'Start Backup' }
        }
        elseif ($type -eq 'Restore') {
            Update-StatusBar -Text $script:GlobalState.RestoreProgressText
            if ($script:UIRefs.BtnStartRestore) { $script:UIRefs.BtnStartRestore.Text = 'Start Restore' }
        }

        Write-LogMessage -Level INFO -Message "Background operation completed: $type"
    }
}

function _Stop-ActiveRunspace {
    if (-not $script:ActiveRunspace) { return }
    try {
        $script:ActiveRunspace.PS.Stop()
        $script:ActiveRunspace.PS.Dispose()
        $script:ActiveRunspace.Runspace.Dispose()
    }
    catch { }
    $script:ActiveRunspace = $null
}

function _Set-OperationButtons {
    param([bool]$Enabled)
    foreach ($key in @('BtnStartBackup','BtnStartRestore','BtnConnect','BtnDisconnect')) {
        if ($script:UIRefs[$key]) {
            try { $script:UIRefs[$key].Enabled = $Enabled } catch { }
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region Shared UI helpers (called from tab files)
# ---------------------------------------------------------------------------

function Update-StatusBar {
    param([string]$Text, [string]$RightText = '')
    if ($script:UIRefs.StatusLabel)      { $script:UIRefs.StatusLabel.Text      = $Text      }
    if ($script:UIRefs.StatusRightLabel -and $RightText) {
        $script:UIRefs.StatusRightLabel.Text = $RightText
    }
}

function Update-TenantDisplay {
    <#
    .SYNOPSIS
        Refreshes all tenant-related labels from GlobalState.
        Called by Tab_Connection after a successful Connect or Disconnect.
    #>
    if (-not $script:GlobalState) { return }

    $connected = $script:GlobalState.IsConnected

    # Connection tab detail labels (registered by Tab_Connection)
    foreach ($key in @('LblTenantName','LblTenantId','LblConnectedUser','LblConnectionTime')) {
        if ($script:UIRefs[$key]) {
            $script:UIRefs[$key].Text = switch ($key) {
                'LblTenantName'     { if ($connected) { $script:GlobalState.TenantDisplayName } else { '-' } }
                'LblTenantId'       { if ($connected) { $script:GlobalState.TenantId          } else { '-' } }
                'LblConnectedUser'  { if ($connected) { $script:GlobalState.ConnectedUser      } else { '-' } }
                'LblConnectionTime' { if ($connected -and $script:GlobalState.ConnectionTime) {
                                          $script:GlobalState.ConnectionTime.ToString('yyyy-MM-dd HH:mm:ss')
                                      } else { '-' } }
            }
        }
    }

    # Enable/disable buttons
    if ($script:UIRefs.BtnConnect)    { $script:UIRefs.BtnConnect.Enabled    = (-not $connected) }
    if ($script:UIRefs.BtnDisconnect) { $script:UIRefs.BtnDisconnect.Enabled = $connected }
    if ($script:UIRefs.BtnStartBackup){ $script:UIRefs.BtnStartBackup.Enabled = $connected }

    # Restore target tenant label
    if ($script:UIRefs.LblRestoreTargetTenant) {
        $script:UIRefs.LblRestoreTargetTenant.Text = if ($connected) {
            "$($script:GlobalState.TenantDisplayName) ($($script:GlobalState.TenantId))"
        } else { 'Not connected' }
    }

    $status = if ($connected) { "Connected to $($script:GlobalState.TenantDisplayName)" } else { 'Not connected' }
    Update-StatusBar -Text $status
}

function Initialize-LoggingForRunspace {
    <#
    .SYNOPSIS
        Thin wrapper – called from inside the background runspace bootstrap.
        Delegates to the Logging module's Initialize-LoggingForRunspace.
    #>
    param(
        [System.Collections.Concurrent.ConcurrentQueue[hashtable]]$LogQueue,
        [string]$LogFile  = $null,
        [string]$LogLevel = 'INFO'
    )
    # The Logging module is already imported inside the runspace.
    # This call reaches the module-level function of the same name.
    if (Get-Command -Name 'Initialize-LoggingForRunspace' -Module 'Logging' -ErrorAction SilentlyContinue) {
        & (Get-Module Logging) { Initialize-LoggingForRunspace @args } $LogQueue $LogFile $LogLevel
    }
}

#endregion

Export-ModuleMember -Function `
    Start-MainWindow, `
    Start-BackgroundOperation, `
    Update-StatusBar, `
    Update-TenantDisplay

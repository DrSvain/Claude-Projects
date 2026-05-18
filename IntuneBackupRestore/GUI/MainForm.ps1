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
# IMPORTANT: This file is dot-sourced into Main.ps1, so `$script:` refers to
# Main.ps1's scope. Do NOT initialize $script:GlobalState here — it would wipe
# the $GlobalState that Main.ps1 created. It is set inside Start-MainForm.
$script:AppVersion   = '1.1.0'
$script:AppName      = 'Intune Backup & Restore Tool'
$script:LogFilePath  = $null
$script:ScriptRoot   = $null

# Tracks the last observed value of $GlobalState.IsConnected so the 250 ms
# timer can fire Update-TenantDisplay only on transitions. Must be initialized
# here (not inside the timer body) because Set-StrictMode is in effect and
# would throw on a first-time read of an uninitialized $script: variable.
$script:LastIsConnected = $false

# Custom tab navigation registries (filled inside Start-MainForm). Must be
# initialised here so Show-Tab can read them safely under Set-StrictMode.
$script:NavButtons = @{}
$script:TabPages   = @{}

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

function Start-MainForm {
    <#
    .SYNOPSIS
        Builds the main form and starts the WinForms message loop.
        Called from Main.ps1 as: Start-MainForm -GlobalState $GlobalState
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Hashtable]$GlobalState
    )

    # Extract display values from GlobalState (support both old and new key names)
    $AppVersion  = if ($GlobalState.ContainsKey('AppVersion') -and $GlobalState.AppVersion) { $GlobalState.AppVersion }
                   elseif ($GlobalState.Config -and $GlobalState.Config['AppVersion'])       { $GlobalState.Config['AppVersion'] }
                   else { '1.0.0' }
    $AppName     = if ($GlobalState.ContainsKey('AppName') -and $GlobalState.AppName)       { $GlobalState.AppName }
                   elseif ($GlobalState.Config -and $GlobalState.Config['AppName'])          { $GlobalState.Config['AppName'] }
                   else { 'Intune Backup & Restore Tool' }
    $AppConfig   = $GlobalState.Config
    $LogFilePath = if ($GlobalState.ContainsKey('SessionLogFile') -and $GlobalState.SessionLogFile) { $GlobalState.SessionLogFile }
                   elseif ($GlobalState.ContainsKey('LogFilePath') -and $GlobalState.LogFilePath)   { $GlobalState.LogFilePath }
                   else { '' }

    $script:GlobalState = $GlobalState
    $script:AppVersion  = $AppVersion
    $script:AppName     = $AppName
    $script:LogFilePath = $LogFilePath
    $script:ScriptRoot  = $GlobalState.AppRoot

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    # Tab_*.ps1 files are already dot-sourced by Main.ps1 before this function is called.
    # Re-registering the queue here ensures runspace-safe access from the GUI thread.
    Register-LogQueue -Queue $GlobalState.LogQueue

    # ── Build Main Form ───────────────────────────────────────────────────
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "$AppName  v$AppVersion"
    $form.Size            = [System.Drawing.Size]::new(1050, 720)
    $form.MinimumSize     = [System.Drawing.Size]::new(800, 580)
    $form.StartPosition   = 'CenterScreen'
    $form.Font            = [System.Drawing.Font]::new('Segoe UI', 9)
    $form.BackColor       = [System.Drawing.Color]::FromArgb(245, 245, 245)

    $script:UIRefs.Form     = $form
    $script:UIRefs.MainForm = $form   # alias used by Tab_Restore

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

    # ── Navigation strip + content host ─────────────────────────────────
    # We do NOT use System.Windows.Forms.TabControl: on some Windows 10/11
    # theme + DPI combinations its tab strip renders almost transparently
    # and the user has no way to switch tabs. We replace it with an
    # explicit horizontal nav strip of toggle buttons + a Fill content
    # panel that shows one tab at a time. This gives us full control over
    # appearance.

    # Container that wraps the nav strip and the content area so they
    # together fill the area between header and statusBar.
    $tabHost = New-Object System.Windows.Forms.Panel
    $tabHost.Dock      = 'Fill'
    $tabHost.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)

    $navStrip = New-Object System.Windows.Forms.Panel
    $navStrip.Dock      = 'Top'
    $navStrip.Height    = 42
    $navStrip.BackColor = [System.Drawing.Color]::FromArgb(225, 232, 240)

    $contentPanel = New-Object System.Windows.Forms.Panel
    $contentPanel.Dock      = 'Fill'
    $contentPanel.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)

    # contentPanel must be added BEFORE navStrip in WinForms so Fill claims
    # the remaining space AFTER navStrip docks Top. WinForms processes
    # docked siblings in REVERSE z-order: last added = processed first.
    $tabHost.Controls.Add($contentPanel)
    $tabHost.Controls.Add($navStrip)

    $script:UIRefs.TabHost     = $tabHost
    $script:UIRefs.NavStrip    = $navStrip
    $script:UIRefs.ContentPanel = $contentPanel

    # Build each tab. Wrap every Initialize-Tab* call so that a failure in
    # one tab still lets the other tabs load — otherwise the user only
    # sees a half-rendered form with no tab strip and no way to debug.
    $tabsToBuild = @(
        @{ Name = 'Connection';    Init = { Initialize-TabConnection    -UIRefs $script:UIRefs -GlobalState $GlobalState } }
        @{ Name = 'Prerequisites'; Init = { Initialize-TabPrerequisites -UIRefs $script:UIRefs -GlobalState $GlobalState } }
        @{ Name = 'Backup';        Init = { Initialize-TabBackup        -UIRefs $script:UIRefs -GlobalState $GlobalState } }
        @{ Name = 'Restore';       Init = { Initialize-TabRestore       -UIRefs $script:UIRefs -GlobalState $GlobalState } }
        @{ Name = 'Log';           Init = { Initialize-TabLog           -UIRefs $script:UIRefs -GlobalState $GlobalState } }
        @{ Name = 'Settings';      Init = { Initialize-TabSettings      -UIRefs $script:UIRefs -GlobalState $GlobalState -AppConfig $AppConfig -LogFilePath $LogFilePath } }
    )

    $script:NavButtons = @{}
    $script:TabPages   = @{}

    $btnLeft = 6
    foreach ($t in $tabsToBuild) {
        $page = $null
        try {
            $page = & $t.Init
            if (-not ($page -is [System.Windows.Forms.TabPage])) {
                throw "Initialize-Tab$($t.Name) did not return a TabPage."
            }
            Write-Host "[Startup] Tab loaded: $($t.Name)" -ForegroundColor Green
        }
        catch {
            $errMsg = "Tab '$($t.Name)' failed to initialize: $($_.Exception.Message)"
            Write-Host "ERROR: $errMsg" -ForegroundColor Red
            Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
            try { Write-LogMessage -Level ERROR -Message $errMsg -ErrorRecord $_ } catch { }

            $page = New-Object System.Windows.Forms.TabPage
            $lbl  = New-Object System.Windows.Forms.Label
            $lbl.Text      = "Tab '$($t.Name)' failed to initialize.`r`n`r`n$($_.Exception.Message)`r`n`r`n$($_.ScriptStackTrace)"
            $lbl.Dock      = 'Fill'
            $lbl.Font      = [System.Drawing.Font]::new('Consolas', 9)
            $lbl.ForeColor = [System.Drawing.Color]::DarkRed
            $lbl.AutoSize  = $false
            $lbl.Padding   = [System.Windows.Forms.Padding]::new(12)
            $page.Controls.Add($lbl)
        }

        # Treat the TabPage as a regular Panel: dock-fill it inside the
        # content area, show only the currently-selected one.
        $page.Dock    = 'Fill'
        $page.Visible = $false
        $contentPanel.Controls.Add($page)
        $script:TabPages[$t.Name] = $page

        # Build the nav button for this tab
        $btn           = New-Object System.Windows.Forms.Button
        $btn.Text      = $t.Name
        $btn.Tag       = $t.Name
        $btn.Location  = [System.Drawing.Point]::new($btnLeft, 5)
        $btn.Size      = [System.Drawing.Size]::new(150, 32)
        $btn.Font      = [System.Drawing.Font]::new('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
        $btn.FlatStyle = 'Flat'
        $btn.BackColor = [System.Drawing.Color]::FromArgb(225, 232, 240)
        $btn.ForeColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
        $btn.FlatAppearance.BorderSize         = 0
        $btn.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(200, 215, 230)
        $btn.Cursor    = [System.Windows.Forms.Cursors]::Hand
        $btn.Add_Click({
            param($sender, $e)
            Show-Tab -Name $sender.Tag
        })
        $navStrip.Controls.Add($btn)
        $script:NavButtons[$t.Name] = $btn

        $btnLeft += 156
    }

    $tabHost.Controls.SetChildIndex($navStrip, 0)   # Ensure navStrip stays on top

    $form.Controls.Add($tabHost)

    # Show the first tab by default
    Show-Tab -Name 'Connection'

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

    # 6. Detect IsConnected transitions and refresh tenant labels + scope grid
    $currentConnected = [bool]$script:GlobalState.IsConnected
    if ($currentConnected -ne $script:LastIsConnected) {
        $script:LastIsConnected = $currentConnected
        try { Update-TenantDisplay } catch { }
    }
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
        # OLD architecture params
        [string]  $OperationType  = '',
        [object[]]$AdditionalArgs = @(),
        # NEW architecture aliases (Tab_Restore uses these)
        [string]  $OperationKey   = '',
        [object[]]$ArgumentList   = @(),
        [hashtable]$GlobalState   = $null,   # accepted but ignored; we use $script:GlobalState
        [hashtable]$UIRefs        = $null    # accepted but ignored; we use $script:UIRefs
    )
    # Reconcile old/new param names
    if (-not $OperationType -and $OperationKey)          { $OperationType  = $OperationKey }
    if (-not $OperationType)                              { $OperationType  = 'Generic' }
    if ($AdditionalArgs.Count -eq 0 -and $ArgumentList.Count -gt 0) { $AdditionalArgs = $ArgumentList }

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

        # Import tool modules (order matters — Helpers before AssignmentEngine
        # before workloads before BackupEngine/RestoreEngine).
        $mods = @(
            'Logging', 'Helpers', 'Prerequisites', 'GraphConnection',
            'AssignmentEngine', 'BackupEngine', 'RestoreEngine'
        )
        foreach ($m in $mods) {
            $path = Join-Path $ModulesRoot "$m.psm1"
            if (Test-Path $path) { Import-Module $path -Force -Global }
        }

        $wlDir = Join-Path $ModulesRoot 'Workloads'
        foreach ($wl in Get-ChildItem -Path $wlDir -Filter '*.psm1' -ErrorAction SilentlyContinue) {
            Import-Module $wl.FullName -Force -Global
        }

        # Replay endpoint version config so Get-GraphRoot inside the runspace
        # honours UseBetaWherePossible and per-category overrides.
        try {
            $cfg = $GlobalState.Config
            if ($cfg) {
                $useBeta = [bool]($cfg['UseBetaWherePossible'] -eq $true)
                $epOver  = $null
                if ($cfg.ContainsKey('EndpointVersions') -and $cfg['EndpointVersions']) {
                    $epOver = [hashtable]$cfg['EndpointVersions']
                }
                Set-GraphEndpointConfig -UseBetaWherePossible $useBeta -EndpointVersions $epOver
            }
        } catch { }

        # Reuse Graph auth context (static .NET object shared across runspaces)
        if (Get-Module -Name 'Microsoft.Graph.Authentication' -ListAvailable) {
            Import-Module 'Microsoft.Graph.Authentication' -Force
        }

        # Point logging at the shared queue (compatible with both old/new GlobalState key names)
        $logFile  = if ($GlobalState.ContainsKey('SessionLogFile') -and $GlobalState.SessionLogFile) { $GlobalState.SessionLogFile }
                    elseif ($GlobalState.ContainsKey('LogFilePath') -and $GlobalState.LogFilePath)   { $GlobalState.LogFilePath }
                    else { $null }
        $logLevel = if ($GlobalState.ContainsKey('LogLevel') -and $GlobalState.LogLevel)             { $GlobalState.LogLevel }
                    elseif ($GlobalState.Config -and $GlobalState.Config['LogLevel'])                 { $GlobalState.Config['LogLevel'] }
                    else { 'INFO' }
        if ($logFile) { Initialize-Logging -LogFile $logFile -LogLevel $logLevel }
        Register-LogQueue -Queue $GlobalState.LogQueue

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

function Show-Tab {
    <#
    .SYNOPSIS
        Hides all tab pages, shows the named one, and highlights the
        matching nav button.
    #>
    param([Parameter(Mandatory)][string]$Name)

    if (-not $script:TabPages -or -not $script:TabPages.ContainsKey($Name)) {
        return
    }

    foreach ($key in $script:TabPages.Keys) {
        $script:TabPages[$key].Visible = ($key -eq $Name)
    }

    if ($script:NavButtons) {
        foreach ($key in $script:NavButtons.Keys) {
            $btn = $script:NavButtons[$key]
            if ($key -eq $Name) {
                $btn.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
                $btn.ForeColor = [System.Drawing.Color]::White
            } else {
                $btn.BackColor = [System.Drawing.Color]::FromArgb(225, 232, 240)
                $btn.ForeColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
            }
        }
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
    if ($script:UIRefs.BtnRequestScopes) { $script:UIRefs.BtnRequestScopes.Enabled = $connected }
    if ($script:UIRefs.BtnSwitchTenant)  { $script:UIRefs.BtnSwitchTenant.Enabled  = $connected }

    # Refresh scope-status grid (Tab_Connection registers this callback).
    # The scriptblock takes $UIRefs as an argument; we pass it explicitly so
    # the callback does not depend on dynamic-scope lookup of locals from the
    # tab init function (which would fail under StrictMode).
    if ($script:UIRefs.RefreshScopeStatus) {
        try { & $script:UIRefs.RefreshScopeStatus $script:UIRefs } catch { }
    }

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

# This file is dot-sourced (not a module) — Export-ModuleMember must NOT be called here.

#Requires -Version 7.0
<#
.SYNOPSIS
    Settings tab — backup path, log level, retry/throttle options, save and reset.
#>

function Initialize-TabSettings {
    param(
        [hashtable]$UIRefs,
        [hashtable]$GlobalState,
        [hashtable]$AppConfig   = $null,   # passed by MainForm but GlobalState.Config is used internally
        [string]$LogFilePath    = ''       # passed by MainForm but ignored (Config path is shown instead)
    )

    $Tab = New-Object System.Windows.Forms.TabPage
    $Tab.Text    = 'Settings'
    $Tab.Padding = [System.Windows.Forms.Padding]::new(12)

    $scroll = [System.Windows.Forms.Panel]::new()
    $scroll.Dock          = 'Fill'
    $scroll.AutoScroll    = $true
    $Tab.Controls.Add($scroll)

    $yPos = 8

    # ── Backup ───────────────────────────────────────────────────────────────
    $grpBackup = New-SettingsGroup -Parent $scroll -Text 'Backup' -Y $yPos -Height 120
    $yPos += 128

    Add-FieldLabel -Parent $grpBackup -Text 'Backup Root Path:' -Y 22
    $txtBackupPath = [System.Windows.Forms.TextBox]::new()
    $txtBackupPath.Location = [System.Drawing.Point]::new(160, 20)
    $txtBackupPath.Width    = 420
    $grpBackup.Controls.Add($txtBackupPath)

    $btnPickPath = New-SettingsButton -Text 'Browse...' -X 586 -Y 19 -Width 80
    $grpBackup.Controls.Add($btnPickPath)

    $chkChecksum = New-SettingsCheck -Text 'Write SHA-256 checksums alongside backup files' -X 160 -Y 52
    $grpBackup.Controls.Add($chkChecksum)

    $chkConfirmRestore = New-SettingsCheck -Text 'Show confirmation dialog before each restore operation' -X 160 -Y 76
    $grpBackup.Controls.Add($chkConfirmRestore)

    $chkExportAssignments = New-SettingsCheck -Text 'Export assignments (and create .assignments.json sidecars)' -X 160 -Y 100
    $grpBackup.Controls.Add($chkExportAssignments)

    # ── Restore options ──────────────────────────────────────────────────────
    $grpRestore = New-SettingsGroup -Parent $scroll -Text 'Restore Defaults' -Y $yPos -Height 110
    $yPos += 118

    Add-FieldLabel -Parent $grpRestore -Text 'Conflict mode:' -Y 24
    $cmbConflictMode = [System.Windows.Forms.ComboBox]::new()
    $cmbConflictMode.Location      = [System.Drawing.Point]::new(160, 21)
    $cmbConflictMode.Width         = 180
    $cmbConflictMode.DropDownStyle = 'DropDownList'
    $cmbConflictMode.Items.AddRange([string[]]@('Skip', 'CreateDuplicate', 'UpdateExisting'))
    $cmbConflictMode.SelectedIndex = 0
    $grpRestore.Controls.Add($cmbConflictMode)
    Add-FieldLabel -Parent $grpRestore -Text '(applies when an object name already exists in the target tenant)' -Y 24 -X 350 -Width 360 -Color Gray

    $chkRestoreAssignments = New-SettingsCheck -Text 'Restore assignments by default (resolve groups by displayName in target tenant)' -X 160 -Y 50
    $grpRestore.Controls.Add($chkRestoreAssignments)

    $chkDryRunDefault = New-SettingsCheck -Text 'Dry run (validate-only) by default — no Graph writes until disabled' -X 160 -Y 76
    $grpRestore.Controls.Add($chkDryRunDefault)

    # ── Graph API endpoint group ─────────────────────────────────────────────
    $grpGraph = New-SettingsGroup -Parent $scroll -Text 'Graph API Endpoints' -Y $yPos -Height 90
    $yPos += 98

    $chkUseBeta = New-SettingsCheck -Text 'Prefer beta endpoint where v1.0 is incomplete (per-category overrides in AppConfig.json)' -X 160 -Y 24
    $grpGraph.Controls.Add($chkUseBeta)

    $lblBetaInfo = [System.Windows.Forms.Label]::new()
    $lblBetaInfo.Location  = [System.Drawing.Point]::new(160, 50)
    $lblBetaInfo.Size      = [System.Drawing.Size]::new(580, 32)
    $lblBetaInfo.Font      = [System.Drawing.Font]::new('Segoe UI', 8.5)
    $lblBetaInfo.ForeColor = [System.Drawing.Color]::Gray
    $lblBetaInfo.Text      = 'Workloads pinned to beta: ProactiveRemediations, AdministrativeTemplates. Others honour the per-category override in EndpointVersions.'
    $grpGraph.Controls.Add($lblBetaInfo)

    # ── Naming pattern ───────────────────────────────────────────────────────
    $grpName = New-SettingsGroup -Parent $scroll -Text 'Backup Folder Naming' -Y $yPos -Height 60
    $yPos += 68

    Add-FieldLabel -Parent $grpName -Text 'Pattern:' -Y 22
    $txtNamingPattern = [System.Windows.Forms.TextBox]::new()
    $txtNamingPattern.Location = [System.Drawing.Point]::new(160, 20)
    $txtNamingPattern.Width    = 540
    $grpName.Controls.Add($txtNamingPattern)
    Add-FieldLabel -Parent $grpName -Text 'Tokens: {tenant} {tenantId} {timestamp}' -Y 22 -X 706 -Width 240 -Color Gray

    $btnPickPath.Add_Click({
        $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
        $dlg.Description         = 'Select backup root folder'
        $dlg.ShowNewFolderButton = $true
        if ($txtBackupPath.Text -and (Test-Path $txtBackupPath.Text)) {
            $dlg.SelectedPath = $txtBackupPath.Text
        }
        if ($dlg.ShowDialog() -eq 'OK') { $txtBackupPath.Text = $dlg.SelectedPath }
    })

    # ── Logging ──────────────────────────────────────────────────────────────
    $grpLog = New-SettingsGroup -Parent $scroll -Text 'Logging' -Y $yPos -Height 78
    $yPos += 86

    Add-FieldLabel -Parent $grpLog -Text 'Log Level:' -Y 24
    $cmbLogLevel = [System.Windows.Forms.ComboBox]::new()
    $cmbLogLevel.Location      = [System.Drawing.Point]::new(160, 21)
    $cmbLogLevel.Width         = 120
    $cmbLogLevel.DropDownStyle = 'DropDownList'
    $cmbLogLevel.Items.AddRange([string[]]@('DEBUG', 'INFO', 'WARN', 'ERROR'))
    $cmbLogLevel.SelectedIndex = 1
    $grpLog.Controls.Add($cmbLogLevel)

    $chkLogToFile = New-SettingsCheck -Text 'Also write log to file in backup folder' -X 160 -Y 50
    $grpLog.Controls.Add($chkLogToFile)

    # ── Graph / Retry ────────────────────────────────────────────────────────
    $grpRetry = New-SettingsGroup -Parent $scroll -Text 'Graph API / Retry' -Y $yPos -Height 102
    $yPos += 110

    Add-FieldLabel -Parent $grpRetry -Text 'Max Retries:' -Y 26
    $numMaxRetries = New-NumericUpDown -X 160 -Y 23 -Min 0 -Max 10 -Value 3
    $grpRetry.Controls.Add($numMaxRetries)
    Add-FieldLabel -Parent $grpRetry -Text '(on 429 / 5xx)' -Y 26 -X 230 -Width 120 -Color Gray

    Add-FieldLabel -Parent $grpRetry -Text 'Base Delay (s):' -Y 52
    $numBaseDelay = New-NumericUpDown -X 160 -Y 49 -Min 1 -Max 60 -Value 2
    $grpRetry.Controls.Add($numBaseDelay)
    Add-FieldLabel -Parent $grpRetry -Text '(doubles each attempt)' -Y 52 -X 230 -Width 160 -Color Gray

    Add-FieldLabel -Parent $grpRetry -Text 'Page Size:' -Y 78
    $numPageSize = New-NumericUpDown -X 160 -Y 75 -Min 10 -Max 999 -Value 100
    $grpRetry.Controls.Add($numPageSize)
    Add-FieldLabel -Parent $grpRetry -Text '($top per Graph request)' -Y 78 -X 230 -Width 180 -Color Gray

    # ── UI Behaviour ─────────────────────────────────────────────────────────
    $grpUI = New-SettingsGroup -Parent $scroll -Text 'UI Behaviour' -Y $yPos -Height 78
    $yPos += 86

    $chkConfirmDisconnect = New-SettingsCheck -Text 'Confirm before disconnecting from tenant' -X 160 -Y 22
    $grpUI.Controls.Add($chkConfirmDisconnect)

    $chkShowDebug = New-SettingsCheck -Text 'Show DEBUG messages in Log tab' -X 160 -Y 46
    $grpUI.Controls.Add($chkShowDebug)

    # ── Config path label ────────────────────────────────────────────────────
    $lblConfigPath = [System.Windows.Forms.Label]::new()
    $lblConfigPath.Location  = [System.Drawing.Point]::new(0, $yPos)
    $lblConfigPath.Size      = [System.Drawing.Size]::new(760, 18)
    $lblConfigPath.Text      = ''
    $lblConfigPath.ForeColor = [System.Drawing.Color]::Gray
    $lblConfigPath.Font      = [System.Drawing.Font]::new('Consolas', 7.5)
    $scroll.Controls.Add($lblConfigPath)
    $yPos += 24

    # ── Action buttons ───────────────────────────────────────────────────────
    $btnSave = [System.Windows.Forms.Button]::new()
    $btnSave.Text      = 'Save Settings'
    $btnSave.Location  = [System.Drawing.Point]::new(0, $yPos)
    $btnSave.Size      = [System.Drawing.Size]::new(130, 30)
    $btnSave.FlatStyle = 'Flat'
    $btnSave.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $btnSave.ForeColor = [System.Drawing.Color]::White
    $scroll.Controls.Add($btnSave)

    $btnReset = [System.Windows.Forms.Button]::new()
    $btnReset.Text      = 'Reset to Defaults'
    $btnReset.Location  = [System.Drawing.Point]::new(140, $yPos)
    $btnReset.Size      = [System.Drawing.Size]::new(140, 30)
    $btnReset.FlatStyle = 'Flat'
    $scroll.Controls.Add($btnReset)

    $lblSaveStatus = [System.Windows.Forms.Label]::new()
    $lblSaveStatus.Location  = [System.Drawing.Point]::new(290, $yPos + 6)
    $lblSaveStatus.Size      = [System.Drawing.Size]::new(400, 18)
    $lblSaveStatus.Text      = ''
    $lblSaveStatus.ForeColor = [System.Drawing.Color]::DarkGreen
    $scroll.Controls.Add($lblSaveStatus)

    # ════════════════════════════════════════════════════════════════════════
    # Populate controls from config
    # ════════════════════════════════════════════════════════════════════════
    function Load-SettingsFromConfig {
        $cfg = $GlobalState['Config']
        if ($null -eq $cfg) { return }

        $txtBackupPath.Text           = if ($cfg['BackupRootPath']) { $cfg['BackupRootPath'] } else { '' }
        $chkChecksum.Checked          = [bool]($cfg['WriteChecksums']    -eq $true)
        $chkConfirmRestore.Checked    = ($cfg['ConfirmRestore']    -ne $false)
        $chkExportAssignments.Checked = ($cfg['ExportAssignments'] -ne $false)

        # Restore defaults
        $cm = if ($cfg['ConflictMode']) { [string]$cfg['ConflictMode'] } else { 'Skip' }
        $cmIdx = $cmbConflictMode.Items.IndexOf($cm)
        $cmbConflictMode.SelectedIndex = if ($cmIdx -ge 0) { $cmIdx } else { 0 }
        $chkRestoreAssignments.Checked = [bool]($cfg['RestoreAssignmentsByDefault'] -eq $true)
        $chkDryRunDefault.Checked      = [bool]($cfg['DryRunByDefault'] -eq $true)

        # Graph endpoints
        $chkUseBeta.Checked = [bool]($cfg['UseBetaWherePossible'] -eq $true)

        # Naming pattern
        $txtNamingPattern.Text = if ($cfg['BackupFolderNamingPattern']) { [string]$cfg['BackupFolderNamingPattern'] } else { '{tenant}_{tenantId}/{timestamp}' }

        $logLevel = if ($cfg['LogLevel']) { $cfg['LogLevel'] } else { 'INFO' }
        $li = $cmbLogLevel.Items.IndexOf($logLevel)
        if ($li -ge 0) { $cmbLogLevel.SelectedIndex = $li }

        $chkLogToFile.Checked         = ($cfg['LogToFile'] -ne $false)

        $maxR = if ($cfg['MaxRetries'])        { [int]$cfg['MaxRetries'] }        else { 3 }
        $baseD = if ($cfg['BaseDelaySeconds']) { [int]$cfg['BaseDelaySeconds'] }  else { 2 }
        $pgSz = if ($cfg['PageSize'])          { [int]$cfg['PageSize'] }          else { 100 }

        $numMaxRetries.Value = [Math]::Max(0,  [Math]::Min(10,  $maxR))
        $numBaseDelay.Value  = [Math]::Max(1,  [Math]::Min(60,  $baseD))
        $numPageSize.Value   = [Math]::Max(10, [Math]::Min(999, $pgSz))

        $chkConfirmDisconnect.Checked = ($cfg['ConfirmDisconnect'] -ne $false)
        $chkShowDebug.Checked         = [bool]($cfg['ShowDebugInUI'] -eq $true)

        $cfgFile = if ($GlobalState['ConfigFile']) { $GlobalState['ConfigFile'] } else { '' }
        $lblConfigPath.Text = if ($cfgFile) { "Config: $cfgFile" } else { '' }
    }

    Load-SettingsFromConfig

    # ════════════════════════════════════════════════════════════════════════
    # Save
    # ════════════════════════════════════════════════════════════════════════
    $btnSave.Add_Click({
        $lblSaveStatus.Text      = ''
        $lblSaveStatus.ForeColor = [System.Drawing.Color]::DarkGreen

        $pathVal = $txtBackupPath.Text.Trim()
        if ($pathVal -and -not (Test-Path $pathVal)) {
            try {
                New-Item -ItemType Directory -Path $pathVal -Force | Out-Null
            } catch {
                [System.Windows.Forms.MessageBox]::Show(
                    "Cannot create backup folder:`n$_", 'Settings Error',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                return
            }
        }

        $newCfg = @{
            BackupRootPath              = $pathVal
            BackupFolderNamingPattern   = $txtNamingPattern.Text.Trim()
            WriteChecksums              = $chkChecksum.Checked
            ConfirmRestore              = $chkConfirmRestore.Checked
            ExportAssignments           = $chkExportAssignments.Checked
            ConflictMode                = $cmbConflictMode.SelectedItem.ToString()
            RestoreAssignmentsByDefault = $chkRestoreAssignments.Checked
            DryRunByDefault             = $chkDryRunDefault.Checked
            UseBetaWherePossible        = $chkUseBeta.Checked
            LogLevel                    = $cmbLogLevel.SelectedItem.ToString()
            LogToFile                   = $chkLogToFile.Checked
            MaxRetries                  = [int]$numMaxRetries.Value
            BaseDelaySeconds            = [int]$numBaseDelay.Value
            PageSize                    = [int]$numPageSize.Value
            ConfirmDisconnect           = $chkConfirmDisconnect.Checked
            ShowDebugInUI               = $chkShowDebug.Checked
        }

        $cfg = $GlobalState['Config']
        if ($null -ne $cfg) {
            foreach ($k in $newCfg.Keys) { $cfg[$k] = $newCfg[$k] }
        } else {
            $GlobalState['Config'] = $newCfg
            $cfg = $newCfg
        }

        # Re-apply Graph endpoint preferences live so subsequent backups/restores
        # honour the new UseBetaWherePossible / EndpointVersions immediately.
        try {
            $epOverrides = $null
            if ($cfg.ContainsKey('EndpointVersions') -and $cfg['EndpointVersions']) {
                $epOverrides = [hashtable]$cfg['EndpointVersions']
            }
            Set-GraphEndpointConfig -UseBetaWherePossible ([bool]$cfg['UseBetaWherePossible']) -EndpointVersions $epOverrides
        } catch { }

        $cfgFile = $GlobalState['ConfigFile']
        if ($cfgFile) {
            try {
                $cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $cfgFile -Encoding UTF8
                $lblSaveStatus.Text = "Saved at $(Get-Date -Format 'HH:mm:ss')"
            } catch {
                $lblSaveStatus.Text      = "Save failed: $_"
                $lblSaveStatus.ForeColor = [System.Drawing.Color]::DarkRed
            }
        } else {
            $lblSaveStatus.Text      = 'Applied (no config file — not persisted).'
            $lblSaveStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        }

        if ($GlobalState['LoggingInitialized']) {
            try { Set-LogLevel -Level $cfg['LogLevel'] } catch {}
        }
    })

    # ════════════════════════════════════════════════════════════════════════
    # Reset
    # ════════════════════════════════════════════════════════════════════════
    $btnReset.Add_Click({
        $dlg = [System.Windows.Forms.MessageBox]::Show(
            'Reset all settings to application defaults?', 'Confirm Reset',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($dlg -ne 'Yes') { return }

        $defaultFile = Join-Path $GlobalState['AppRoot'] 'Config/AppConfig.json'
        if (Test-Path $defaultFile) {
            try {
                $defaults = Get-Content $defaultFile -Raw | ConvertFrom-Json -AsHashtable
                $GlobalState['Config'] = $defaults
                Load-SettingsFromConfig
                $lblSaveStatus.Text      = 'Reset to defaults. Click Save to persist.'
                $lblSaveStatus.ForeColor = [System.Drawing.Color]::DarkOrange
            } catch {
                $lblSaveStatus.Text      = "Reset failed: $_"
                $lblSaveStatus.ForeColor = [System.Drawing.Color]::DarkRed
            }
        } else {
            $lblSaveStatus.Text      = 'Default config file not found.'
            $lblSaveStatus.ForeColor = [System.Drawing.Color]::DarkRed
        }
    })

    $UIRefs.ReloadSettingsTab = { Load-SettingsFromConfig }

    return $Tab
}

# ── Layout helpers ────────────────────────────────────────────────────────────
function New-SettingsGroup {
    param([System.Windows.Forms.Control]$Parent, [string]$Text, [int]$Y, [int]$Height)
    $gb = [System.Windows.Forms.GroupBox]::new()
    $gb.Text     = $Text
    $gb.Location = [System.Drawing.Point]::new(0, $Y)
    $gb.Size     = [System.Drawing.Size]::new(760, $Height)
    $gb.Padding  = [System.Windows.Forms.Padding]::new(4)
    $Parent.Controls.Add($gb)
    return $gb
}

function Add-FieldLabel {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$Y,
        [int]$X = 8,
        [int]$Width = 148,
        $Color = $null
    )
    $lbl = [System.Windows.Forms.Label]::new()
    $lbl.Text      = $Text
    $lbl.Location  = [System.Drawing.Point]::new($X, $Y)
    $lbl.Size      = [System.Drawing.Size]::new($Width, 18)
    $lbl.TextAlign = 'MiddleRight'
    if ($Color) { $lbl.ForeColor = $Color }
    $Parent.Controls.Add($lbl)
}

function New-SettingsCheck {
    param([string]$Text, [int]$X, [int]$Y)
    $cb = [System.Windows.Forms.CheckBox]::new()
    $cb.Text     = $Text
    $cb.Location = [System.Drawing.Point]::new($X, $Y)
    $cb.Size     = [System.Drawing.Size]::new(560, 20)
    return $cb
}

function New-NumericUpDown {
    param([int]$X, [int]$Y, [int]$Min, [int]$Max, [int]$Value)
    $n = [System.Windows.Forms.NumericUpDown]::new()
    $n.Location = [System.Drawing.Point]::new($X, $Y)
    $n.Width    = 60
    $n.Minimum  = $Min
    $n.Maximum  = $Max
    $n.Value    = $Value
    return $n
}

function New-SettingsButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 80, [int]$Height = 24)
    $btn = [System.Windows.Forms.Button]::new()
    $btn.Text      = $Text
    $btn.Location  = [System.Drawing.Point]::new($X, $Y)
    $btn.Size      = [System.Drawing.Size]::new($Width, $Height)
    $btn.FlatStyle = 'Flat'
    return $btn
}

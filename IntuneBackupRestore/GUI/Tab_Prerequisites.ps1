<#
.SYNOPSIS
    Prerequisites tab for the Intune Backup & Restore Tool GUI.

.DESCRIPTION
    Provides:
      - DataGrid showing required module name, installed version, status
      - "Check Prerequisites" button
      - "Install Missing" button – shows a confirmation dialog before installing
      - PowerShell environment info panel
      - Color-coded status: OK (green) | Outdated (orange) | Missing (red) | Error (red)

    Installation is NEVER silent.  The user must confirm the list of modules
    to be installed before Install-ModuleConfirmed is called.
#>

Set-StrictMode -Version Latest

function Initialize-TabPrerequisites {
    [CmdletBinding()]
    param(
        [hashtable]$UIRefs,
        [System.Collections.Hashtable]$GlobalState
    )

    $tab         = New-Object System.Windows.Forms.TabPage
    $tab.Text    = '✅ Prerequisites'
    $tab.Padding = [System.Windows.Forms.Padding]::new(10)

    $scroll = New-Object System.Windows.Forms.Panel
    $scroll.Dock       = 'Fill'
    $scroll.AutoScroll = $true

    # ── Module status group ───────────────────────────────────────────────
    $grpModules = _New-GB -Text 'PowerShell Module Status' -Top 8 -Left 8 -Width 980 -Height 320

    $btnCheck = _New-Btn -Text 'Check Prerequisites' -Top 24 -Left 10 -Width 180 `
                         -Color ([System.Drawing.Color]::FromArgb(0,120,212))
    $btnInstall = _New-Btn -Text 'Install Missing' -Top 24 -Left 200 -Width 160 `
                           -Color ([System.Drawing.Color]::FromArgb(0,153,76))
    $btnInstall.Enabled = $false

    # DataGrid
    $dg = New-Object System.Windows.Forms.DataGridView
    $dg.Location                  = [System.Drawing.Point]::new(10, 66)
    $dg.Size                      = [System.Drawing.Size]::new(955, 236)
    $dg.ReadOnly                  = $true
    $dg.AllowUserToAddRows        = $false
    $dg.AllowUserToDeleteRows     = $false
    $dg.AllowUserToResizeRows     = $false
    $dg.SelectionMode             = 'FullRowSelect'
    $dg.AutoSizeColumnsMode       = 'Fill'
    $dg.BorderStyle               = 'FixedSingle'
    $dg.BackgroundColor           = [System.Drawing.Color]::White
    $dg.RowHeadersVisible         = $false
    $dg.Font                      = [System.Drawing.Font]::new('Consolas', 9)
    $dg.ColumnHeadersDefaultCellStyle.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

    foreach ($col in @(
        @{Name='ModuleName'; Header='Module Name';         Weight=35},
        @{Name='Required';   Header='Required';            Weight=10},
        @{Name='InstalledVersion'; Header='Installed';     Weight=18},
        @{Name='MinVersion'; Header='Min. Version';        Weight=15},
        @{Name='Status';     Header='Status';              Weight=12},
        @{Name='Purpose';    Header='Purpose';             Weight=$null}
    )) {
        $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $c.Name       = $col.Name
        $c.HeaderText = $col.Header
        if ($col.Weight) { $c.FillWeight = $col.Weight }
        $dg.Columns.Add($c) | Out-Null
    }

    # Color rows by status
    $dg.Add_DataBindingComplete({
        foreach ($row in $dg.Rows) {
            $status = $row.Cells['Status'].Value
            $row.DefaultCellStyle.ForeColor = switch ($status) {
                'OK'      { [System.Drawing.Color]::FromArgb(0,128,0)   }
                'Outdated'{ [System.Drawing.Color]::FromArgb(180,100,0) }
                'Missing' { [System.Drawing.Color]::Red                  }
                'Error'   { [System.Drawing.Color]::DarkRed              }
                default   { [System.Drawing.Color]::Black                }
            }
            if ($status -in 'Missing','Error') {
                $row.DefaultCellStyle.Font = [System.Drawing.Font]::new('Consolas', 9, [System.Drawing.FontStyle]::Bold)
            }
        }
    })

    $grpModules.Controls.AddRange(@($btnCheck, $btnInstall, $dg))

    # ── Warning banner (shown when install is available) ──────────────────
    $pnlWarn = New-Object System.Windows.Forms.Panel
    $pnlWarn.Location  = [System.Drawing.Point]::new(8, 338)
    $pnlWarn.Size      = [System.Drawing.Size]::new(980, 40)
    $pnlWarn.BackColor = [System.Drawing.Color]::FromArgb(255,243,205)
    $pnlWarn.BorderStyle = 'FixedSingle'
    $pnlWarn.Visible   = $false

    $lblWarn = New-Object System.Windows.Forms.Label
    $lblWarn.Name     = 'lblInstallWarning'
    $lblWarn.Text     = ''
    $lblWarn.Location = [System.Drawing.Point]::new(8, 10)
    $lblWarn.Size     = [System.Drawing.Size]::new(960, 20)
    $lblWarn.Font     = [System.Drawing.Font]::new('Segoe UI', 9)
    $lblWarn.ForeColor= [System.Drawing.Color]::FromArgb(100,60,0)
    $pnlWarn.Controls.Add($lblWarn)

    # ── PS Environment group ──────────────────────────────────────────────
    $grpEnv = _New-GB -Text 'PowerShell Environment' -Top 390 -Left 8 -Width 980 -Height 140

    $envLabels = @(
        @{Caption='PowerShell Version:'; Key='PSVersion';      Col=0}
        @{Caption='Edition:';            Key='PSEdition';      Col=0}
        @{Caption='Apartment State:';    Key='ApartmentState'; Col=480}
        @{Caption='Operating System:';   Key='OS';             Col=480}
        @{Caption='64-bit Process:';     Key='Is64BitProcess'; Col=0}
        @{Caption='Running as Admin:';   Key='IsAdmin';        Col=480}
    )

    $envValueLabels = @{}
    $row = 0
    foreach ($el in $envLabels) {
        $top = 24 + ($row / 2 -as [int]) * 34
        if ($el.Col -eq 0) { $row++ }

        $lCap = New-Object System.Windows.Forms.Label
        $lCap.Text     = $el.Caption
        $lCap.Location = [System.Drawing.Point]::new($el.Col + 10, $top)
        $lCap.Size     = [System.Drawing.Size]::new(150, 22)
        $lCap.Font     = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

        $lVal = New-Object System.Windows.Forms.Label
        $lVal.Text     = '-'
        $lVal.Location = [System.Drawing.Point]::new($el.Col + 165, $top)
        $lVal.Size     = [System.Drawing.Size]::new(290, 22)
        $lVal.Font     = [System.Drawing.Font]::new('Segoe UI', 9)

        $envValueLabels[$el.Key] = $lVal
        $grpEnv.Controls.AddRange(@($lCap, $lVal))
    }

    $grpModules.Controls.AddRange(@($btnCheck, $btnInstall, $dg))
    $scroll.Controls.AddRange(@($grpModules, $pnlWarn, $grpEnv))
    $tab.Controls.Add($scroll)

    # ── Helper: populate environment labels ───────────────────────────────
    function Refresh-EnvInfo {
        $info = Get-PSEnvironmentInfo
        foreach ($key in $envValueLabels.Keys) {
            $val = $info[$key]
            $lbl = $envValueLabels[$key]
            $lbl.Text = if ($null -ne $val) { $val.ToString() } else { '-' }
            if ($key -eq 'IsAdmin' -and $val -eq $true) {
                $lbl.ForeColor = [System.Drawing.Color]::FromArgb(0,128,0)
                $lbl.Text = 'Yes (elevated)'
            } elseif ($key -eq 'IsAdmin') {
                $lbl.ForeColor = [System.Drawing.Color]::FromArgb(180,100,0)
                $lbl.Text = 'No'
            }
            if ($key -eq 'ApartmentState' -and $val -ne 'STA') {
                $lbl.ForeColor = [System.Drawing.Color]::Red
            }
        }
    }

    # ── Helper: run check and fill DataGrid ───────────────────────────────
    function Invoke-PrereqCheck {
        $btnCheck.Enabled = $false
        $btnCheck.Text    = 'Checking...'
        Update-StatusBar  -Text 'Checking prerequisites...'

        try {
            $rows = Test-Prerequisites

            $dg.Rows.Clear()
            foreach ($r in $rows) {
                $idx = $dg.Rows.Add(
                    $r.Name,
                    $r.Required,
                    $r.InstalledVersion,
                    $r.MinVersion,
                    $r.Status,
                    $r.Purpose
                )
                $row = $dg.Rows[$idx]
                $row.DefaultCellStyle.ForeColor = switch ($r.Status) {
                    'OK'      { [System.Drawing.Color]::FromArgb(0,128,0)   }
                    'Outdated'{ [System.Drawing.Color]::FromArgb(180,100,0) }
                    'Missing' { [System.Drawing.Color]::Red                  }
                    'Error'   { [System.Drawing.Color]::DarkRed              }
                    default   { [System.Drawing.Color]::Black                }
                }
                if ($r.Status -in 'Missing','Error') {
                    $row.DefaultCellStyle.Font = [System.Drawing.Font]::new('Consolas', 9, [System.Drawing.FontStyle]::Bold)
                }
            }

            $missing = @($rows | Where-Object { $_.Required -eq 'Yes' -and $_.Status -ne 'OK' })
            if ($missing.Count -gt 0) {
                $names = ($missing | ForEach-Object { $_.Name }) -join ', '
                $lblWarn.Text    = "⚠  $($missing.Count) required module(s) need attention: $names"
                $pnlWarn.Visible = $true
                $btnInstall.Enabled = $true
            } else {
                $pnlWarn.Visible    = $false
                $btnInstall.Enabled = $false
            }

            Update-StatusBar -Text 'Prerequisites check complete.'
        }
        catch {
            Write-LogMessage -Level ERROR -Message "Prerequisites check failed: $($_.Exception.Message)" -ErrorRecord $_
            Update-StatusBar -Text 'Prerequisites check failed – see log.'
        }
        finally {
            $btnCheck.Enabled = $true
            $btnCheck.Text    = 'Check Prerequisites'
        }
    }

    # ── Event: Check ─────────────────────────────────────────────────────
    $btnCheck.Add_Click({ Invoke-PrereqCheck })

    # ── Event: Install ────────────────────────────────────────────────────
    $btnInstall.Add_Click({
        $toInstall = Get-MissingModules
        if ($toInstall.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('No missing required modules found.', 'Nothing to Install', 'OK', 'Information') | Out-Null
            return
        }

        $moduleList = ($toInstall | ForEach-Object { "  • $($_.Name)  (min v$($_.MinVersion), scope: $($_.InstallScope))" }) -join "`n"
        $msg = "The following module(s) will be installed from PSGallery:`n`n$moduleList`n`nDo you want to proceed?"

        $ans = [System.Windows.Forms.MessageBox]::Show(
            $msg, 'Confirm Module Installation', 'YesNo', 'Question')

        if ($ans -ne 'Yes') { return }

        $btnInstall.Enabled = $false
        $btnInstall.Text    = 'Installing...'
        Update-StatusBar -Text 'Installing modules...'

        $allOk = $true
        foreach ($mod in $toInstall) {
            try {
                Write-LogMessage -Level INFO -Message "Installing $($mod.Name)..."
                $result = Install-ModuleConfirmed `
                    -Name        $mod.Name `
                    -MinVersion  $mod.MinVersion `
                    -Scope       $mod.InstallScope `
                    -Confirmed

                if ($result.Success) {
                    Write-LogMessage -Level SUCCESS -Message "Installed $($mod.Name) v$($result.Version)"
                } else {
                    Write-LogMessage -Level ERROR -Message "Install failed: $($mod.Name) – $($result.Error)"
                    $allOk = $false
                }
            }
            catch {
                Write-LogMessage -Level ERROR -Message "Unexpected error installing $($mod.Name)" -ErrorRecord $_
                $allOk = $false
            }
        }

        $btnInstall.Text = 'Install Missing'
        Update-StatusBar -Text 'Installation complete. Re-checking...'

        # Re-run check automatically
        Invoke-PrereqCheck

        if ($allOk) {
            [System.Windows.Forms.MessageBox]::Show(
                'All modules installed successfully.', 'Installation Complete', 'OK', 'Information') | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                'Some modules could not be installed. See the Log tab for details.',
                'Installation Incomplete', 'OK', 'Warning') | Out-Null
        }
    })

    # Expose Refresh-EnvInfo so MainForm can call it on startup
    # (dot-sourcing puts it in the script scope of MainForm.ps1)

    return $tab
}

# ---------------------------------------------------------------------------
#region Private helpers
# ---------------------------------------------------------------------------
function _New-GB {
    param([string]$Text,[int]$Top,[int]$Left,[int]$Width,[int]$Height)
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $Text; $g.Location = [System.Drawing.Point]::new($Left,$Top)
    $g.Size = [System.Drawing.Size]::new($Width,$Height)
    $g.Font = [System.Drawing.Font]::new('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
    return $g
}
function _New-Btn {
    param([string]$Text,[int]$Top,[int]$Left,[int]$Width,
          [System.Drawing.Color]$Color=[System.Drawing.Color]::SteelBlue)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Location = [System.Drawing.Point]::new($Left,$Top)
    $b.Size = [System.Drawing.Size]::new($Width,32)
    $b.BackColor = $Color; $b.ForeColor = [System.Drawing.Color]::White
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.Font   = [System.Drawing.Font]::new('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}
#endregion

<#
.SYNOPSIS
    Connection tab for the Intune Backup & Restore Tool GUI.

.DESCRIPTION
    Provides:
      - Connect button (opens browser for interactive Graph auth)
      - Disconnect button
      - Switch Tenant button (prompts for tenant ID / domain)
      - Tenant detail panel (Name, ID, User, Time)
      - Required Graph scopes table

    Authentication runs in a background runspace via Start-BackgroundOperation
    so the browser can open while the WinForms message loop stays responsive.
    The static Microsoft.Graph.Authentication token context is process-wide,
    so once the runspace sets it the main thread can also use it.
#>

Set-StrictMode -Version Latest

function Initialize-TabConnection {
    [CmdletBinding()]
    param(
        [hashtable]$UIRefs,
        [System.Collections.Hashtable]$GlobalState
    )

    $tab      = New-Object System.Windows.Forms.TabPage
    $tab.Text = '🔗 Connection'
    $tab.Padding = [System.Windows.Forms.Padding]::new(10)

    # ── Outer scroll panel ────────────────────────────────────────────────
    $scroll = New-Object System.Windows.Forms.Panel
    $scroll.Dock          = 'Fill'
    $scroll.AutoScroll    = $true

    # ── Authentication group ──────────────────────────────────────────────
    $grpAuth       = _New-GroupBox -Text 'Authentication' -Top 8 -Left 8 -Width 980 -Height 160
    $lblAuthInfo   = _New-Label -Text 'Sign in to Microsoft Graph using your Microsoft 365 / Entra ID admin account. A browser window will open for interactive authentication.' `
                                -Top 22 -Left 10 -Width 940 -Height 36
    $lblAuthInfo.Font = [System.Drawing.Font]::new('Segoe UI', 9)

    $btnConnect = _New-Button -Text 'Connect' -Top 68 -Left 10 -Width 130 -Color ([System.Drawing.Color]::FromArgb(0,120,212))
    $btnConnect.Name = 'BtnConnect'

    $btnDisconnect = _New-Button -Text 'Disconnect' -Top 68 -Left 150 -Width 130 -Color ([System.Drawing.Color]::FromArgb(196,43,28))
    $btnDisconnect.Enabled = $false
    $btnDisconnect.Name    = 'BtnDisconnect'

    $btnSwitch = _New-Button -Text 'Switch Tenant' -Top 68 -Left 290 -Width 140 -Color ([System.Drawing.Color]::FromArgb(100,100,100))
    $btnSwitch.Enabled = $false

    $grpAuth.Controls.AddRange(@($lblAuthInfo, $btnConnect, $btnDisconnect, $btnSwitch))

    # ── Tenant detail group ───────────────────────────────────────────────
    $grpDetail  = _New-GroupBox -Text 'Connected Tenant' -Top 180 -Left 8 -Width 980 -Height 130

    $lblNames = @('Tenant Name:', 'Tenant ID:', 'Connected User:', 'Connection Time:')
    $valKeys  = @('LblTenantName','LblTenantId','LblConnectedUser','LblConnectionTime')

    for ($i = 0; $i -lt 4; $i++) {
        $col = if ($i -lt 2) { 0 } else { 480 }
        $row = if ($i % 2 -eq 0) { 28 } else { 68 }

        $lCaption = _New-Label -Text $lblNames[$i] -Top $row -Left ($col + 10) -Width 130 -Height 22
        $lCaption.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

        $lValue = _New-Label -Text '-' -Top $row -Left ($col + 145) -Width 320 -Height 22
        $lValue.Name = $valKeys[$i]

        $grpDetail.Controls.AddRange(@($lCaption, $lValue))
        $UIRefs[$valKeys[$i]] = $lValue
    }

    # ── Required scopes group ─────────────────────────────────────────────
    $grpScopes = _New-GroupBox -Text 'Microsoft Graph Permissions (granted vs required)' -Top 322 -Left 8 -Width 980 -Height 240

    $lblScopeInfo = _New-Label -Text 'Granted scopes are checked against required scopes below. Use "Request missing scopes" to step-up consent.' `
                               -Top 22 -Left 10 -Width 800 -Height 20
    $lblScopeInfo.Font = [System.Drawing.Font]::new('Segoe UI', 9)

    $btnRefreshScopes = _New-Button -Text 'Refresh' -Top 18 -Left 818 -Width 70 -Color ([System.Drawing.Color]::FromArgb(100,100,100))
    $btnRequestScopes = _New-Button -Text 'Request missing scopes' -Top 18 -Left 700 -Width 110 -Color ([System.Drawing.Color]::FromArgb(0,120,212))
    # Disable until connected
    $btnRequestScopes.Enabled = $false

    $dgScopes = New-Object System.Windows.Forms.DataGridView
    $dgScopes.Location                  = [System.Drawing.Point]::new(10, 50)
    $dgScopes.Size                      = [System.Drawing.Size]::new(955, 180)
    $dgScopes.ReadOnly                  = $true
    $dgScopes.AllowUserToAddRows        = $false
    $dgScopes.AllowUserToDeleteRows     = $false
    $dgScopes.AllowUserToResizeRows     = $false
    $dgScopes.SelectionMode             = 'FullRowSelect'
    $dgScopes.ColumnHeadersDefaultCellStyle.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $dgScopes.AutoSizeColumnsMode       = 'Fill'
    $dgScopes.BorderStyle               = 'FixedSingle'
    $dgScopes.BackgroundColor           = [System.Drawing.Color]::White
    $dgScopes.RowHeadersVisible         = $false
    $dgScopes.Font                      = [System.Drawing.Font]::new('Segoe UI', 9)

    $dgScopes.Columns.Add('Scope',       'Scope')       | Out-Null
    $dgScopes.Columns.Add('Purpose',     'Purpose')     | Out-Null
    $dgScopes.Columns.Add('RequiredFor', 'Required For')| Out-Null
    $dgScopes.Columns.Add('Status',      'Status')      | Out-Null
    $dgScopes.Columns['Scope'].FillWeight       = 26
    $dgScopes.Columns['Purpose'].FillWeight     = 38
    $dgScopes.Columns['RequiredFor'].FillWeight = 22
    $dgScopes.Columns['Status'].FillWeight      = 14

    # Refresh function — populates rows with current Granted/Missing state.
    $refreshScopeGrid = {
        $dgScopes.Rows.Clear()
        try {
            $rows = Get-CurrentScopeStatus
        }
        catch {
            # Not connected yet — fall back to required-only list with Missing.
            $rows = (Get-RequiredGraphScopes) | ForEach-Object {
                [PSCustomObject]@{
                    Scope=$_.Scope; Purpose=$_.Purpose; RequiredFor=$_.RequiredFor; Granted=$false
                }
            }
        }
        foreach ($r in $rows) {
            $statusText = if ($r.Granted) { 'Granted' } else { 'Missing' }
            $idx = $dgScopes.Rows.Add($r.Scope, $r.Purpose, $r.RequiredFor, $statusText)
            $row = $dgScopes.Rows[$idx]
            if ($r.Granted) {
                $row.Cells['Status'].Style.ForeColor = [System.Drawing.Color]::DarkGreen
                $row.Cells['Status'].Style.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
            }
            else {
                $row.Cells['Status'].Style.ForeColor = [System.Drawing.Color]::DarkRed
                $row.Cells['Status'].Style.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
            }
        }
    }
    & $refreshScopeGrid

    $btnRefreshScopes.Add_Click({ & $refreshScopeGrid })
    $btnRequestScopes.Add_Click({
        $btnRequestScopes.Enabled = $false
        $btnRequestScopes.Text    = 'Requesting...'
        try {
            Request-MissingScopes | Out-Null
            & $refreshScopeGrid
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Could not refresh scopes: $($_.Exception.Message)",
                'Scope refresh',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }
        finally {
            $btnRequestScopes.Text = 'Request missing scopes'
            $btnRequestScopes.Enabled = ($GlobalState.IsConnected -eq $true)
        }
    })

    # Expose refresh callback so the timer can call it after connect / switch
    $UIRefs.RefreshScopeStatus = $refreshScopeGrid
    $UIRefs.BtnRequestScopes   = $btnRequestScopes

    $grpScopes.Controls.AddRange(@($lblScopeInfo, $btnRefreshScopes, $btnRequestScopes, $dgScopes))

    # ── Register UIRefs ───────────────────────────────────────────────────
    $UIRefs.BtnConnect    = $btnConnect
    $UIRefs.BtnDisconnect = $btnDisconnect
    $UIRefs.BtnSwitchTenant = $btnSwitch

    # ── Event Handlers ────────────────────────────────────────────────────

    $btnConnect.Add_Click({
        $UIRefs.BtnConnect.Enabled    = $false
        $UIRefs.BtnConnect.Text       = 'Connecting...'
        Update-StatusBar -Text 'Opening browser for authentication...'

        $connectScript = {
            param($GlobalState, $ExtraArgs)
            $tenantId = if ($ExtraArgs -and $ExtraArgs[0]) { $ExtraArgs[0] } else { $null }

            try {
                $params = @{}
                if ($tenantId) { $params['TenantId'] = $tenantId }
                $result = Connect-IntuneTenant @params

                $GlobalState.IsConnected       = $true
                $GlobalState.TenantDisplayName = $result.TenantDisplayName
                $GlobalState.TenantId          = $result.TenantId
                $GlobalState.ConnectedUser      = $result.ConnectedUser
                $GlobalState.ConnectionTime     = $result.ConnectionTime
            }
            catch {
                Write-LogMessage -Level ERROR -Message "Authentication failed: $($_.Exception.Message)" -ErrorRecord $_
                $GlobalState.IsConnected = $false
            }
        }

        Start-BackgroundOperation -ScriptBlock $connectScript -OperationType 'Connect'
    })

    $btnDisconnect.Add_Click({
        $ans = [System.Windows.Forms.MessageBox]::Show(
            'Disconnect from Microsoft Graph?',
            'Confirm Disconnect', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }

        try {
            Disconnect-IntuneTenant | Out-Null
            $GlobalState.IsConnected        = $false
            $GlobalState.TenantDisplayName  = ''
            $GlobalState.TenantId           = ''
            $GlobalState.ConnectedUser       = ''
            $GlobalState.ConnectionTime      = $null
            Update-TenantDisplay
        }
        catch {
            Write-LogMessage -Level ERROR -Message "Disconnect error: $($_.Exception.Message)"
        }
    })

    $btnSwitch.Add_Click({
        $newTenant = _Show-InputDialog `
            -Title  'Switch Tenant' `
            -Prompt 'Enter Tenant ID (GUID) or verified domain (e.g. contoso.onmicrosoft.com):' `
            -Default $GlobalState.TenantId

        if ([string]::IsNullOrWhiteSpace($newTenant)) { return }

        $UIRefs.BtnConnect.Text    = 'Connecting...'
        $UIRefs.BtnConnect.Enabled = $false

        $switchScript = {
            param($GlobalState, $ExtraArgs)
            $tid = $ExtraArgs[0]
            try {
                $result = Connect-IntuneTenant -TenantId $tid
                $GlobalState.IsConnected       = $true
                $GlobalState.TenantDisplayName = $result.TenantDisplayName
                $GlobalState.TenantId          = $result.TenantId
                $GlobalState.ConnectedUser      = $result.ConnectedUser
                $GlobalState.ConnectionTime     = $result.ConnectionTime
            }
            catch {
                Write-LogMessage -Level ERROR -Message "Tenant switch failed: $($_.Exception.Message)" -ErrorRecord $_
                $GlobalState.IsConnected = $false
            }
        }

        Start-BackgroundOperation -ScriptBlock $switchScript -OperationType 'Connect' -AdditionalArgs @($newTenant)
    })

    # Override _Complete-RunspaceOperation completion hook for Connect type
    # Done by checking GlobalState.IsConnected in the timer (Update-UIFromTimer
    # calls Update-TenantDisplay). We add a one-shot flag approach:
    $btnConnect.Tag = 'ConnectBtn'

    # Assemble
    $scroll.Controls.AddRange(@($grpAuth, $grpDetail, $grpScopes))
    $tab.Controls.Add($scroll)

    return $tab
}

# ---------------------------------------------------------------------------
#region Private helpers
# ---------------------------------------------------------------------------

function _New-GroupBox {
    param([string]$Text, [int]$Top, [int]$Left, [int]$Width, [int]$Height)
    $gb           = New-Object System.Windows.Forms.GroupBox
    $gb.Text      = $Text
    $gb.Location  = [System.Drawing.Point]::new($Left, $Top)
    $gb.Size      = [System.Drawing.Size]::new($Width, $Height)
    $gb.Font      = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    return $gb
}

function _New-Label {
    param([string]$Text, [int]$Top, [int]$Left, [int]$Width, [int]$Height)
    $lbl          = New-Object System.Windows.Forms.Label
    $lbl.Text     = $Text
    $lbl.Location = [System.Drawing.Point]::new($Left, $Top)
    $lbl.Size     = [System.Drawing.Size]::new($Width, $Height)
    $lbl.Font     = [System.Drawing.Font]::new('Segoe UI', 9)
    return $lbl
}

function _New-Button {
    param([string]$Text, [int]$Top, [int]$Left, [int]$Width,
          [System.Drawing.Color]$Color = [System.Drawing.Color]::SteelBlue)
    $btn               = New-Object System.Windows.Forms.Button
    $btn.Text          = $Text
    $btn.Location      = [System.Drawing.Point]::new($Left, $Top)
    $btn.Size          = [System.Drawing.Size]::new($Width, 32)
    $btn.BackColor     = $Color
    $btn.ForeColor     = [System.Drawing.Color]::White
    $btn.FlatStyle     = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.Font          = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $btn.Cursor        = [System.Windows.Forms.Cursors]::Hand
    return $btn
}

function _Show-InputDialog {
    param([string]$Title, [string]$Prompt, [string]$Default = '')

    $dlg            = New-Object System.Windows.Forms.Form
    $dlg.Text       = $Title
    $dlg.Size       = [System.Drawing.Size]::new(480, 160)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = $Prompt
    $lbl.Location = [System.Drawing.Point]::new(12, 16)
    $lbl.Size     = [System.Drawing.Size]::new(440, 40)
    $lbl.Font     = [System.Drawing.Font]::new('Segoe UI', 9)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Text     = $Default
    $txt.Location = [System.Drawing.Point]::new(12, 62)
    $txt.Size     = [System.Drawing.Size]::new(440, 24)
    $txt.Font     = [System.Drawing.Font]::new('Segoe UI', 9)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text           = 'OK'
    $ok.DialogResult   = 'OK'
    $ok.Location       = [System.Drawing.Point]::new(270, 94)
    $ok.Size           = [System.Drawing.Size]::new(88, 28)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text         = 'Cancel'
    $cancel.DialogResult = 'Cancel'
    $cancel.Location     = [System.Drawing.Point]::new(364, 94)
    $cancel.Size         = [System.Drawing.Size]::new(88, 28)

    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel
    $dlg.Controls.AddRange(@($lbl, $txt, $ok, $cancel))

    if ($dlg.ShowDialog() -eq 'OK') { return $txt.Text.Trim() }
    return ''
}

#endregion

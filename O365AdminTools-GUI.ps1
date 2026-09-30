#requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
    O365 Admin Tools - WinForms front-end (Windows only).
.DESCRIPTION
    Thin UI over O365AdminTools.Core.psm1. This file contains only layout, event wiring
    and rendering. All Exchange / Purview / Graph logic lives in the module, shared with
    O365AdminTools-CLI.ps1.

    Changes vs. the original monolithic script:
      - Logic extracted to the Core module (one codebase for GUI + CLI)
      - New-Control / New-ListView factory replaces ~1,500 lines of control boilerplate
      - Compliance search polling and mailbox provisioning run on WinForms Timers
        (no more Start-Sleep + Application.DoEvents blocking / re-entrancy)
      - Every EXO-touching handler is guarded by Test-ExoReady
      - Explicit Connect Graph button + Test-GraphReady for the attendee filter
      - Log mirrored to disk (see Get-ToolLogPath) as well as the on-screen log box
      - Single mailbox context (State.LoadedMailbox) shared by Permissions / Aliases / Auto-Reply / Calendar
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Import-Module (Join-Path $PSScriptRoot 'O365AdminTools.Core.psm1') -Force -ErrorAction Stop

$State  = Get-ToolState
$Config = Get-ToolConfig

# ================================================================================
# UI helpers
# ================================================================================

$script:UI = @{
    Font        = New-Object System.Drawing.Font("Segoe UI", 10)
    FontBold    = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    FontItalic9 = New-Object System.Drawing.Font("Segoe UI",  9, [System.Drawing.FontStyle]::Italic)
    FontSmall9  = New-Object System.Drawing.Font("Segoe UI",  9)
    FontItalic8 = New-Object System.Drawing.Font("Segoe UI",  8, [System.Drawing.FontStyle]::Italic)
    Gray        = [System.Drawing.Color]::Gray
    DimGray     = [System.Drawing.Color]::DimGray
    Green       = [System.Drawing.Color]::DarkGreen
    Red         = [System.Drawing.Color]::Red
    Blue        = [System.Drawing.Color]::DarkBlue
    Text        = [System.Drawing.SystemColors]::WindowText
}

function New-Control {
    <#
    .SYNOPSIS
    Creates a WinForms control, applies properties, adds it to a parent.
    Location / Size accept @(x, y) arrays. Font defaults to the standard UI font.
    #>
    param(
        [Parameter(Mandatory)][string]$Type,
        $Parent,
        [hashtable]$Props = @{}
    )
    $c = New-Object "System.Windows.Forms.$Type"
    if (-not $Props.ContainsKey('Font')) { $c.Font = $script:UI.Font }
    foreach ($k in $Props.Keys) {
        $v = $Props[$k]
        switch ($k) {
            'Location' { $c.Location = New-Object System.Drawing.Point($v[0], $v[1]) }
            'Size'     { $c.Size     = New-Object System.Drawing.Size($v[0], $v[1]) }
            default    { $c.$k = $v }
        }
    }
    if ($Parent) { $Parent.Controls.Add($c) }
    return $c
}

function New-Label {
    param($Parent, [string]$Text, [int[]]$Location, [int[]]$Size, $Font, $ForeColor)
    $p = @{ Text = $Text; Location = $Location }
    if ($Size) { $p.Size = $Size } else { $p.AutoSize = $true }
    if ($Font) { $p.Font = $Font }
    if ($ForeColor) { $p.ForeColor = $ForeColor }
    return New-Control -Type Label -Parent $Parent -Props $p
}

function New-ListView {
    param($Parent, [int[]]$Location, [int[]]$Size, [object[]]$Columns)
    $lv = New-Control -Type ListView -Parent $Parent -Props @{
        Location = $Location; Size = $Size; View = 'Details'; FullRowSelect = $true; GridLines = $true
    }
    foreach ($col in $Columns) { [void]$lv.Columns.Add($col[0], $col[1]) }
    Add-ListViewCopyMenu $lv
    return $lv
}

function Set-ListViewRows {
    <#
    .SYNOPSIS
    Renders an array of objects into a ListView. $Properties = column order.
    Each item's Tag holds the source row. $Style: optional { param($item, $row) }.
    #>
    param($ListView, $Rows, [string[]]$Properties, [scriptblock]$Style)
    $ListView.BeginUpdate()
    $ListView.Items.Clear()
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        $item = New-Object System.Windows.Forms.ListViewItem([string]$row.($Properties[0]))
        foreach ($p in ($Properties | Select-Object -Skip 1)) { [void]$item.SubItems.Add([string]$row.$p) }
        $item.Tag = $row
        if ($Style) { & $Style $item $row }
        [void]$ListView.Items.Add($item)
    }
    $ListView.EndUpdate()
}

function Add-PlaceholderBehavior {
    param([System.Windows.Forms.TextBox]$TextBox, [string]$PlaceholderText)
    $TextBox.Tag       = $PlaceholderText
    $TextBox.Text      = $PlaceholderText
    $TextBox.ForeColor = $script:UI.Gray
    $TextBox.Add_GotFocus({
        if ($this.ForeColor -eq [System.Drawing.Color]::Gray -and $this.Text -eq $this.Tag) {
            $this.Text = ''; $this.ForeColor = [System.Drawing.SystemColors]::WindowText
        }
    })
    $TextBox.Add_LostFocus({
        if ([string]::IsNullOrWhiteSpace($this.Text)) {
            $this.Text = $this.Tag; $this.ForeColor = [System.Drawing.Color]::Gray
        }
    })
}

function Get-ControlText {
    param([System.Windows.Forms.TextBox]$TextBox)
    if ($TextBox.ForeColor -eq $script:UI.Gray -and $TextBox.Text -eq $TextBox.Tag) { return '' }
    return $TextBox.Text.Trim()
}

function Set-ControlText {
    # Sets real text (or restores the placeholder when $Text is empty).
    param([System.Windows.Forms.TextBox]$TextBox, [string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        $TextBox.Text = $TextBox.Tag; $TextBox.ForeColor = $script:UI.Gray
    } else {
        $TextBox.Text = $Text; $TextBox.ForeColor = $script:UI.Text
    }
}

function Add-ListViewCopyMenu {
    param([System.Windows.Forms.ListView]$lv)
    $copyRows = {
        param($listview, $selectedOnly)
        $source = if ($selectedOnly) { $listview.SelectedItems } else { $listview.Items }
        if ($null -eq $source -or $source.Count -eq 0) { return }
        $lines = foreach ($item in $source) {
            (@($item.Text) + @($item.SubItems | Select-Object -Skip 1 | ForEach-Object { $_.Text })) -join "`t"
        }
        [System.Windows.Forms.Clipboard]::SetText(($lines -join "`r`n"))
    }
    $cms = New-Object System.Windows.Forms.ContextMenuStrip
    $miSel = New-Object System.Windows.Forms.ToolStripMenuItem "Copy Selected Row(s)"
    $miSel.ShortcutKeyDisplayString = "Ctrl+C"
    $miSel.Add_Click({ & $copyRows $args[0].GetCurrentParent().SourceControl $true }.GetNewClosure())
    $miAll = New-Object System.Windows.Forms.ToolStripMenuItem "Copy All Rows"
    $miAll.Add_Click({ & $copyRows $args[0].GetCurrentParent().SourceControl $false }.GetNewClosure())
    [void]$cms.Items.Add($miSel); [void]$cms.Items.Add($miAll)
    $lv.ContextMenuStrip = $cms
    $lv.Add_KeyDown({
        $e = $args[1]
        if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::C) {
            & $copyRows $args[0] $true
            $e.Handled = $true
        }
    }.GetNewClosure())
}

function Confirm-Action {
    param([string]$Text, [string]$Title = "Confirm")
    $r = [System.Windows.Forms.MessageBox]::Show($Text, $Title, "YesNo", "Warning")
    return ($r -eq 'Yes')
}
function Show-Info  { param([string]$Text, [string]$Title = "Done")  [System.Windows.Forms.MessageBox]::Show($Text, $Title, "OK", "Information") | Out-Null }
function Show-Error { param([string]$Text, [string]$Title = "Error") [System.Windows.Forms.MessageBox]::Show($Text, $Title, "OK", "Error") | Out-Null }

# ================================================================================
# Form + shared footer (connections, log)
# ================================================================================

$form = New-Control -Type Form -Props @{
    Text = "O365 Admin Tools"; Size = @(960, 1000); MinimumSize = (New-Object System.Drawing.Size(960, 1000)); StartPosition = "CenterScreen"
}
$tabs = New-Control -Type TabControl -Parent $form -Props @{ Location = @(10, 10); Size = @(932, 790) }

$btnConnectEXO    = New-Control -Type Button -Parent $form -Props @{ Text = "Connect EXO";    Location = @(20,  806); Size = @(120, 28) }
$btnConnectIPPS   = New-Control -Type Button -Parent $form -Props @{ Text = "Connect IPPS";   Location = @(146, 806); Size = @(170, 28) }
$btnDisconnectAll = New-Control -Type Button -Parent $form -Props @{ Text = "Disconnect All"; Location = @(322, 806); Size = @(110, 28) }
$btnConnectGraph  = New-Control -Type Button -Parent $form -Props @{ Text = "Connect Graph";  Location = @(438, 806); Size = @(120, 28) }
$lblConnStatus    = New-Label -Parent $form -Text "" -Location @(570, 812) -Font $script:UI.FontSmall9 -ForeColor $script:UI.DimGray

$txtLog = New-Control -Type TextBox -Parent $form -Props @{
    Location = @(20, 842); Size = @(915, 95); Multiline = $true; ScrollBars = "Vertical"; ReadOnly = $true
}
$script:txtLog = $txtLog

# Mirror module log lines into the on-screen log box (they are already written to disk).
Register-ToolLogSink -ScriptBlock {
    param($Line, $Level, $Message)
    if ($script:txtLog -and -not $script:txtLog.IsDisposed) {
        $script:txtLog.AppendText("$Line`r`n")
        $script:txtLog.SelectionStart = $script:txtLog.TextLength
        $script:txtLog.ScrollToCaret()
    }
}

function Update-ConnectionLabels {
    $exo   = if ($State.ExoConnected)   { "Connected" } else { "Not Connected" }
    $graph = if ($State.GraphConnected) { "Connected" } else { "Not Connected" }
    $lblConnStatus.Text      = "EXO: $exo   |   IPPS: $($State.IppsMode)   |   Graph: $graph"
    $lblConnStatus.ForeColor = if ($State.ExoConnected) { $script:UI.Green } else { $script:UI.DimGray }
}

$btnConnectEXO.Add_Click({
    try { Connect-ToolExchangeOnline | Out-Null } catch { Show-Error $_.Exception.Message "EXO Connection Error" }
    Update-ConnectionLabels
})
$btnConnectIPPS.Add_Click({
    try { Connect-ToolCompliance | Out-Null } catch { Show-Error $_.Exception.Message "IPPS Connection Error" }
    Update-ConnectionLabels
})
$btnConnectGraph.Add_Click({
    try { Connect-ToolGraph | Out-Null } catch { Show-Error $_.Exception.Message "Graph Connection Error" }
    Update-ConnectionLabels
})
$btnDisconnectAll.Add_Click({
    Disconnect-ToolSessions
    Update-ConnectionLabels
})

# ================================================================================
# TAB - Create Shared Mailbox
# ================================================================================

$tabMailbox = New-Object System.Windows.Forms.TabPage; $tabMailbox.Text = "Create Shared Mailbox"

New-Label -Parent $tabMailbox -Text "Display Name:" -Location @(20, 22) | Out-Null
$txtDisplay = New-Control -Type TextBox -Parent $tabMailbox -Props @{ Location = @(155, 20); Size = @(310, 25) }
New-Label -Parent $tabMailbox -Text "Alias (no @):" -Location @(20, 62) | Out-Null
$txtAlias   = New-Control -Type TextBox -Parent $tabMailbox -Props @{ Location = @(155, 60); Size = @(310, 25) }
New-Label -Parent $tabMailbox -Text "Primary SMTP:" -Location @(20, 102) | Out-Null
$txtSmtp    = New-Control -Type TextBox -Parent $tabMailbox -Props @{ Location = @(155, 100); Size = @(310, 25) }
Add-PlaceholderBehavior $txtSmtp "e.g. alias@provenit.com"
New-Label -Parent $tabMailbox -Text "Full Access (one per line):" -Location @(20, 148) | Out-Null
$txtFull    = New-Control -Type TextBox -Parent $tabMailbox -Props @{ Location = @(20, 170); Size = @(450, 110); Multiline = $true; ScrollBars = "Vertical" }
New-Label -Parent $tabMailbox -Text "Send As (one per line):" -Location @(20, 298) | Out-Null
$txtSendAs  = New-Control -Type TextBox -Parent $tabMailbox -Props @{ Location = @(20, 320); Size = @(450, 110); Multiline = $true; ScrollBars = "Vertical" }
$btnValidate = New-Control -Type Button -Parent $tabMailbox -Props @{ Text = "Validate";       Location = @(20, 450);  Size = @(120, 35) }
$btnCreate   = New-Control -Type Button -Parent $tabMailbox -Props @{ Text = "Create Mailbox"; Location = @(150, 450); Size = @(140, 35); Enabled = $false }
$lvMailbox   = New-ListView -Parent $tabMailbox -Location @(490, 20) -Size @(425, 465) -Columns @(@("Type",100), @("Identity",220), @("Status",85))

$script:sharedMbxValidation = $null

$btnValidate.Add_Click({
    $btnCreate.Enabled = $false
    $script:sharedMbxValidation = $null
    if (-not (Test-ExoReady)) { return }
    $v = Test-SharedMailboxRequest -DisplayName $txtDisplay.Text.Trim() -Alias $txtAlias.Text.Trim() `
            -PrimarySmtp (Get-ControlText $txtSmtp) -FullAccess (Split-Entries $txtFull.Text) -SendAs (Split-Entries $txtSendAs.Text)
    Set-ListViewRows -ListView $lvMailbox -Rows $v.Rows -Properties Type,Identity,Status -Style {
        param($item, $row) if ($row.Status -ne 'OK') { $item.ForeColor = [System.Drawing.Color]::Red }
    }
    foreach ($e in $v.Errors) { Write-ToolLog $e -Level Warning }
    if ($v.IsValid) {
        $script:sharedMbxValidation = $v
        $btnCreate.Enabled = $true
        Write-ToolLog "Validation passed - click Create Mailbox to proceed." -Level Success
    } else {
        Write-ToolLog "Validation failed. Fix the items above and validate again." -Level Error
    }
})

# Provisioning runs on a Timer so the form stays responsive while EXO propagates.
$script:provisionId       = $null
$script:provisionAttempts = 0
$timerProvision = New-Object System.Windows.Forms.Timer
$timerProvision.Interval = $Config.ProvisionDelaySeconds * 1000
$timerProvision.Add_Tick({
    $script:provisionAttempts++
    try {
        $mbx = Test-MailboxProvisioned -Identity $script:provisionId
        if ($mbx) {
            $timerProvision.Stop()
            $id = $mbx.PrimarySmtpAddress.ToString()
            Write-ToolLog "Mailbox confirmed: $id"
            Set-SharedMailboxPermissions -MailboxId $id -FullAccess $script:sharedMbxValidation.ValidFull -SendAs $script:sharedMbxValidation.ValidSendAs
            Show-Info "Shared mailbox created and permissions applied.`r`n$id" "Success"
            $btnValidate.Enabled = $true
            return
        }
        if ($script:provisionAttempts -ge $Config.ProvisionRetries) {
            $timerProvision.Stop()
            $btnValidate.Enabled = $true
            throw "Mailbox not found after waiting. Permissions can be applied manually once it appears."
        }
        Write-ToolLog "  Waiting... attempt $($script:provisionAttempts)/$($Config.ProvisionRetries)"
    }
    catch {
        $timerProvision.Stop()
        $btnValidate.Enabled = $true
        Write-ToolLog "ERROR: $($_.Exception.Message)" -Level Error
        Show-Error $_.Exception.Message
    }
})

$btnCreate.Add_Click({
    if (-not $script:sharedMbxValidation) { Write-ToolLog "Please run Validate first." -Level Warning; return }
    if (-not (Test-ExoReady)) { return }
    try {
        $script:provisionId = New-SharedMailboxRequest -DisplayName $txtDisplay.Text.Trim() -Alias $txtAlias.Text.Trim() -PrimarySmtp (Get-ControlText $txtSmtp)
        $script:provisionAttempts = 0
        $btnCreate.Enabled   = $false
        $btnValidate.Enabled = $false
        $timerProvision.Start()
    }
    catch {
        Write-ToolLog "ERROR: $($_.Exception.Message)" -Level Error
        Show-Error $_.Exception.Message
    }
})

# ================================================================================
# TAB - Mailbox Permissions (+ Forwarding + Calendar)
# ================================================================================

$tabMbxPerms = New-Object System.Windows.Forms.TabPage; $tabMbxPerms.Text = "Mailbox Permissions"

New-Label -Parent $tabMbxPerms -Text "Mailbox:" -Location @(20, 16) | Out-Null
$txtMbxLookup = New-Control -Type TextBox -Parent $tabMbxPerms -Props @{ Location = @(90, 14); Size = @(380, 25) }
Add-PlaceholderBehavior $txtMbxLookup "alias, UPN, or email address"
$btnMbxLoad   = New-Control -Type Button -Parent $tabMbxPerms -Props @{ Text = "Load Mailbox"; Location = @(482, 12); Size = @(130, 30) }
$lblMbxStatus = New-Label -Parent $tabMbxPerms -Text "" -Location @(622, 17) -ForeColor $script:UI.DimGray

New-Label -Parent $tabMbxPerms -Text "Mailbox Permissions:" -Location @(20, 52) -Font $script:UI.FontBold | Out-Null
$lvMbxPerms = New-ListView -Parent $tabMbxPerms -Location @(20, 72) -Size @(892, 180) -Columns @(@("User",310), @("Full Access",130), @("Send As",120), @("Send on Behalf",200))

$grpMbxGrant = New-Control -Type GroupBox -Parent $tabMbxPerms -Props @{ Text = "Grant / Revoke Permissions"; Location = @(20, 260); Size = @(892, 68); Font = $script:UI.FontBold }
New-Label -Parent $grpMbxGrant -Text "User:" -Location @(12, 30) | Out-Null
$txtMbxGrantUser = New-Control -Type TextBox -Parent $grpMbxGrant -Props @{ Location = @(52, 28); Size = @(190, 25) }
Add-PlaceholderBehavior $txtMbxGrantUser "user@domain.com"
$chkFullAccess   = New-Control -Type CheckBox -Parent $grpMbxGrant -Props @{ Text = "Full Access";    Location = @(252, 30); AutoSize = $true }
$chkAutoMap      = New-Control -Type CheckBox -Parent $grpMbxGrant -Props @{ Text = "Auto-Map";       Location = @(355, 30); AutoSize = $true; Font = $script:UI.FontItalic9; Checked = $true; Enabled = $false }
$chkSendAs       = New-Control -Type CheckBox -Parent $grpMbxGrant -Props @{ Text = "Send As";        Location = @(450, 30); AutoSize = $true }
$chkSendOnBehalf = New-Control -Type CheckBox -Parent $grpMbxGrant -Props @{ Text = "Send on Behalf"; Location = @(525, 30); AutoSize = $true }
$btnMbxGrant     = New-Control -Type Button   -Parent $grpMbxGrant -Props @{ Text = "Grant";  Location = @(692, 26); Size = @(90, 30) }
$btnMbxRevoke    = New-Control -Type Button   -Parent $grpMbxGrant -Props @{ Text = "Revoke"; Location = @(790, 26); Size = @(90, 30) }

$grpFwd = New-Control -Type GroupBox -Parent $tabMbxPerms -Props @{ Text = "Forwarding"; Location = @(20, 336); Size = @(892, 90); Font = $script:UI.FontBold }
New-Label -Parent $grpFwd -Text "Forward to:" -Location @(12, 28) | Out-Null
$txtFwdTo    = New-Control -Type TextBox  -Parent $grpFwd -Props @{ Location = @(92, 26); Size = @(230, 25) }
Add-PlaceholderBehavior $txtFwdTo "user@domain.com"
$chkKeepCopy = New-Control -Type CheckBox -Parent $grpFwd -Props @{ Text = "Keep copy"; Location = @(330, 28); AutoSize = $true }
$btnSetFwd   = New-Control -Type Button   -Parent $grpFwd -Props @{ Text = "Set";   Location = @(12, 57); Size = @(80, 26) }
$btnClearFwd = New-Control -Type Button   -Parent $grpFwd -Props @{ Text = "Clear"; Location = @(98, 57); Size = @(80, 26) }

$grpCalPerms   = New-Control -Type GroupBox -Parent $tabMbxPerms -Props @{ Text = "Calendar Permissions"; Location = @(20, 434); Size = @(892, 328); Font = $script:UI.FontBold }
$btnRefreshCal = New-Control -Type Button -Parent $grpCalPerms -Props @{ Text = "Refresh"; Location = @(792, 18); Size = @(90, 26) }
$lvCalPerms    = New-ListView -Parent $grpCalPerms -Location @(10, 48) -Size @(870, 184) -Columns @(@("User",300), @("Access Rights",220), @("Is Inherited",130))
New-Label -Parent $grpCalPerms -Text "User:" -Location @(10, 242) | Out-Null
$txtCalGrantUser = New-Control -Type TextBox -Parent $grpCalPerms -Props @{ Location = @(52, 240); Size = @(200, 25) }
Add-PlaceholderBehavior $txtCalGrantUser "user@domain.com"
New-Label -Parent $grpCalPerms -Text "Permission:" -Location @(265, 242) | Out-Null
$cboCalLevel = New-Control -Type ComboBox -Parent $grpCalPerms -Props @{ Location = @(345, 239); Size = @(185, 25); DropDownStyle = 'DropDownList' }
Get-CalendarPermissionLevels | ForEach-Object { [void]$cboCalLevel.Items.Add($_) }
$cboCalLevel.SelectedItem = 'Reviewer'
$btnCalGrant = New-Control -Type Button -Parent $grpCalPerms -Props @{ Text = "Grant / Update"; Location = @(545, 237); Size = @(130, 30) }
New-Label -Parent $grpCalPerms -Text "Remove:" -Location @(10, 284) | Out-Null
$txtCalRemoveUser = New-Control -Type TextBox -Parent $grpCalPerms -Props @{ Location = @(75, 282); Size = @(200, 25) }
Add-PlaceholderBehavior $txtCalRemoveUser "user@domain.com"
$btnCalRemove = New-Control -Type Button -Parent $grpCalPerms -Props @{ Text = "Remove"; Location = @(285, 280); Size = @(100, 28) }
New-Label -Parent $grpCalPerms -Text "Click a row to fill both user fields." -Location @(400, 287) -Font $script:UI.FontItalic9 -ForeColor $script:UI.DimGray | Out-Null

# ================================================================================
# TAB - Auto-Reply
# ================================================================================

$tabOOO = New-Object System.Windows.Forms.TabPage; $tabOOO.Text = "Auto-Reply"

New-Label -Parent $tabOOO -Text "Mailbox:" -Location @(20, 14) | Out-Null
$txtOOOMbx = New-Control -Type TextBox -Parent $tabOOO -Props @{ Location = @(90, 12); Size = @(360, 25) }
Add-PlaceholderBehavior $txtOOOMbx "alias, UPN, or email"
$btnOOOLoad       = New-Control -Type Button -Parent $tabOOO -Props @{ Text = "Load"; Location = @(460, 10); Size = @(80, 28) }
$lblOOOCurrentMbx = New-Label -Parent $tabOOO -Text "" -Location @(552, 15) -ForeColor $script:UI.DimGray
New-Label -Parent $tabOOO -Text "Status:" -Location @(20, 52) | Out-Null
$cboOOOState = New-Control -Type ComboBox -Parent $tabOOO -Props @{ Location = @(72, 49); Size = @(140, 25); DropDownStyle = 'DropDownList' }
@('Disabled','Enabled') | ForEach-Object { [void]$cboOOOState.Items.Add($_) }
$cboOOOState.SelectedIndex = 0
New-Label -Parent $tabOOO -Text "Internal Reply Message:" -Location @(20, 86) -Font $script:UI.FontBold | Out-Null
$txtOOOInternal = New-Control -Type TextBox -Parent $tabOOO -Props @{ Location = @(20, 108); Size = @(892, 175); Multiline = $true; ScrollBars = "Vertical" }
New-Label -Parent $tabOOO -Text "External Reply Message:" -Location @(20, 296) -Font $script:UI.FontBold | Out-Null
$txtOOOExternal = New-Control -Type TextBox -Parent $tabOOO -Props @{ Location = @(20, 318); Size = @(892, 175); Multiline = $true; ScrollBars = "Vertical" }
$btnSetOOO = New-Control -Type Button -Parent $tabOOO -Props @{ Text = "Apply Auto-Reply"; Location = @(792, 504); Size = @(120, 35) }

# ================================================================================
# TAB - Aliases
# ================================================================================

$tabAliasSearch = New-Object System.Windows.Forms.TabPage; $tabAliasSearch.Text = "Aliases"

New-Label -Parent $tabAliasSearch -Text "Search:" -Location @(20, 18) | Out-Null
$txtAliasSearch  = New-Control -Type TextBox  -Parent $tabAliasSearch -Props @{ Location = @(72, 16); Size = @(360, 25) }
Add-PlaceholderBehavior $txtAliasSearch "alias, partial email, or full address"
$chkAliasPartial = New-Control -Type CheckBox -Parent $tabAliasSearch -Props @{ Text = "Partial match"; Location = @(448, 17); AutoSize = $true; Checked = $true }
$btnAliasSearch  = New-Control -Type Button   -Parent $tabAliasSearch -Props @{ Text = "Search"; Location = @(560, 14); Size = @(100, 28) }
New-Label -Parent $tabAliasSearch -Text "Searches across all mailboxes, shared mailboxes, distribution groups, and mail users. Double-click a row to load that mailbox." `
    -Location @(20, 50) -Size @(880, 18) -Font $script:UI.FontItalic9 -ForeColor $script:UI.DimGray | Out-Null
$lvAliasResults = New-ListView -Parent $tabAliasSearch -Location @(20, 74) -Size @(892, 256) -Columns @(@("Display Name",240), @("Primary SMTP",280), @("Type",160), @("Matched Address",200))

$grpAliases = New-Control -Type GroupBox -Parent $tabAliasSearch -Props @{ Text = "Manage Aliases"; Location = @(20, 344); Size = @(892, 412); Font = $script:UI.FontBold }
$lblAliasCurrentMbx = New-Label -Parent $grpAliases -Text "No mailbox loaded - load one from the Mailbox Permissions tab." -Location @(10, 22) -Font $script:UI.FontItalic9 -ForeColor $script:UI.DimGray
$lvAliases = New-ListView -Parent $grpAliases -Location @(10, 44) -Size @(870, 284) -Columns @(@("Address",560), @("Type",290))
New-Label -Parent $grpAliases -Text "Add Alias:" -Location @(10, 340) | Out-Null
$txtAddAlias    = New-Control -Type TextBox -Parent $grpAliases -Props @{ Location = @(82, 338); Size = @(450, 25) }
Add-PlaceholderBehavior $txtAddAlias "newalias@domain.com"
$btnAddAlias    = New-Control -Type Button -Parent $grpAliases -Props @{ Text = "Add";             Location = @(544, 336); Size = @(120, 28) }
$btnRemoveAlias = New-Control -Type Button -Parent $grpAliases -Props @{ Text = "Remove Selected"; Location = @(10, 374);  Size = @(150, 28) }

# ================================================================================
# TAB - Email Investigation (Compliance Search + Message Trace sub-tabs)
# ================================================================================

$tabEmailInv  = New-Object System.Windows.Forms.TabPage; $tabEmailInv.Text = "Email Investigation"
$subEmailTabs = New-Control -Type TabControl -Parent $tabEmailInv -Props @{ Location = @(0, 0); Size = @(932, 790) }

# ---- Compliance Search ----------------------------------------------------------
$tabCompliance = New-Object System.Windows.Forms.TabPage; $tabCompliance.Text = "Compliance Search"
$grpCriteria = New-Control -Type GroupBox -Parent $tabCompliance -Props @{ Text = "Search Criteria"; Location = @(10, 10); Size = @(900, 220); Font = $script:UI.FontBold }

New-Label -Parent $grpCriteria -Text "From Address:"        -Location @(15, 30)  -Size @(110, 20) | Out-Null
$txtFrom      = New-Control -Type TextBox -Parent $grpCriteria -Props @{ Location = @(130, 28); Size = @(280, 23) }
New-Label -Parent $grpCriteria -Text "Subject Contains:"    -Location @(440, 30) -Size @(115, 20) | Out-Null
$txtSubject   = New-Control -Type TextBox -Parent $grpCriteria -Props @{ Location = @(560, 28); Size = @(300, 23) }
New-Label -Parent $grpCriteria -Text "Recipient (optional):" -Location @(15, 65) -Size @(115, 20) | Out-Null
$txtRecipient = New-Control -Type TextBox -Parent $grpCriteria -Props @{ Location = @(130, 63); Size = @(280, 23) }
New-Label -Parent $grpCriteria -Text "Scope:"               -Location @(440, 65) -Size @(50, 20) | Out-Null
$cmbScope = New-Control -Type ComboBox -Parent $grpCriteria -Props @{ Location = @(560, 63); Size = @(180, 23); DropDownStyle = 'DropDownList' }
@("All Mailboxes","Specific Mailbox") | ForEach-Object { [void]$cmbScope.Items.Add($_) }
$cmbScope.SelectedIndex = 0
New-Label -Parent $grpCriteria -Text "Mailbox:"             -Location @(15, 100) -Size @(110, 20) | Out-Null
$txtMailbox = New-Control -Type TextBox -Parent $grpCriteria -Props @{ Location = @(130, 98); Size = @(280, 23); Enabled = $false }
New-Label -Parent $grpCriteria -Text "Received Start:"      -Location @(440, 100) -Size @(100, 20) | Out-Null
$dtpStart = New-Control -Type DateTimePicker -Parent $grpCriteria -Props @{ Location = @(560, 98);  Size = @(180, 23); Format = 'Short'; Value = (Get-Date).Date.AddDays(-3); ShowCheckBox = $true; Checked = $true }
New-Label -Parent $grpCriteria -Text "Received End:"        -Location @(440, 135) -Size @(100, 20) | Out-Null
$dtpEnd   = New-Control -Type DateTimePicker -Parent $grpCriteria -Props @{ Location = @(560, 133); Size = @(180, 23); Format = 'Short'; Value = (Get-Date).Date; ShowCheckBox = $true; Checked = $true }
$btnRunSearch = New-Control -Type Button -Parent $grpCriteria -Props @{ Text = "Run Search";        Location = @(130, 170); Size = @(140, 30) }
$btnPurge     = New-Control -Type Button -Parent $grpCriteria -Props @{ Text = "Soft Delete Purge"; Location = @(285, 170); Size = @(160, 30) }
$btnClearSpam = New-Control -Type Button -Parent $grpCriteria -Props @{ Text = "Clear Fields";      Location = @(460, 170); Size = @(120, 30) }

$grpResults = New-Control -Type GroupBox -Parent $tabCompliance -Props @{ Text = "Last Search Result"; Location = @(10, 240); Size = @(900, 90); Font = $script:UI.FontBold }
New-Label -Parent $grpResults -Text "Search Name:" -Location @(15, 30) -Size @(90, 20) | Out-Null
$txtSearchName = New-Control -Type TextBox -Parent $grpResults -Props @{ Location = @(110, 28); Size = @(560, 23); ReadOnly = $true }
New-Label -Parent $grpResults -Text "Item Count:"  -Location @(15, 58) -Size @(90, 20) | Out-Null
$txtItemCount  = New-Control -Type TextBox -Parent $grpResults -Props @{ Location = @(110, 56); Size = @(120, 23); ReadOnly = $true }

# ---- Message Trace --------------------------------------------------------------
$tabTrace = New-Object System.Windows.Forms.TabPage; $tabTrace.Text = "Message Trace"

New-Label -Parent $tabTrace -Text "Sender:"           -Location @(15, 18)  -Size @(65, 20) | Out-Null
$txtMfSender    = New-Control -Type TextBox -Parent $tabTrace -Props @{ Location = @(85, 16);  Size = @(200, 23) }
New-Label -Parent $tabTrace -Text "Recipient:"        -Location @(300, 18) -Size @(70, 20) | Out-Null
$txtMfRecipient = New-Control -Type TextBox -Parent $tabTrace -Props @{ Location = @(375, 16); Size = @(200, 23) }
New-Label -Parent $tabTrace -Text "Subject contains:" -Location @(590, 18) -Size @(105, 20) | Out-Null
$txtMfSubject   = New-Control -Type TextBox -Parent $tabTrace -Props @{ Location = @(695, 16); Size = @(180, 23) }
New-Label -Parent $tabTrace -Text "Start:"            -Location @(15, 53)  -Size @(65, 20) | Out-Null
$dtpMfStart = New-Control -Type DateTimePicker -Parent $tabTrace -Props @{ Location = @(85, 51);  Size = @(150, 23); Format = 'Short'; Value = (Get-Date).AddDays(-2) }
New-Label -Parent $tabTrace -Text "End:"              -Location @(300, 53) -Size @(70, 20) | Out-Null
$dtpMfEnd   = New-Control -Type DateTimePicker -Parent $tabTrace -Props @{ Location = @(375, 51); Size = @(150, 23); Format = 'Short'; Value = (Get-Date) }
New-Label -Parent $tabTrace -Text "Status:"           -Location @(590, 53) -Size @(65, 20) | Out-Null
$cmbMfStatus = New-Control -Type ComboBox -Parent $tabTrace -Props @{ Location = @(655, 49); Size = @(150, 23); DropDownStyle = 'DropDownList' }
Get-MessageTraceStatuses | ForEach-Object { [void]$cmbMfStatus.Items.Add($_) }
$cmbMfStatus.SelectedIndex = 0
$btnMfSearch = New-Control -Type Button -Parent $tabTrace -Props @{ Text = "Search Mail Flow"; Location = @(695, 85); Size = @(180, 28) }

New-Label -Parent $tabTrace -Text "Results:" -Location @(15, 118) -Size @(100, 18) -Font $script:UI.FontBold | Out-Null
$lvMfResults = New-ListView -Parent $tabTrace -Location @(15, 138) -Size @(870, 150) -Columns @(@("Received",130), @("Sender",190), @("Recipient",190), @("Subject",230), @("Status",100))
$btnMfDetails         = New-Control -Type Button -Parent $tabTrace -Props @{ Text = "View Transport Detail";  Location = @(15, 296);  Size = @(190, 28) }
$btnMfMailboxActivity = New-Control -Type Button -Parent $tabTrace -Props @{ Text = "Check Mailbox Activity"; Location = @(215, 296); Size = @(190, 28) }
$btnMfInboxRules      = New-Control -Type Button -Parent $tabTrace -Props @{ Text = "Show Inbox Rules";       Location = @(415, 296); Size = @(170, 28) }
New-Label -Parent $tabTrace -Text "Transport Detail (selected message):" -Location @(15, 332) -Size @(300, 18) -Font $script:UI.FontBold | Out-Null
$lvMfDetail = New-ListView -Parent $tabTrace -Location @(15, 352) -Size @(870, 80) -Columns @(@("Time",130), @("Event",110), @("Detail",610))
New-Label -Parent $tabTrace -Text "Mailbox Activity - best-effort match by recipient + subject + time window after delivery. Audit log can take up to an hour to populate." `
    -Location @(15, 436) -Size @(870, 16) -Font $script:UI.FontItalic8 -ForeColor $script:UI.DimGray | Out-Null
$lvMfActivity = New-ListView -Parent $tabTrace -Location @(15, 454) -Size @(870, 80) -Columns @(@("Time",130), @("Operation",110), @("Folder",180), @("Details",430))
New-Label -Parent $tabTrace -Text "Recipient's Current Inbox Rules:" -Location @(15, 538) -Size @(300, 18) -Font $script:UI.FontBold | Out-Null
$lvMfRules = New-ListView -Parent $tabTrace -Location @(15, 558) -Size @(870, 100) -Columns @(@("Name",160), @("Enabled",60), @("Priority",55), @("Conditions",290), @("Actions",290))

[void]$subEmailTabs.TabPages.Add($tabCompliance)
[void]$subEmailTabs.TabPages.Add($tabTrace)

# ================================================================================
# TAB - Recurring Events
# ================================================================================

$tabRecurring = New-Object System.Windows.Forms.TabPage; $tabRecurring.Text = "Recurring Events"

New-Label -Parent $tabRecurring -Text ("Finds meetings the mailbox organizes (with attendees/resources) in the chosen date " +
    "window, then cancels them. Recurring series with any occurrence in that window are cancelled in full.") `
    -Location @(20, 16) -Size @(892, 36) -Font $script:UI.FontItalic9 -ForeColor $script:UI.DimGray | Out-Null
New-Label -Parent $tabRecurring -Text "Mailbox:" -Location @(20, 62) | Out-Null
$txtRecMbx = New-Control -Type TextBox -Parent $tabRecurring -Props @{ Location = @(90, 58); Size = @(280, 25) }
Add-PlaceholderBehavior $txtRecMbx "user@domain.com"
New-Label -Parent $tabRecurring -Text "Start Date:" -Location @(390, 62) | Out-Null
$dtpRecStart = New-Control -Type DateTimePicker -Parent $tabRecurring -Props @{ Location = @(465, 58); Size = @(120, 25); Format = 'Short'; Value = (Get-Date) }
New-Label -Parent $tabRecurring -Text "Window (days):" -Location @(600, 62) | Out-Null
$nudRecWindow = New-Control -Type NumericUpDown -Parent $tabRecurring -Props @{ Location = @(710, 58); Size = @(60, 25); Minimum = 1; Maximum = 1825; Value = 1 }
$chkRecCustomRouting  = New-Control -Type CheckBox -Parent $tabRecurring -Props @{ Location = @(90, 92);  AutoSize = $true; Font = $script:UI.FontSmall9
    Text = "Use Custom Routing (experimental - routes directly to the mailbox's backend server; may avoid a generic 'server side error')" }
$chkRecSingleAttendee = New-Control -Type CheckBox -Parent $tabRecurring -Props @{ Location = @(90, 114); AutoSize = $true; Font = $script:UI.FontSmall9
    Text = "Only show meetings with 0-1 other attendees (personal room bookings / 1:1 calls) - requires Graph connection" }
$btnRecSearch = New-Control -Type Button -Parent $tabRecurring -Props @{ Text = "Search (Preview)"; Location = @(20, 150); Size = @(160, 32) }
$lblRecStatus = New-Label -Parent $tabRecurring -Text "" -Location @(190, 158) -ForeColor $script:UI.DimGray
New-Label -Parent $tabRecurring -Text "Meetings that would be cancelled:" -Location @(20, 194) -Font $script:UI.FontBold | Out-Null
$lvRecEvents  = New-ListView -Parent $tabRecurring -Location @(20, 218) -Size @(892, 300) -Columns @(@("Subject",620), @("Start Date",260))
$btnRecCancel = New-Control -Type Button -Parent $tabRecurring -Props @{ Text = "Cancel All Found Meetings"; Location = @(20, 528); Size = @(220, 34); Enabled = $false }
New-Label -Parent $tabRecurring -Text "Run Search first. Cancellation is immediate and emails attendees - this cannot be undone." `
    -Location @(255, 536) -Font $script:UI.FontItalic9 -ForeColor $script:UI.DimGray | Out-Null

# ================================================================================
# Event handlers - Mailbox context (Permissions / Forwarding / Calendar / Aliases / OOO)
# ================================================================================

function Get-LoadedMailboxSmtp {
    if ($null -eq $State.LoadedMailbox) { Write-ToolLog "Load a mailbox first (Mailbox Permissions tab)." -Level Warning; return $null }
    return $State.LoadedMailbox.PrimarySmtpAddress.ToString()
}

function Update-PermissionsView {
    $smtp = Get-LoadedMailboxSmtp; if (-not $smtp) { return }
    $rows = Get-MailboxPermissionReport -Mailbox $smtp
    Set-ListViewRows -ListView $lvMbxPerms -Rows $rows -Properties User,FullAccess,SendAs,SendOnBehalf
    Write-ToolLog "Mbx Perms: $($rows.Count) permission entr$(if ($rows.Count -eq 1){'y'}else{'ies'}) loaded."
}

function Update-CalendarView {
    $smtp = Get-LoadedMailboxSmtp; if (-not $smtp) { return }
    try {
        $rows = Get-CalendarPermissionReport -Mailbox $smtp
        Set-ListViewRows -ListView $lvCalPerms -Rows $rows -Properties User,AccessRights,IsInherited -Style {
            param($item, $row) if ($row.IsSystem) { $item.ForeColor = [System.Drawing.Color]::Gray }
        }
        Write-ToolLog "Calendar: $($rows.Count) permission entr$(if ($rows.Count -eq 1){'y'}else{'ies'}) loaded."
    } catch { Write-ToolLog "Calendar ERROR (load): $($_.Exception.Message)" -Level Error }
}

function Update-AliasView {
    $mbx = Update-MailboxContext
    if (-not $mbx) { return }
    Set-ListViewRows -ListView $lvAliases -Rows (Get-MailboxAliasReport -MailboxObject $mbx) -Properties Address,Type -Style {
        param($item, $row) if ($row.IsPrimary) { $item.ForeColor = [System.Drawing.Color]::DarkBlue }
    }
    $lblAliasCurrentMbx.Text = "$($mbx.DisplayName)  ($($mbx.PrimarySmtpAddress))"; $lblAliasCurrentMbx.ForeColor = $script:UI.Green
}

function Update-ForwardingView {
    $mbx = $State.LoadedMailbox; if (-not $mbx) { return }
    $f = Get-MailboxForwardingReport -MailboxObject $mbx
    Set-ControlText $txtFwdTo $f.ForwardTo
    $chkKeepCopy.Checked = $f.KeepCopy
}

function Update-AutoReplyView {
    $smtp = Get-LoadedMailboxSmtp; if (-not $smtp) { return }
    $mbx = $State.LoadedMailbox
    Set-ControlText $txtOOOMbx $smtp
    $lblOOOCurrentMbx.Text = "$($mbx.DisplayName)  ($smtp)"; $lblOOOCurrentMbx.ForeColor = $script:UI.Green
    try {
        $ooo = Get-MailboxAutoReplyReport -Mailbox $smtp
        $cboOOOState.SelectedItem = $(if ($ooo.Enabled) { 'Enabled' } else { 'Disabled' })
        $txtOOOInternal.Text = $ooo.InternalMessage
        $txtOOOExternal.Text = $ooo.ExternalMessage
    } catch { Write-ToolLog "Auto-Reply: settings unavailable: $($_.Exception.Message)" -Level Warning }
}

function Set-MailboxUiContext {
    param([string]$Identity)
    if (-not (Test-ExoReady)) { return $false }
    if ([string]::IsNullOrWhiteSpace($Identity)) { Write-ToolLog "Enter a mailbox identity first." -Level Warning; return $false }
    try {
        $mbx = Get-MailboxContext -Identity $Identity
        $lblMbxStatus.Text = "$($mbx.DisplayName)  [$($mbx.RecipientTypeDetails)]"; $lblMbxStatus.ForeColor = $script:UI.Green
        Set-ControlText $txtMbxLookup $mbx.PrimarySmtpAddress.ToString()
        Update-PermissionsView
        Update-ForwardingView
        Update-AliasView
        Update-AutoReplyView
        Update-CalendarView
        return $true
    }
    catch {
        $lblMbxStatus.Text = "Not found"; $lblMbxStatus.ForeColor = $script:UI.Red
        $lblOOOCurrentMbx.Text = ""; $lblOOOCurrentMbx.ForeColor = $script:UI.DimGray
        $lblAliasCurrentMbx.Text = "No mailbox loaded - load one from the Mailbox Permissions tab."; $lblAliasCurrentMbx.ForeColor = $script:UI.DimGray
        $lvMbxPerms.Items.Clear(); $lvCalPerms.Items.Clear(); $lvAliases.Items.Clear()
        return $false
    }
}

$btnMbxLoad.Add_Click({ Set-MailboxUiContext (Get-ControlText $txtMbxLookup) | Out-Null })
$btnOOOLoad.Add_Click({ Set-MailboxUiContext (Get-ControlText $txtOOOMbx) | Out-Null })

$chkFullAccess.Add_CheckedChanged({
    $chkAutoMap.Enabled = $chkFullAccess.Checked
    $chkAutoMap.Checked = $chkFullAccess.Checked
})

$lvMbxPerms.Add_SelectedIndexChanged({
    if ($lvMbxPerms.SelectedItems.Count -eq 0) { return }
    $row = $lvMbxPerms.SelectedItems[0].Tag
    Set-ControlText $txtMbxGrantUser $row.User
    $chkFullAccess.Checked   = ($row.FullAccess   -eq 'Yes')
    $chkSendAs.Checked       = ($row.SendAs       -eq 'Yes')
    $chkSendOnBehalf.Checked = ($row.SendOnBehalf -eq 'Yes')
    $chkAutoMap.Checked = $true; $chkAutoMap.Enabled = $chkFullAccess.Checked
})

$btnMbxGrant.Add_Click({
    if (-not (Test-ExoReady)) { return }
    $smtp = Get-LoadedMailboxSmtp; if (-not $smtp) { return }
    $user = Get-ControlText $txtMbxGrantUser
    if (-not $user) { Write-ToolLog "Mbx Perms: Enter a User to grant permissions to." -Level Warning; return }
    if (-not ($chkFullAccess.Checked -or $chkSendAs.Checked -or $chkSendOnBehalf.Checked)) { Write-ToolLog "Mbx Perms: Select at least one permission." -Level Warning; return }
    Grant-MailboxAccess -Mailbox $smtp -User $user -FullAccess:$chkFullAccess.Checked -AutoMapping $chkAutoMap.Checked `
        -SendAs:$chkSendAs.Checked -SendOnBehalf:$chkSendOnBehalf.Checked | Out-Null
    Update-PermissionsView
})

$btnMbxRevoke.Add_Click({
    if (-not (Test-ExoReady)) { return }
    $smtp = Get-LoadedMailboxSmtp; if (-not $smtp) { return }
    $user = Get-ControlText $txtMbxGrantUser
    if (-not $user) { Write-ToolLog "Mbx Perms: Enter a User to revoke permissions from." -Level Warning; return }
    if (-not ($chkFullAccess.Checked -or $chkSendAs.Checked -or $chkSendOnBehalf.Checked)) { Write-ToolLog "Mbx Perms: Select which permissions to revoke." -Level Warning; return }
    if (-not (Confirm-Action "Revoke selected permissions for '$user' on '$smtp'?" "Confirm Revoke")) { return }
    Revoke-MailboxAccess -Mailbox $smtp -User $user -FullAccess:$chkFullAccess.Checked -SendAs:$chkSendAs.Checked -SendOnBehalf:$chkSendOnBehalf.Checked | Out-Null
    Update-PermissionsView
})

$btnSetFwd.Add_Click({
    if (-not (Test-ExoReady)) { return }
    $smtp = Get-LoadedMailboxSmtp; if (-not $smtp) { return }
    $fwd = Get-ControlText $txtFwdTo
    if (-not $fwd) { Write-ToolLog "Mbx Perms: Enter a forwarding address." -Level Warning; return }
    try { Set-MailboxForwarding -Mailbox $smtp -ForwardTo $fwd -KeepCopy $chkKeepCopy.Checked; Update-MailboxContext | Out-Null; Update-ForwardingView }
    catch { Write-ToolLog "Mbx Perms ERROR (set forwarding): $($_.Exception.Message)" -Level Error }
})

$btnClearFwd.Add_Click({
    if (-not (Test-ExoReady)) { return }
    $smtp = Get-LoadedMailboxSmtp; if (-not $smtp) { return }
    try { Clear-MailboxForwarding -Mailbox $smtp; Update-MailboxContext | Out-Null; Update-ForwardingView }
    catch { Write-ToolLog "Mbx Perms ERROR (clear forwarding): $($_.Exception.Message)" -Level Error }
})

$lvCalPerms.Add_SelectedIndexChanged({
    if ($lvCalPerms.SelectedItems.Count -eq 0) { return }
    $row = $lvCalPerms.SelectedItems[0].Tag
    if (-not $row.IsSystem) { Set-ControlText $txtCalGrantUser $row.User; Set-ControlText $txtCalRemoveUser $row.User }
    $idx = $cboCalLevel.Items.IndexOf($row.AccessRights.Trim())
    if ($idx -ge 0) { $cboCalLevel.SelectedIndex = $idx }
})

$btnRefreshCal.Add_Click({ if (Test-ExoReady) { Update-CalendarView } })

$btnCalGrant.Add_Click({
    if (-not (Test-ExoReady)) { return }
    $smtp = Get-LoadedMailboxSmtp; if (-not $smtp) { return }
    $user = Get-ControlText $txtCalGrantUser
    if (-not $user) { Write-ToolLog "Calendar: Enter a user to grant/update." -Level Warning; return }
    try { Grant-CalendarPermission -Mailbox $smtp -User $user -AccessRights $cboCalLevel.SelectedItem | Out-Null; Update-CalendarView }
    catch { Write-ToolLog "Calendar ERROR (grant): $($_.Exception.Message)" -Level Error }
})

$btnCalRemove.Add_Click({
    if (-not (Test-ExoReady)) { return }
    $smtp = Get-LoadedMailboxSmtp; if (-not $smtp) { return }
    $user = Get-ControlText $txtCalRemoveUser
    if (-not $user) { Write-ToolLog "Calendar: Enter a user to remove." -Level Warning; return }
    if (-not (Confirm-Action "Remove calendar permission for '$user' on '$smtp'?" "Confirm Remove")) { return }
    try {
        Revoke-CalendarPermission -Mailbox $smtp -User $user
        Set-ControlText $txtCalRemoveUser ''; Set-ControlText $txtCalGrantUser ''
        Update-CalendarView
    }
    catch { Write-ToolLog "Calendar ERROR (remove): $($_.Exception.Message)" -Level Error }
})

$btnSetOOO.Add_Click({
    if (-not (Test-ExoReady)) { return }
    $smtp = Get-LoadedMailboxSmtp; if (-not $smtp) { return }
    try { Set-MailboxAutoReply -Mailbox $smtp -Enabled ($cboOOOState.SelectedItem -eq 'Enabled') -InternalMessage $txtOOOInternal.Text -ExternalMessage $txtOOOExternal.Text }
    catch { Write-ToolLog "Auto-Reply ERROR: $($_.Exception.Message)" -Level Error }
})

# ---- Aliases ------------------------------------------------------------------

$btnAliasSearch.Add_Click({
    if (-not (Test-ExoReady)) { return }
    $term = Get-ControlText $txtAliasSearch
    if (-not $term) { Write-ToolLog "Alias Search: Enter a search term first." -Level Warning; return }
    try {
        $rows = Find-RecipientByAddress -Term $term -Partial $chkAliasPartial.Checked
        Set-ListViewRows -ListView $lvAliasResults -Rows $rows -Properties DisplayName,PrimarySmtp,Type,MatchedAddress
    } catch { Write-ToolLog "Alias Search ERROR: $($_.Exception.Message)" -Level Error }
})

$txtAliasSearch.Add_KeyDown({
    if ($args[1].KeyCode -eq [System.Windows.Forms.Keys]::Return) {
        $btnAliasSearch.PerformClick(); $args[1].Handled = $true; $args[1].SuppressKeyPress = $true
    }
})

$lvAliasResults.Add_DoubleClick({
    if ($lvAliasResults.SelectedItems.Count -eq 0) { return }
    $smtp = $lvAliasResults.SelectedItems[0].Tag.PrimarySmtp
    if ($smtp -and (Set-MailboxUiContext $smtp)) { $tabs.SelectedTab = $tabMbxPerms }
})

$btnAddAlias.Add_Click({
    if (-not (Test-ExoReady)) { return }
    $smtp = Get-LoadedMailboxSmtp; if (-not $smtp) { return }
    $alias = Get-ControlText $txtAddAlias
    if (-not $alias) { Write-ToolLog "Aliases: Enter an alias address to add." -Level Warning; return }
    try { Add-MailboxAlias -Mailbox $smtp -Alias $alias; Set-ControlText $txtAddAlias ''; Update-AliasView }
    catch { Write-ToolLog "Aliases ERROR (add): $($_.Exception.Message)" -Level Error }
})

$btnRemoveAlias.Add_Click({
    if (-not (Test-ExoReady)) { return }
    $smtp = Get-LoadedMailboxSmtp; if (-not $smtp) { return }
    if ($lvAliases.SelectedItems.Count -eq 0) { Write-ToolLog "Aliases: Select an alias to remove." -Level Warning; return }
    $row = $lvAliases.SelectedItems[0].Tag
    if ($row.IsPrimary) { Write-ToolLog "Aliases: Cannot remove the Primary SMTP address." -Level Warning; return }
    if (-not (Confirm-Action "Remove alias '$($row.Address)' from '$smtp'?" "Confirm Remove Alias")) { return }
    try { Remove-MailboxAlias -Mailbox $smtp -Alias $row.Address; Update-AliasView }
    catch { Write-ToolLog "Aliases ERROR (remove): $($_.Exception.Message)" -Level Error }
})

# ================================================================================
# Event handlers - Compliance Search (Timer-driven polling, no DoEvents)
# ================================================================================

$cmbScope.Add_SelectedIndexChanged({
    $txtMailbox.Enabled = ($cmbScope.SelectedItem -eq "Specific Mailbox")
    if (-not $txtMailbox.Enabled) { $txtMailbox.Text = "" }
})

function Set-SearchButtonsEnabled { param([bool]$Enabled) $btnRunSearch.Enabled = $Enabled; $btnPurge.Enabled = $Enabled; $btnClearSpam.Enabled = $Enabled }

$timerSearch = New-Object System.Windows.Forms.Timer
$timerSearch.Interval = $Config.SearchPollSeconds * 1000
$timerSearch.Add_Tick({
    try {
        $st = Get-SpamComplianceSearchStatus -Name $State.PendingSearchName
        Write-ToolLog "Search status: $($st.Status)"
        if (-not $st.IsFinished) { return }
        $timerSearch.Stop()
        Set-SearchButtonsEnabled $true
        if (Complete-SpamComplianceSearch -Status $st) {
            $txtSearchName.Text = $State.LastSearchName
            $txtItemCount.Text  = $State.LastSearchItems.ToString()
            Show-Info "Search complete.`n`nSearch Name: $($State.LastSearchName)`nItems: $($State.LastSearchItems)" "Search Complete"
        } else {
            Show-Error "Compliance search failed. Check Purview / Compliance Center for more detail." "Search Failed"
        }
    }
    catch {
        $timerSearch.Stop()
        Set-SearchButtonsEnabled $true
        $failed = [PSCustomObject]@{ Name = $State.PendingSearchName; Status = 'Failed'; Items = 0; IsFinished = $true }
        Complete-SpamComplianceSearch -Status $failed | Out-Null
        Write-ToolLog "Search polling error: $($_.Exception.Message)" -Level Error
        Show-Error $_.Exception.Message "Search Error"
    }
})

$btnRunSearch.Add_Click({
    if (-not (Test-SearchReady)) { return }
    try {
        $start = if ($dtpStart.Checked) { $dtpStart.Value } else { $null }
        $end   = if ($dtpEnd.Checked)   { $dtpEnd.Value }   else { $null }
        $query = New-SpamComplianceQuery -From $txtFrom.Text -Subject $txtSubject.Text -Recipient $txtRecipient.Text -StartDate $start -EndDate $end
        $location = 'All'
        if ($cmbScope.SelectedItem -eq "Specific Mailbox") {
            if ([string]::IsNullOrWhiteSpace($txtMailbox.Text)) { throw "Mailbox is required when scope is 'Specific Mailbox'." }
            $location = $txtMailbox.Text.Trim()
        }
        if ((Test-BroadComplianceQuery $query) -and -not (Confirm-Action "Your query is extremely broad and may return a huge number of items.`n`nContinue anyway?" "Broad Search Warning")) {
            Write-ToolLog "Search canceled due to broad query."; return
        }
        if (Start-SpamComplianceSearch -Query $query -ExchangeLocation $location) {
            Set-SearchButtonsEnabled $false
            $timerSearch.Start()
        }
    }
    catch {
        Write-ToolLog "Search error: $($_.Exception.Message)" -Level Error
        Show-Error $_.Exception.Message "Search Error"
    }
})

$btnPurge.Add_Click({
    if (-not (Test-PurgeReady)) { return }
    $text = "You are about to SOFT DELETE messages for:`n`nSearch Name: $($State.LastSearchName)`nItem Count: $($State.LastSearchItems)`n`nThis will move them into Recoverable Items.`n`nContinue?"
    if (-not (Confirm-Action $text "Confirm Purge")) { Write-ToolLog "Purge canceled by user."; return }
    try {
        if (Invoke-CompliancePurge) { Show-Info "Purge submitted.`n`nMonitor in Microsoft Purview / Compliance Center." "Purge Submitted" }
    }
    catch {
        Write-ToolLog "Purge error: $($_.Exception.Message)" -Level Error
        Show-Error $_.Exception.Message "Purge Error"
    }
})

$btnClearSpam.Add_Click({
    $txtFrom.Text = ""; $txtSubject.Text = ""; $txtRecipient.Text = ""; $txtMailbox.Text = ""
    $cmbScope.SelectedIndex = 0
    $dtpStart.Value = (Get-Date).Date.AddDays(-3); $dtpStart.Checked = $true
    $dtpEnd.Value   = (Get-Date).Date;             $dtpEnd.Checked   = $true
    $txtSearchName.Text = ""; $txtItemCount.Text = ""
    Reset-SpamComplianceSearch
    Write-ToolLog "Fields cleared."
})

# ================================================================================
# Event handlers - Message Trace
# ================================================================================

$lvMfResults.Add_SelectedIndexChanged({ $lvMfDetail.Items.Clear(); $lvMfActivity.Items.Clear(); $lvMfRules.Items.Clear() })

function Get-SelectedTraceRow {
    if ($lvMfResults.SelectedItems.Count -eq 0) { Write-ToolLog "Mail Flow: select a message first." -Level Warning; return $null }
    return $lvMfResults.SelectedItems[0].Tag
}

$btnMfSearch.Add_Click({
    if (-not (Test-ExoReady)) { return }
    try {
        Write-ToolLog "Mail Flow: searching..."
        $rows = Get-MessageTraceReport -Sender $txtMfSender.Text -Recipient $txtMfRecipient.Text -Subject $txtMfSubject.Text `
                    -StartDate $dtpMfStart.Value -EndDate $dtpMfEnd.Value -Status $cmbMfStatus.SelectedItem
        Set-ListViewRows -ListView $lvMfResults -Rows $rows -Properties Received,Sender,Recipient,Subject,Status
    }
    catch { Write-ToolLog "Mail Flow search error: $($_.Exception.Message)" -Level Error; Show-Error $_.Exception.Message "Mail Flow Search Error" }
})

$btnMfDetails.Add_Click({
    if (-not (Test-ExoReady)) { return }
    $row = Get-SelectedTraceRow; if (-not $row) { return }
    try { Set-ListViewRows -ListView $lvMfDetail -Rows (Get-MessageTraceDetailReport -TraceRow $row) -Properties Time,Event,Detail }
    catch { Write-ToolLog "Mail Flow detail error: $($_.Exception.Message)" -Level Error; Show-Error $_.Exception.Message "Transport Detail Error" }
})

$btnMfMailboxActivity.Add_Click({
    if (-not (Test-ExoReady)) { return }
    $row = Get-SelectedTraceRow; if (-not $row) { return }
    try { Set-ListViewRows -ListView $lvMfActivity -Rows (Get-MailboxActivityReport -TraceRow $row) -Properties Time,Operation,Folder,Details }
    catch { Write-ToolLog "Mail Flow mailbox activity error: $($_.Exception.Message)" -Level Error; Show-Error $_.Exception.Message "Mailbox Activity Error" }
})

$btnMfInboxRules.Add_Click({
    if (-not (Test-ExoReady)) { return }
    $row = Get-SelectedTraceRow; if (-not $row) { return }
    try { Set-ListViewRows -ListView $lvMfRules -Rows (Get-InboxRuleReport -Mailbox $row.Recipient) -Properties Name,Enabled,Priority,Conditions,Actions }
    catch { Write-ToolLog "Mail Flow inbox rules error: $($_.Exception.Message)" -Level Error; Show-Error $_.Exception.Message "Inbox Rules Error" }
})

# ================================================================================
# Event handlers - Recurring Events
# ================================================================================

$invalidateRecurring = { $btnRecCancel.Enabled = $false; $State.RecurringPreview = $null }
$txtRecMbx.Add_TextChanged($invalidateRecurring)
$dtpRecStart.Add_ValueChanged($invalidateRecurring)
$nudRecWindow.Add_ValueChanged($invalidateRecurring)
$chkRecCustomRouting.Add_CheckedChanged($invalidateRecurring)
$chkRecSingleAttendee.Add_CheckedChanged($invalidateRecurring)

$btnRecSearch.Add_Click({
    $lvRecEvents.Items.Clear(); $btnRecCancel.Enabled = $false
    if (-not (Test-ExoReady)) { return }
    $mailbox = Get-ControlText $txtRecMbx
    if (-not $mailbox) { Write-ToolLog "Recurring Events: Enter a mailbox first." -Level Warning; return }
    if ($chkRecSingleAttendee.Checked -and -not (Test-GraphReady)) {
        if (-not (Confirm-Action "Graph is not connected, so the attendee filter will be skipped and ALL organized meetings will be shown.`n`nContinue?" "Graph Not Connected")) { return }
    }
    try {
        $lblRecStatus.Text = "Searching..."; $lblRecStatus.ForeColor = $script:UI.DimGray
        $p = Get-RecurringMeetingPreview -Mailbox $mailbox -StartDate $dtpRecStart.Value -WindowDays ([int]$nudRecWindow.Value) `
                -UseCustomRouting:$chkRecCustomRouting.Checked -FilterSingleAttendee:$chkRecSingleAttendee.Checked
        Set-ListViewRows -ListView $lvRecEvents -Rows $p.Meetings -Properties Subject,StartDate
        if ($p.Meetings.Count -gt 0) {
            $btnRecCancel.Enabled = $true
            $lblRecStatus.Text = "$($p.Meetings.Count) meeting(s) found."; $lblRecStatus.ForeColor = $script:UI.Green
        } else {
            $lblRecStatus.Text = "No matching meetings found."; $lblRecStatus.ForeColor = $script:UI.DimGray
        }
    }
    catch {
        $lblRecStatus.Text = "Search failed."; $lblRecStatus.ForeColor = $script:UI.Red
        Write-ToolLog "Recurring Events ERROR (search): $($_.Exception.Message)" -Level Error
    }
})

$btnRecCancel.Add_Click({
    if (-not (Test-ExoReady)) { return }
    $warning = Get-RecurringCancelWarning
    if (-not $warning) { Write-ToolLog "Recurring Events: Run Search first." -Level Warning; return }
    if (-not (Confirm-Action $warning "Confirm Cancel Meetings")) { return }
    try {
        $count = Remove-RecurringMeetings
        Show-Info "$count meeting(s) cancelled on $(Get-ControlText $txtRecMbx)."
        $lvRecEvents.Items.Clear(); $btnRecCancel.Enabled = $false
        $lblRecStatus.Text = "Cancellation complete."; $lblRecStatus.ForeColor = $script:UI.Green
    }
    catch { Write-ToolLog "Recurring Events ERROR (cancel): $($_.Exception.Message)" -Level Error }
})

# ================================================================================
# Assemble + launch
# ================================================================================

[void]$tabs.TabPages.Add($tabMbxPerms)
[void]$tabs.TabPages.Add($tabAliasSearch)
[void]$tabs.TabPages.Add($tabMailbox)
[void]$tabs.TabPages.Add($tabOOO)
[void]$tabs.TabPages.Add($tabEmailInv)
[void]$tabs.TabPages.Add($tabRecurring)

$form.Add_Shown({
    Update-ConnectionLabels
    Write-ToolLog "O365 Admin Tools ready. Log file: $(Get-ToolLogPath)"
    Write-ToolLog "Use the Connect buttons below to connect to Exchange Online, IPPS, and (optionally) Graph."
})
$form.Add_FormClosing({
    $timerSearch.Stop(); $timerProvision.Stop()
    Write-ToolLog "Session ended."
})

[void]$form.ShowDialog()

#requires -Modules ExchangeOnlineManagement
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ================================================================================
# Helper Functions
# ================================================================================

function Test-MailAlias {
    param([string]$Alias)
    if ([string]::IsNullOrWhiteSpace($Alias)) { return $false }
    if ($Alias -match '[@\s]') { return $false }
    return $Alias -match '^[A-Za-z0-9][A-Za-z0-9\!\#\$\%\&''\*\+\-\/=\?\^_`\{\|\}~\.]*[A-Za-z0-9]$' -or $Alias.Length -eq 1
}

function Split-Entries {
    param([string]$Text)
    $raw = ($Text -split "(`r`n|`n|,|;)" | ForEach-Object { $_.Trim() }) | Where-Object { $_ }
    return $raw | Select-Object -Unique
}

function Write-Log {
    param($tb, [string]$msg)
    $tb.AppendText("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg`r`n")
    $tb.SelectionStart = $tb.TextLength
    $tb.ScrollToCaret()
}

function Get-RecipientSafe {
    param([string]$Identity)
    try { return Get-Recipient -Identity $Identity -ErrorAction Stop }
    catch { return $null }
}

function Get-CalendarIdentity {
    <#
    .SYNOPSIS
    Returns the mailbox folder path for the calendar (e.g. "user@domain.com:\Calendar").
    Falls back to folder statistics for non-English tenants where the folder name differs.
    #>
    param([string]$Mailbox)
    $defaultPath = "${Mailbox}:\Calendar"
    try {
        # Quick check — if this works we're done
        Get-MailboxFolderPermission -Identity $defaultPath -ErrorAction Stop | Out-Null
        return $defaultPath
    }
    catch {
        try {
            $calFolder = Get-MailboxFolderStatistics -Identity $Mailbox -FolderScope Calendar -ErrorAction Stop |
                         Where-Object { $_.FolderType -eq 'Calendar' } |
                         Select-Object -First 1
            if ($calFolder) {
                $fp = $calFolder.FolderPath.TrimStart('/').Replace('/', '\')
                return "${Mailbox}:\${fp}"
            }
        }
        catch { }
        return $defaultPath   # Let the caller surface the real error
    }
}

# ================================================================================
# Form
# ================================================================================

$form                = New-Object System.Windows.Forms.Form
$form.Text           = "O365 Admin Tools"
$form.Size           = New-Object System.Drawing.Size(960, 730)
$form.StartPosition  = "CenterScreen"
$form.MinimumSize    = New-Object System.Drawing.Size(960, 730)

$font     = New-Object System.Drawing.Font("Segoe UI", 10)
$fontBold = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)

# ── Shared: TabControl ───────────────────────────────────────────────────────────
$tabs          = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(10, 10)
$tabs.Size     = New-Object System.Drawing.Size(932, 558)
$tabs.Font     = $font
$form.Controls.Add($tabs)

# ── Shared: Connect button + status label ────────────────────────────────────────
$btnConnect          = New-Object System.Windows.Forms.Button
$btnConnect.Text     = "Connect to EXO"
$btnConnect.Location = New-Object System.Drawing.Point(20, 578)
$btnConnect.Size     = New-Object System.Drawing.Size(155, 35)
$btnConnect.Font     = $font
$form.Controls.Add($btnConnect)

$lblConnStatus           = New-Object System.Windows.Forms.Label
$lblConnStatus.Text      = "Not connected"
$lblConnStatus.Location  = New-Object System.Drawing.Point(185, 588)
$lblConnStatus.AutoSize  = $true
$lblConnStatus.ForeColor = [System.Drawing.Color]::Gray
$lblConnStatus.Font      = $font
$form.Controls.Add($lblConnStatus)

# ── Shared: Log box ──────────────────────────────────────────────────────────────
$txtLog          = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(20, 623)
$txtLog.Size     = New-Object System.Drawing.Size(915, 82)
$txtLog.Multiline  = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly   = $true
$txtLog.Font       = $font
$form.Controls.Add($txtLog)

# ================================================================================
# TAB 1 — Shared Mailbox  (original functionality, adapted for tab layout)
# ================================================================================

$tabMailbox      = New-Object System.Windows.Forms.TabPage
$tabMailbox.Text = "Shared Mailbox"
$tabs.TabPages.Add($tabMailbox)

# Display Name
$lblDisplay          = New-Object System.Windows.Forms.Label
$lblDisplay.Text     = "Display Name:"
$lblDisplay.Location = New-Object System.Drawing.Point(20, 22)
$lblDisplay.AutoSize = $true
$tabMailbox.Controls.Add($lblDisplay)

$txtDisplay          = New-Object System.Windows.Forms.TextBox
$txtDisplay.Location = New-Object System.Drawing.Point(155, 20)
$txtDisplay.Size     = New-Object System.Drawing.Size(310, 25)
$txtDisplay.Font     = $font
$tabMailbox.Controls.Add($txtDisplay)

# Alias
$lblAlias          = New-Object System.Windows.Forms.Label
$lblAlias.Text     = "Alias (no @):"
$lblAlias.Location = New-Object System.Drawing.Point(20, 62)
$lblAlias.AutoSize = $true
$tabMailbox.Controls.Add($lblAlias)

$txtAlias          = New-Object System.Windows.Forms.TextBox
$txtAlias.Location = New-Object System.Drawing.Point(155, 60)
$txtAlias.Size     = New-Object System.Drawing.Size(310, 25)
$txtAlias.Font     = $font
$tabMailbox.Controls.Add($txtAlias)

# Primary SMTP
$lblSmtp                  = New-Object System.Windows.Forms.Label
$lblSmtp.Text             = "Primary SMTP:"
$lblSmtp.Location         = New-Object System.Drawing.Point(20, 102)
$lblSmtp.AutoSize         = $true
$tabMailbox.Controls.Add($lblSmtp)

$txtSmtp                  = New-Object System.Windows.Forms.TextBox
$txtSmtp.Location         = New-Object System.Drawing.Point(155, 100)
$txtSmtp.Size             = New-Object System.Drawing.Size(310, 25)
$txtSmtp.Font             = $font
$txtSmtp.PlaceholderText  = "e.g. alias@provenit.com"
$tabMailbox.Controls.Add($txtSmtp)

# Full Access
$lblFull          = New-Object System.Windows.Forms.Label
$lblFull.Text     = "Full Access (one per line):"
$lblFull.Location = New-Object System.Drawing.Point(20, 148)
$lblFull.AutoSize = $true
$tabMailbox.Controls.Add($lblFull)

$txtFull            = New-Object System.Windows.Forms.TextBox
$txtFull.Location   = New-Object System.Drawing.Point(20, 170)
$txtFull.Size       = New-Object System.Drawing.Size(450, 110)
$txtFull.Multiline  = $true
$txtFull.ScrollBars = "Vertical"
$txtFull.Font       = $font
$tabMailbox.Controls.Add($txtFull)

# Send As
$lblSendAs          = New-Object System.Windows.Forms.Label
$lblSendAs.Text     = "Send As (one per line):"
$lblSendAs.Location = New-Object System.Drawing.Point(20, 298)
$lblSendAs.AutoSize = $true
$tabMailbox.Controls.Add($lblSendAs)

$txtSendAs            = New-Object System.Windows.Forms.TextBox
$txtSendAs.Location   = New-Object System.Drawing.Point(20, 320)
$txtSendAs.Size       = New-Object System.Drawing.Size(450, 110)
$txtSendAs.Multiline  = $true
$txtSendAs.ScrollBars = "Vertical"
$txtSendAs.Font       = $font
$tabMailbox.Controls.Add($txtSendAs)

# Validate + Create buttons
$btnValidate          = New-Object System.Windows.Forms.Button
$btnValidate.Text     = "Validate"
$btnValidate.Location = New-Object System.Drawing.Point(20, 450)
$btnValidate.Size     = New-Object System.Drawing.Size(120, 35)
$btnValidate.Font     = $font
$tabMailbox.Controls.Add($btnValidate)

$btnCreate          = New-Object System.Windows.Forms.Button
$btnCreate.Text     = "Create Mailbox"
$btnCreate.Location = New-Object System.Drawing.Point(150, 450)
$btnCreate.Size     = New-Object System.Drawing.Size(140, 35)
$btnCreate.Font     = $font
$btnCreate.Enabled  = $false
$tabMailbox.Controls.Add($btnCreate)

# Validation ListView
$lvMailbox               = New-Object System.Windows.Forms.ListView
$lvMailbox.Location      = New-Object System.Drawing.Point(490, 20)
$lvMailbox.Size          = New-Object System.Drawing.Size(425, 465)
$lvMailbox.View          = "Details"
$lvMailbox.FullRowSelect = $true
$lvMailbox.GridLines     = $true
$lvMailbox.Font          = $font
[void]$lvMailbox.Columns.Add("Type",      100)
[void]$lvMailbox.Columns.Add("Identity",  220)
[void]$lvMailbox.Columns.Add("Status",     85)
$tabMailbox.Controls.Add($lvMailbox)

# ================================================================================
# TAB 2 — Calendar Permissions
# ================================================================================

$tabCal      = New-Object System.Windows.Forms.TabPage
$tabCal.Text = "Calendar Permissions"
$tabs.TabPages.Add($tabCal)

# ── Calendar owner field + Load button ──────────────────────────────────────────
$lblCalOwner          = New-Object System.Windows.Forms.Label
$lblCalOwner.Text     = "Calendar Owner:"
$lblCalOwner.Location = New-Object System.Drawing.Point(20, 24)
$lblCalOwner.AutoSize = $true
$lblCalOwner.Font     = $font
$tabCal.Controls.Add($lblCalOwner)

$txtCalOwner                 = New-Object System.Windows.Forms.TextBox
$txtCalOwner.Location        = New-Object System.Drawing.Point(140, 22)
$txtCalOwner.Size            = New-Object System.Drawing.Size(390, 25)
$txtCalOwner.Font            = $font
$txtCalOwner.PlaceholderText = "e.g. john@provenit.com"
$tabCal.Controls.Add($txtCalOwner)

$btnLoadPerms          = New-Object System.Windows.Forms.Button
$btnLoadPerms.Text     = "Load Permissions"
$btnLoadPerms.Location = New-Object System.Drawing.Point(545, 20)
$btnLoadPerms.Size     = New-Object System.Drawing.Size(155, 30)
$btnLoadPerms.Font     = $font
$tabCal.Controls.Add($btnLoadPerms)

# ── Current permissions label + ListView ─────────────────────────────────────────
$lblCurrentPerms          = New-Object System.Windows.Forms.Label
$lblCurrentPerms.Text     = "Current Calendar Permissions:"
$lblCurrentPerms.Location = New-Object System.Drawing.Point(20, 64)
$lblCurrentPerms.AutoSize = $true
$lblCurrentPerms.Font     = $fontBold
$tabCal.Controls.Add($lblCurrentPerms)

$lvCalPerms               = New-Object System.Windows.Forms.ListView
$lvCalPerms.Location      = New-Object System.Drawing.Point(20, 86)
$lvCalPerms.Size          = New-Object System.Drawing.Size(895, 200)
$lvCalPerms.View          = "Details"
$lvCalPerms.FullRowSelect = $true
$lvCalPerms.GridLines     = $true
$lvCalPerms.Font          = $font
[void]$lvCalPerms.Columns.Add("User",          320)
[void]$lvCalPerms.Columns.Add("Access Rights", 220)
[void]$lvCalPerms.Columns.Add("Is Inherited",  130)
$tabCal.Controls.Add($lvCalPerms)

# ── Grant / Update GroupBox ──────────────────────────────────────────────────────
$grpGrant          = New-Object System.Windows.Forms.GroupBox
$grpGrant.Text     = "Grant / Update Permission"
$grpGrant.Location = New-Object System.Drawing.Point(20, 300)
$grpGrant.Size     = New-Object System.Drawing.Size(895, 82)
$grpGrant.Font     = $fontBold
$tabCal.Controls.Add($grpGrant)

$lblGrantUser          = New-Object System.Windows.Forms.Label
$lblGrantUser.Text     = "User:"
$lblGrantUser.Location = New-Object System.Drawing.Point(12, 32)
$lblGrantUser.AutoSize = $true
$lblGrantUser.Font     = $font
$grpGrant.Controls.Add($lblGrantUser)

$txtGrantUser                 = New-Object System.Windows.Forms.TextBox
$txtGrantUser.Location        = New-Object System.Drawing.Point(55, 30)
$txtGrantUser.Size            = New-Object System.Drawing.Size(330, 25)
$txtGrantUser.Font            = $font
$txtGrantUser.PlaceholderText = "user@domain.com"
$grpGrant.Controls.Add($txtGrantUser)

$lblGrantLevel          = New-Object System.Windows.Forms.Label
$lblGrantLevel.Text     = "Permission:"
$lblGrantLevel.Location = New-Object System.Drawing.Point(400, 32)
$lblGrantLevel.AutoSize = $true
$lblGrantLevel.Font     = $font
$grpGrant.Controls.Add($lblGrantLevel)

$cboGrantLevel              = New-Object System.Windows.Forms.ComboBox
$cboGrantLevel.Location     = New-Object System.Drawing.Point(480, 29)
$cboGrantLevel.Size         = New-Object System.Drawing.Size(195, 25)
$cboGrantLevel.Font         = $font
$cboGrantLevel.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
@('Owner','PublishingEditor','Editor','PublishingAuthor','Author',
  'NonEditingAuthor','Reviewer','AvailabilityOnly','LimitedDetails') |
    ForEach-Object { [void]$cboGrantLevel.Items.Add($_) }
$cboGrantLevel.SelectedIndex = 6   # Default: Reviewer
$grpGrant.Controls.Add($cboGrantLevel)

$btnGrant          = New-Object System.Windows.Forms.Button
$btnGrant.Text     = "Grant / Update"
$btnGrant.Location = New-Object System.Drawing.Point(695, 27)
$btnGrant.Size     = New-Object System.Drawing.Size(145, 35)
$btnGrant.Font     = $font
$grpGrant.Controls.Add($btnGrant)

# ── Remove GroupBox ──────────────────────────────────────────────────────────────
$grpRemove          = New-Object System.Windows.Forms.GroupBox
$grpRemove.Text     = "Remove Permission"
$grpRemove.Location = New-Object System.Drawing.Point(20, 396)
$grpRemove.Size     = New-Object System.Drawing.Size(895, 78)
$grpRemove.Font     = $fontBold
$tabCal.Controls.Add($grpRemove)

$lblRemoveUser          = New-Object System.Windows.Forms.Label
$lblRemoveUser.Text     = "User:"
$lblRemoveUser.Location = New-Object System.Drawing.Point(12, 32)
$lblRemoveUser.AutoSize = $true
$lblRemoveUser.Font     = $font
$grpRemove.Controls.Add($lblRemoveUser)

$txtRemoveUser                 = New-Object System.Windows.Forms.TextBox
$txtRemoveUser.Location        = New-Object System.Drawing.Point(55, 30)
$txtRemoveUser.Size            = New-Object System.Drawing.Size(330, 25)
$txtRemoveUser.Font            = $font
$txtRemoveUser.PlaceholderText = "user@domain.com"
$grpRemove.Controls.Add($txtRemoveUser)

$lblRemoveHint           = New-Object System.Windows.Forms.Label
$lblRemoveHint.Text      = "Tip: click a row in the list above to auto-fill both user fields."
$lblRemoveHint.Location  = New-Object System.Drawing.Point(400, 34)
$lblRemoveHint.AutoSize  = $true
$lblRemoveHint.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
$lblRemoveHint.ForeColor = [System.Drawing.Color]::DimGray
$grpRemove.Controls.Add($lblRemoveHint)

$btnRemove          = New-Object System.Windows.Forms.Button
$btnRemove.Text     = "Remove"
$btnRemove.Location = New-Object System.Drawing.Point(695, 27)
$btnRemove.Size     = New-Object System.Drawing.Size(145, 35)
$btnRemove.Font     = $font
$grpRemove.Controls.Add($btnRemove)

# ================================================================================
# State
# ================================================================================

$script:validated   = $false
$script:validFull   = @()
$script:validSendAs = @()

# ================================================================================
# Event Handlers — Connect (shared)
# ================================================================================

$btnConnect.Add_Click({
    try {
        Write-Log $txtLog "Connecting to Exchange Online..."
        Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop | Out-Null
        Write-Log $txtLog "Connected successfully."
        $lblConnStatus.Text      = "Connected"
        $lblConnStatus.ForeColor = [System.Drawing.Color]::Green
    }
    catch {
        Write-Log $txtLog "CONNECT FAILED: $($_.Exception.Message)"
        $lblConnStatus.Text      = "Connection failed"
        $lblConnStatus.ForeColor = [System.Drawing.Color]::Red
    }
})

# ================================================================================
# Event Handlers — Shared Mailbox tab
# ================================================================================

$btnValidate.Add_Click({
    $lvMailbox.Items.Clear()
    $script:validated   = $false
    $script:validFull   = @()
    $script:validSendAs = @()
    $btnCreate.Enabled  = $false

    $display = $txtDisplay.Text.Trim()
    $alias   = $txtAlias.Text.Trim()
    $smtp    = $txtSmtp.Text.Trim()
    $ok      = $true

    if ([string]::IsNullOrWhiteSpace($display)) {
        Write-Log $txtLog "Display Name is required."
        $ok = $false
    }

    if (-not (Test-MailAlias -Alias $alias)) {
        Write-Log $txtLog "Alias is invalid - use alphanumeric only, no @ symbol."
        $ok = $false
    }

    if (-not [string]::IsNullOrWhiteSpace($smtp)) {
        if ($smtp -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            Write-Log $txtLog "Primary SMTP doesn't look like a valid email address."
            $ok = $false
        }
    }

    foreach ($u in (Split-Entries $txtFull.Text)) {
        $r    = Get-RecipientSafe $u
        $item = New-Object System.Windows.Forms.ListViewItem("FullAccess")
        [void]$item.SubItems.Add($u)
        if ($null -ne $r) {
            [void]$item.SubItems.Add("OK")
            $script:validFull += $r.PrimarySmtpAddress.ToString()
        }
        else {
            [void]$item.SubItems.Add("NOT FOUND")
            $item.ForeColor = [System.Drawing.Color]::Red
            $ok = $false
        }
        [void]$lvMailbox.Items.Add($item)
    }

    foreach ($u in (Split-Entries $txtSendAs.Text)) {
        $r    = Get-RecipientSafe $u
        $item = New-Object System.Windows.Forms.ListViewItem("SendAs")
        [void]$item.SubItems.Add($u)
        if ($null -ne $r) {
            [void]$item.SubItems.Add("OK")
            $script:validSendAs += $r.PrimarySmtpAddress.ToString()
        }
        else {
            [void]$item.SubItems.Add("NOT FOUND")
            $item.ForeColor = [System.Drawing.Color]::Red
            $ok = $false
        }
        [void]$lvMailbox.Items.Add($item)
    }

    if ($ok) {
        $script:validated  = $true
        $btnCreate.Enabled = $true
        Write-Log $txtLog "Validation passed - click Create Mailbox to proceed."
    }
    else {
        Write-Log $txtLog "Validation failed. Fix NOT FOUND items and validate again."
    }
})

$btnCreate.Add_Click({
    if (-not $script:validated) { Write-Log $txtLog "Please run Validate first."; return }

    $display = $txtDisplay.Text.Trim()
    $alias   = $txtAlias.Text.Trim()
    $smtp    = $txtSmtp.Text.Trim()

    try {
        Write-Log $txtLog "Creating shared mailbox: DisplayName='$display'  Alias='$alias'  SMTP='$smtp'"

        $params = @{
            Shared      = $true
            Name        = $display
            DisplayName = $display
            Alias       = $alias
            ErrorAction = 'Stop'
        }
        if (-not [string]::IsNullOrWhiteSpace($smtp)) { $params.PrimarySmtpAddress = $smtp }

        New-Mailbox @params | Out-Null
        Write-Log $txtLog "Mailbox creation submitted - waiting for EXO propagation..."

        $idToFind = if ($smtp) { $smtp } else { $alias }
        $mbx = $null
        for ($i = 1; $i -le 12; $i++) {
            Start-Sleep -Seconds 5
            $mbx = Get-Mailbox -Identity $idToFind -ErrorAction SilentlyContinue
            if ($mbx) { break }
            Write-Log $txtLog "  Waiting... attempt $i/12"
        }
        if (-not $mbx) {
            throw "Mailbox not found after waiting. Permissions can be applied manually once it appears."
        }

        $mailboxId = $mbx.PrimarySmtpAddress.ToString()
        Write-Log $txtLog "Mailbox confirmed: $mailboxId"

        foreach ($u in $script:validFull) {
            Write-Log $txtLog "  FullAccess  → $u"
            Add-MailboxPermission -Identity $mailboxId -User $u `
                -AccessRights FullAccess -InheritanceType All -AutoMapping:$true `
                -ErrorAction Stop | Out-Null
        }

        foreach ($u in $script:validSendAs) {
            Write-Log $txtLog "  SendAs      → $u"
            Add-RecipientPermission -Identity $mailboxId -Trustee $u `
                -AccessRights SendAs -Confirm:$false -ErrorAction Stop | Out-Null
        }

        Write-Log $txtLog "Done."
        [System.Windows.Forms.MessageBox]::Show(
            "Shared mailbox created and permissions applied.`r`n$mailboxId",
            "Success", "OK", "Information"
        ) | Out-Null
    }
    catch {
        Write-Log $txtLog "ERROR: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Error", "OK", "Error") | Out-Null
    }
})

# ================================================================================
# Event Handlers — Calendar Permissions tab
# ================================================================================

# Click a row → auto-fill both user fields and match the permission level
$lvCalPerms.Add_SelectedIndexChanged({
    if ($lvCalPerms.SelectedItems.Count -eq 0) { return }
    $sel  = $lvCalPerms.SelectedItems[0]
    $user = $sel.Text
    # Skip system entries — they can be updated but not removed
    if ($user -notin @('Default', 'Anonymous')) {
        $txtGrantUser.Text  = $user
        $txtRemoveUser.Text = $user
    }
    # Match permission level in dropdown if possible
    $currentLevel = $sel.SubItems[1].Text.Trim()
    $idx = $cboGrantLevel.Items.IndexOf($currentLevel)
    if ($idx -ge 0) { $cboGrantLevel.SelectedIndex = $idx }
})

$btnLoadPerms.Add_Click({
    $mailbox = $txtCalOwner.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($mailbox)) {
        Write-Log $txtLog "Calendar: Enter a mailbox address first."
        return
    }

    $lvCalPerms.Items.Clear()

    try {
        Write-Log $txtLog "Calendar: Loading permissions for $mailbox ..."
        $calPath = Get-CalendarIdentity -Mailbox $mailbox
        $perms   = Get-MailboxFolderPermission -Identity $calPath -ErrorAction Stop

        foreach ($p in $perms) {
            $item = New-Object System.Windows.Forms.ListViewItem($p.User.ToString())
            [void]$item.SubItems.Add(($p.AccessRights -join ', '))
            [void]$item.SubItems.Add($(if ($p.IsInherited) { 'Yes' } else { 'No' }))
            # Dim system default entries
            if ($p.User.ToString() -in @('Default', 'Anonymous')) {
                $item.ForeColor = [System.Drawing.Color]::Gray
            }
            [void]$lvCalPerms.Items.Add($item)
        }

        Write-Log $txtLog "Calendar: $($perms.Count) permission entr$(if ($perms.Count -eq 1){'y'}else{'ies'}) loaded."
    }
    catch {
        Write-Log $txtLog "Calendar ERROR (load): $($_.Exception.Message)"
    }
})

$btnGrant.Add_Click({
    $mailbox = $txtCalOwner.Text.Trim()
    $user    = $txtGrantUser.Text.Trim()
    $level   = $cboGrantLevel.SelectedItem

    if ([string]::IsNullOrWhiteSpace($mailbox) -or [string]::IsNullOrWhiteSpace($user)) {
        Write-Log $txtLog "Calendar: Both Calendar Owner and User fields are required."
        return
    }

    try {
        $calPath  = Get-CalendarIdentity -Mailbox $mailbox
        $existing = Get-MailboxFolderPermission -Identity $calPath -User $user -ErrorAction SilentlyContinue

        if ($existing) {
            Write-Log $txtLog "Calendar: Updating $user → $level on $mailbox ..."
            Set-MailboxFolderPermission -Identity $calPath -User $user `
                -AccessRights $level -ErrorAction Stop | Out-Null
            Write-Log $txtLog "Calendar: Permission updated."
        }
        else {
            Write-Log $txtLog "Calendar: Granting $user → $level on $mailbox ..."
            Add-MailboxFolderPermission -Identity $calPath -User $user `
                -AccessRights $level -ErrorAction Stop | Out-Null
            Write-Log $txtLog "Calendar: Permission granted."
        }

        $btnLoadPerms.PerformClick()   # Refresh the list
    }
    catch {
        Write-Log $txtLog "Calendar ERROR (grant): $($_.Exception.Message)"
    }
})

$btnRemove.Add_Click({
    $mailbox = $txtCalOwner.Text.Trim()
    $user    = $txtRemoveUser.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($mailbox) -or [string]::IsNullOrWhiteSpace($user)) {
        Write-Log $txtLog "Calendar: Both Calendar Owner and User fields are required."
        return
    }

    # Prevent accidental removal of system entries
    if ($user -in @('Default', 'Anonymous')) {
        Write-Log $txtLog "Calendar: '$user' is a system entry - use Grant/Update to change its access level instead."
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Remove calendar permission for '$user' on '$mailbox'?",
        "Confirm Remove", "YesNo", "Warning"
    )
    if ($confirm -ne 'Yes') { return }

    try {
        $calPath = Get-CalendarIdentity -Mailbox $mailbox
        Write-Log $txtLog "Calendar: Removing permission for $user on $mailbox ..."
        Remove-MailboxFolderPermission -Identity $calPath -User $user `
            -Confirm:$false -ErrorAction Stop
        Write-Log $txtLog "Calendar: Permission removed."

        $txtRemoveUser.Clear()
        $txtGrantUser.Clear()
        $btnLoadPerms.PerformClick()   # Refresh the list
    }
    catch {
        Write-Log $txtLog "Calendar ERROR (remove): $($_.Exception.Message)"
    }
})

# ================================================================================
# Launch
# ================================================================================

[void]$form.ShowDialog()

#requires -Modules ExchangeOnlineManagement
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Test-MailAlias {
    param([string]$Alias)
    if ([string]::IsNullOrWhiteSpace($Alias)) { return $false }
    # Allow letters/digits and common EXO alias allowed specials (simple approximation)
    # Disallow @ and spaces explicitly
    if ($Alias -match '[@\s]') { return $false }
    return $Alias -match '^[A-Za-z0-9][A-Za-z0-9\!\#\$\%\&''\*\+\-\/=\?\^_`\{\|\}~\.]*[A-Za-z0-9]$' -or $Alias.Length -eq 1
}

function Split-Entries {
    param([string]$Text)
    # one per line; also tolerate commas/semicolons
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
    try {
        return Get-Recipient -Identity $Identity -ErrorAction Stop
    } catch {
        return $null
    }
}

# --- Build Form ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Create Shared Mailbox (EXO) + Permissions"
$form.Size = New-Object System.Drawing.Size(900, 650)
$form.StartPosition = "CenterScreen"

$font = New-Object System.Drawing.Font("Segoe UI", 10)

# Left labels/inputs
$lblDisplay = New-Object System.Windows.Forms.Label
$lblDisplay.Text = "Display Name:"
$lblDisplay.Location = New-Object System.Drawing.Point(20,20)
$lblDisplay.AutoSize = $true
$form.Controls.Add($lblDisplay)

$txtDisplay = New-Object System.Windows.Forms.TextBox
$txtDisplay.Location = New-Object System.Drawing.Point(140,18)
$txtDisplay.Size = New-Object System.Drawing.Size(320,25)
$txtDisplay.Font = $font
$form.Controls.Add($txtDisplay)

$lblAlias = New-Object System.Windows.Forms.Label
$lblAlias.Text = "Alias (no @):"
$lblAlias.Location = New-Object System.Drawing.Point(20,60)
$lblAlias.AutoSize = $true
$form.Controls.Add($lblAlias)

$txtAlias = New-Object System.Windows.Forms.TextBox
$txtAlias.Location = New-Object System.Drawing.Point(140,58)
$txtAlias.Size = New-Object System.Drawing.Size(320,25)
$txtAlias.Font = $font
$form.Controls.Add($txtAlias)

$lblSmtp = New-Object System.Windows.Forms.Label
$lblSmtp.Text = "Primary SMTP:"
$lblSmtp.Location = New-Object System.Drawing.Point(20,100)
$lblSmtp.AutoSize = $true
$form.Controls.Add($lblSmtp)

$txtSmtp = New-Object System.Windows.Forms.TextBox
$txtSmtp.Location = New-Object System.Drawing.Point(140,98)
$txtSmtp.Size = New-Object System.Drawing.Size(320,25)
$txtSmtp.Font = $font
$txtSmtp.PlaceholderText = "example: alias@provenit.com"
$form.Controls.Add($txtSmtp)

$lblFull = New-Object System.Windows.Forms.Label
$lblFull.Text = "Full Access (one per line):"
$lblFull.Location = New-Object System.Drawing.Point(20,150)
$lblFull.AutoSize = $true
$form.Controls.Add($lblFull)

$txtFull = New-Object System.Windows.Forms.TextBox
$txtFull.Location = New-Object System.Drawing.Point(20,175)
$txtFull.Size = New-Object System.Drawing.Size(440,120)
$txtFull.Multiline = $true
$txtFull.ScrollBars = "Vertical"
$txtFull.Font = $font
$form.Controls.Add($txtFull)

$lblSendAs = New-Object System.Windows.Forms.Label
$lblSendAs.Text = "Send As (one per line):"
$lblSendAs.Location = New-Object System.Drawing.Point(20,310)
$lblSendAs.AutoSize = $true
$form.Controls.Add($lblSendAs)

$txtSendAs = New-Object System.Windows.Forms.TextBox
$txtSendAs.Location = New-Object System.Drawing.Point(20,335)
$txtSendAs.Size = New-Object System.Drawing.Size(440,120)
$txtSendAs.Multiline = $true
$txtSendAs.ScrollBars = "Vertical"
$txtSendAs.Font = $font
$form.Controls.Add($txtSendAs)

# Validation results list
$lv = New-Object System.Windows.Forms.ListView
$lv.Location = New-Object System.Drawing.Point(480,18)
$lv.Size = New-Object System.Drawing.Size(390,437)
$lv.View = "Details"
$lv.FullRowSelect = $true
$lv.GridLines = $true
[void]$lv.Columns.Add("Type",80)
[void]$lv.Columns.Add("Identity",200)
[void]$lv.Columns.Add("Status",90)
$form.Controls.Add($lv)

# Buttons
$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = "Connect"
$btnConnect.Location = New-Object System.Drawing.Point(20,470)
$btnConnect.Size = New-Object System.Drawing.Size(120,35)
$form.Controls.Add($btnConnect)

$btnValidate = New-Object System.Windows.Forms.Button
$btnValidate.Text = "Validate"
$btnValidate.Location = New-Object System.Drawing.Point(150,470)
$btnValidate.Size = New-Object System.Drawing.Size(120,35)
$form.Controls.Add($btnValidate)

$btnCreate = New-Object System.Windows.Forms.Button
$btnCreate.Text = "Create"
$btnCreate.Location = New-Object System.Drawing.Point(280,470)
$btnCreate.Size = New-Object System.Drawing.Size(120,35)
$btnCreate.Enabled = $false
$form.Controls.Add($btnCreate)

# Log box
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(20,520)
$txtLog.Size = New-Object System.Drawing.Size(850,90)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Font = $font
$form.Controls.Add($txtLog)

# State
$script:validated = $false
$script:validFull = @()
$script:validSendAs = @()

$btnConnect.Add_Click({
    try {
        Write-Log $txtLog "Connecting to Exchange Online..."
        Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop | Out-Null
        Write-Log $txtLog "Connected."
    } catch {
        Write-Log $txtLog "CONNECT FAILED: $($_.Exception.Message)"
    }
})

$btnValidate.Add_Click({
    $lv.Items.Clear()
    $script:validated = $false
    $script:validFull = @()
    $script:validSendAs = @()
    $btnCreate.Enabled = $false

    $display = $txtDisplay.Text.Trim()
    $alias   = $txtAlias.Text.Trim()
    $smtp    = $txtSmtp.Text.Trim()

    $ok = $true

    if ([string]::IsNullOrWhiteSpace($display)) {
        Write-Log $txtLog "Display Name is required."
        $ok = $false
    }

    if (-not (Test-MailAlias -Alias $alias)) {
        Write-Log $txtLog "Alias is invalid. Use something like CSUPEAC (NO @domain)."
        $ok = $false
    }

    if (-not [string]::IsNullOrWhiteSpace($smtp)) {
        if ($smtp -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            Write-Log $txtLog "Primary SMTP doesn't look like an email address."
            $ok = $false
        }
    }

    $fullList = Split-Entries $txtFull.Text
    foreach ($u in $fullList) {
        $r = Get-RecipientSafe $u
        $item = New-Object System.Windows.Forms.ListViewItem("FullAccess")
        [void]$item.SubItems.Add($u)
        if ($null -ne $r) {
            [void]$item.SubItems.Add("OK")
            $script:validFull += $r.PrimarySmtpAddress.ToString()
        } else {
            [void]$item.SubItems.Add("NOT FOUND")
            $ok = $false
        }
        [void]$lv.Items.Add($item)
    }

    $saList = Split-Entries $txtSendAs.Text
    foreach ($u in $saList) {
        $r = Get-RecipientSafe $u
        $item = New-Object System.Windows.Forms.ListViewItem("SendAs")
        [void]$item.SubItems.Add($u)
        if ($null -ne $r) {
            [void]$item.SubItems.Add("OK")
            $script:validSendAs += $r.PrimarySmtpAddress.ToString()
        } else {
            [void]$item.SubItems.Add("NOT FOUND")
            $ok = $false
        }
        [void]$lv.Items.Add($item)
    }

    if ($ok) {
        $script:validated = $true
        $btnCreate.Enabled = $true
        Write-Log $txtLog "Validation passed. You can click Create."
    } else {
        Write-Log $txtLog "Validation failed. Fix items marked NOT FOUND (or remove them) and Validate again."
    }
})

$btnCreate.Add_Click({
    if (-not $script:validated) {
        Write-Log $txtLog "Please Validate first."
        return
    }

    $display = $txtDisplay.Text.Trim()
    $alias   = $txtAlias.Text.Trim()
    $smtp    = $txtSmtp.Text.Trim()

    try {
        Write-Log $txtLog "Creating shared mailbox: DisplayName='$display' Alias='$alias' PrimarySMTP='$smtp'"

        $params = @{
            Shared      = $true
            Name        = $display
            DisplayName = $display
            Alias       = $alias
            ErrorAction = 'Stop'
        }
        if (-not [string]::IsNullOrWhiteSpace($smtp)) {
            $params.PrimarySmtpAddress = $smtp
        }

        New-Mailbox @params | Out-Null
        Write-Log $txtLog "Mailbox creation submitted."

        # Wait for mailbox to appear (EXO propagation)
        $idToFind = if ($smtp) { $smtp } else { $alias }
        $mbx = $null
        for ($i=1; $i -le 12; $i++) {
            Start-Sleep -Seconds 5
            $mbx = Get-Mailbox -Identity $idToFind -ErrorAction SilentlyContinue
            if ($mbx) { break }
            Write-Log $txtLog "Waiting for mailbox to appear... attempt $i/12"
        }
        if (-not $mbx) { throw "Mailbox not found after waiting. Try again in a minute and re-run permissions." }

        $mailboxId = $mbx.PrimarySmtpAddress.ToString()
        Write-Log $txtLog "Mailbox found: $mailboxId"

        # Apply Full Access
        foreach ($u in $script:validFull) {
            Write-Log $txtLog "Granting FullAccess to $u"
            Add-MailboxPermission -Identity $mailboxId -User $u -AccessRights FullAccess -InheritanceType All -AutoMapping:$true -ErrorAction Stop | Out-Null
        }

        # Apply Send As
        foreach ($u in $script:validSendAs) {
            Write-Log $txtLog "Granting SendAs to $u"
            Add-RecipientPermission -Identity $mailboxId -Trustee $u -AccessRights SendAs -Confirm:$false -ErrorAction Stop | Out-Null
        }

        Write-Log $txtLog "Done."
        [System.Windows.Forms.MessageBox]::Show("Shared mailbox created and permissions applied.`r`n$mailboxId","Success","OK","Information") | Out-Null
    }
    catch {
        Write-Log $txtLog "ERROR: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,"Error","OK","Error") | Out-Null
    }
})

[void]$form.ShowDialog()

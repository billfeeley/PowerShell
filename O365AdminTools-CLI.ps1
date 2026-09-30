#requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
    O365 Admin Tools - console front-end (cross-platform: Windows, macOS, Linux).
.DESCRIPTION
    Thin menu-driven UI over O365AdminTools.Core.psm1. All Exchange / Purview / Graph
    logic lives in the module and is shared with the WinForms GUI (O365AdminTools-GUI.ps1).
.NOTES
    pwsh -File O365AdminTools-CLI.ps1
    Works over SSH into any host with PowerShell 7 + ExchangeOnlineManagement installed.
    Log file location is printed at startup (also: Get-ToolLogPath).
#>

Import-Module (Join-Path $PSScriptRoot 'O365AdminTools.Core.psm1') -Force -ErrorAction Stop

$State  = Get-ToolState
$Config = Get-ToolConfig

# ================================================================================
# Console helpers
# ================================================================================

Register-ToolLogSink -ScriptBlock {
    param($Line, $Level, $Message)
    $color = switch ($Level) { 'Error' { 'Red' } 'Warning' { 'Yellow' } 'Success' { 'Green' } default { 'Gray' } }
    Write-Host $Line -ForegroundColor $color
}

function Write-Heading { param([string]$Text) Write-Host "`n== $Text ==" -ForegroundColor Cyan }

function Read-RequiredString {
    param([string]$Prompt)
    while ($true) {
        $val = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($val)) { return $val.Trim() }
        Write-Host "  This field is required." -ForegroundColor Yellow
    }
}

function Read-OptionalString {
    param([string]$Prompt)
    $val = Read-Host "$Prompt (Enter to skip)"
    if ([string]::IsNullOrWhiteSpace($val)) { return '' }
    return $val.Trim()
}

function Read-YesNo {
    param([string]$Prompt, [switch]$DefaultYes)
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $val = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($val)) { return $DefaultYes.IsPresent }
    return $val.Trim().ToLowerInvariant() -in @('y','yes')
}

function Read-OptionalDate {
    param([string]$Prompt, [datetime]$Default)
    $val = Read-Host "$Prompt (MM/dd/yyyy, Enter for $($Default.ToString('MM/dd/yyyy')))"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    try { return [datetime]::Parse($val) }
    catch { Write-Host "  Could not parse date, using default." -ForegroundColor Yellow; return $Default }
}

function Read-Choice {
    <#
    .SYNOPSIS
    Prints a list of options and returns the chosen value, or $null for 0/blank.
    #>
    param([string[]]$Options, [string]$Prompt = "Choose an option", [string]$Default)
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $Options[$i]) }
    $hint = if ($Default) { " (Enter for $Default)" } else { "" }
    $val = Read-Host "$Prompt$hint"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    $n = 0
    if ([int]::TryParse($val, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) { return $Options[$n - 1] }
    if ($val -in $Options) { return $val }
    return $null
}

function Show-Table {
    param($Rows, [string[]]$Properties, [string]$EmptyMessage = "  (no results)")
    $arr = @($Rows)
    if ($arr.Count -eq 0) { Write-Host $EmptyMessage -ForegroundColor DarkGray; return }
    if ($Properties) { $arr | Select-Object $Properties | Format-Table -AutoSize -Wrap | Out-Host }
    else             { $arr | Format-Table -AutoSize -Wrap | Out-Host }
}

function Show-IndexedTable {
    param($Rows, [string[]]$Properties, [string]$EmptyMessage = "  (no results)")
    $arr = @($Rows)
    if ($arr.Count -eq 0) { Write-Host $EmptyMessage -ForegroundColor DarkGray; return }
    $i = 0
    $indexed = foreach ($r in $arr) {
        $i++
        $o = [ordered]@{ '#' = $i }
        $props = if ($Properties) { $Properties } else { $r.PSObject.Properties.Name }
        foreach ($p in $props) { $o[$p] = $r.$p }
        [PSCustomObject]$o
    }
    $indexed | Format-Table -AutoSize -Wrap | Out-Host
}

function Read-IndexSelection {
    param([int]$Count, [string]$Prompt = "Enter a # (0 to cancel)")
    if ($Count -eq 0) { return -1 }
    while ($true) {
        $val = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($val)) { return -1 }
        $n = 0
        if ([int]::TryParse($val, [ref]$n)) {
            if ($n -eq 0) { return -1 }
            if ($n -ge 1 -and $n -le $Count) { return ($n - 1) }
        }
        Write-Host "  Enter 1-$Count, or 0 to cancel." -ForegroundColor Yellow
    }
}

function Show-ConnectionStatus {
    $c = { param($ok, $text) if ($ok) { Write-Host -NoNewline $text -ForegroundColor Green } else { Write-Host -NoNewline $text -ForegroundColor DarkGray } }
    Write-Host ""
    Write-Host -NoNewline "EXO: ";   & $c $State.ExoConnected   $(if ($State.ExoConnected) { "Connected" } else { "Not Connected" })
    Write-Host -NoNewline "  |  IPPS: "; & $c ($State.IppsMode -eq 'SearchOnly') $State.IppsMode
    Write-Host -NoNewline "  |  Graph: "; & $c $State.GraphConnected $(if ($State.GraphConnected) { "Connected" } else { "Not Connected" })
    Write-Host ""
}

# ================================================================================
# Feature: Create Shared Mailbox
# ================================================================================

function Invoke-CreateSharedMailboxMenu {
    if (-not (Test-ExoReady)) { return }
    Write-Heading "Create Shared Mailbox"
    $display = Read-RequiredString "Display Name"
    $alias   = Read-RequiredString "Alias (no @)"
    $smtp    = Read-OptionalString "Primary SMTP (e.g. alias@provenit.com)"
    $fullRaw = Read-OptionalString "Full Access users (comma/semicolon separated)"
    $sendRaw = Read-OptionalString "Send As users (comma/semicolon separated)"

    $v = Test-SharedMailboxRequest -DisplayName $display -Alias $alias -PrimarySmtp $smtp `
            -FullAccess (Split-Entries $fullRaw) -SendAs (Split-Entries $sendRaw)
    Show-Table $v.Rows -EmptyMessage ""
    foreach ($e in $v.Errors) { Write-ToolLog $e -Level Warning }
    if (-not $v.IsValid) { Write-ToolLog "Validation failed. Fix the items above and try again." -Level Error; return }
    Write-ToolLog "Validation passed." -Level Success
    if (-not (Read-YesNo "Create the mailbox now?")) { Write-ToolLog "Canceled."; return }

    try {
        $id  = New-SharedMailboxRequest -DisplayName $display -Alias $alias -PrimarySmtp $smtp
        $mbx = Wait-MailboxProvisioned -Identity $id
        Set-SharedMailboxPermissions -MailboxId $mbx.PrimarySmtpAddress.ToString() -FullAccess $v.ValidFull -SendAs $v.ValidSendAs
    }
    catch { Write-ToolLog "ERROR: $($_.Exception.Message)" -Level Error }
}

# ================================================================================
# Feature: Manage Mailbox
# ================================================================================

function Invoke-LoadMailboxPrompt {
    $identity = Read-RequiredString "Mailbox (alias, UPN, or email address)"
    try { Get-MailboxContext -Identity $identity | Out-Null; return $true }
    catch { return $false }
}

function Get-LoadedSmtp { return $State.LoadedMailbox.PrimarySmtpAddress.ToString() }

function Invoke-PermissionsMenu {
    $mbx = Get-LoadedSmtp
    Write-Host "`nPermissions on $mbx :" -ForegroundColor Cyan
    Show-Table (Get-MailboxPermissionReport -Mailbox $mbx)
    switch (Read-Choice @('Grant permission(s)','Revoke permission(s)','Back')) {
        'Grant permission(s)' {
            $user = Read-RequiredString "User (user@domain.com)"
            $fa   = Read-YesNo "Grant Full Access?"
            $auto = $true
            if ($fa) { $auto = Read-YesNo "Enable Auto-Mapping?" -DefaultYes }
            $sa   = Read-YesNo "Grant Send As?"
            $sob  = Read-YesNo "Grant Send on Behalf?"
            if (-not ($fa -or $sa -or $sob)) { Write-ToolLog "Nothing selected." -Level Warning; return }
            Grant-MailboxAccess -Mailbox $mbx -User $user -FullAccess:$fa -AutoMapping $auto -SendAs:$sa -SendOnBehalf:$sob | Out-Null
        }
        'Revoke permission(s)' {
            $user = Read-RequiredString "User to revoke from"
            $fa   = Read-YesNo "Revoke Full Access?"
            $sa   = Read-YesNo "Revoke Send As?"
            $sob  = Read-YesNo "Revoke Send on Behalf?"
            if (-not ($fa -or $sa -or $sob)) { Write-ToolLog "Nothing selected." -Level Warning; return }
            if (-not (Read-YesNo "Confirm: revoke selected permissions for '$user' on '$mbx'?")) { return }
            Revoke-MailboxAccess -Mailbox $mbx -User $user -FullAccess:$fa -SendAs:$sa -SendOnBehalf:$sob | Out-Null
        }
        default { }
    }
}

function Invoke-ForwardingMenu {
    $mbx = Get-LoadedSmtp
    $f = Get-MailboxForwardingReport -MailboxObject (Update-MailboxContext)
    $current = if ($f.ForwardTo) { $f.ForwardTo } else { '(none)' }
    Write-Host "`nForwarding on ${mbx}: $current  (KeepCopy=$($f.KeepCopy))" -ForegroundColor Cyan
    switch (Read-Choice @('Set forwarding','Clear forwarding','Back')) {
        'Set forwarding' {
            $to   = Read-RequiredString "Forward to (email address)"
            $keep = Read-YesNo "Keep a copy in this mailbox?"
            try { Set-MailboxForwarding -Mailbox $mbx -ForwardTo $to -KeepCopy $keep } catch { Write-ToolLog "ERROR: $($_.Exception.Message)" -Level Error }
        }
        'Clear forwarding' {
            try { Clear-MailboxForwarding -Mailbox $mbx } catch { Write-ToolLog "ERROR: $($_.Exception.Message)" -Level Error }
        }
        default { }
    }
}

function Invoke-CalendarMenu {
    $mbx = Get-LoadedSmtp
    try { $rows = Get-CalendarPermissionReport -Mailbox $mbx }
    catch { Write-ToolLog "ERROR (load calendar permissions): $($_.Exception.Message)" -Level Error; return }
    Write-Host "`nCalendar permissions on $mbx :" -ForegroundColor Cyan
    Show-Table $rows -Properties User,AccessRights,IsInherited
    switch (Read-Choice @('Grant / Update permission','Remove permission','Back')) {
        'Grant / Update permission' {
            $user  = Read-RequiredString "User (user@domain.com)"
            Write-Host "Permission level:"
            $level = Read-Choice (Get-CalendarPermissionLevels) -Default 'Reviewer'
            if (-not $level) { Write-ToolLog "Unknown level." -Level Error; return }
            try { Grant-CalendarPermission -Mailbox $mbx -User $user -AccessRights $level | Out-Null } catch { Write-ToolLog "ERROR: $($_.Exception.Message)" -Level Error }
        }
        'Remove permission' {
            $user = Read-RequiredString "User to remove"
            if (-not (Read-YesNo "Remove calendar permission for '$user' on '$mbx'?")) { return }
            try { Revoke-CalendarPermission -Mailbox $mbx -User $user } catch { Write-ToolLog "ERROR: $($_.Exception.Message)" -Level Error }
        }
        default { }
    }
}

function Invoke-AliasesMenu {
    $mbx  = Get-LoadedSmtp
    $rows = Get-MailboxAliasReport -MailboxObject (Update-MailboxContext)
    Write-Host "`nAliases on $mbx :" -ForegroundColor Cyan
    Show-IndexedTable $rows -Properties Address,Type
    switch (Read-Choice @('Add alias','Remove alias','Back')) {
        'Add alias' {
            $alias = Read-RequiredString "New alias address"
            try { Add-MailboxAlias -Mailbox $mbx -Alias $alias } catch { Write-ToolLog "ERROR: $($_.Exception.Message)" -Level Error }
        }
        'Remove alias' {
            $idx = Read-IndexSelection -Count $rows.Count -Prompt "Enter the # of the alias to remove (0 to cancel)"
            if ($idx -lt 0) { return }
            $sel = $rows[$idx]
            if ($sel.IsPrimary) { Write-ToolLog "Cannot remove the Primary SMTP address." -Level Error; return }
            if (-not (Read-YesNo "Remove alias '$($sel.Address)' from '$mbx'?")) { return }
            try { Remove-MailboxAlias -Mailbox $mbx -Alias $sel.Address } catch { Write-ToolLog "ERROR: $($_.Exception.Message)" -Level Error }
        }
        default { }
    }
}

function Invoke-AutoReplyMenu {
    $mbx = Get-LoadedSmtp
    try {
        $ooo = Get-MailboxAutoReplyReport -Mailbox $mbx
        Write-Host "`nAuto-Reply on ${mbx}:" -ForegroundColor Cyan
        Write-Host "  State:    $($ooo.State)"
        Write-Host "  Internal: $($ooo.InternalMessage)"
        Write-Host "  External: $($ooo.ExternalMessage)"
    } catch { Write-ToolLog "Auto-Reply settings unavailable: $($_.Exception.Message)" -Level Warning }
    if (-not (Read-YesNo "Change auto-reply settings?")) { return }
    $enable   = Read-YesNo "Enable auto-reply?"
    $internal = ''; $external = ''
    if ($enable) { $internal = Read-Host "Internal reply message"; $external = Read-Host "External reply message" }
    try { Set-MailboxAutoReply -Mailbox $mbx -Enabled $enable -InternalMessage $internal -ExternalMessage $external }
    catch { Write-ToolLog "ERROR (auto-reply): $($_.Exception.Message)" -Level Error }
}

function Invoke-ManageMailboxLoop {
    while ($true) {
        Write-Heading "Manage Mailbox: $($State.LoadedMailbox.DisplayName) ($(Get-LoadedSmtp))"
        $choice = Read-Choice @('Permissions (view / grant / revoke)','Forwarding','Calendar Permissions','Aliases','Auto-Reply (Out of Office)','Load a different mailbox','Back to Main Menu')
        switch ($choice) {
            'Permissions (view / grant / revoke)' { Invoke-PermissionsMenu }
            'Forwarding'                          { Invoke-ForwardingMenu }
            'Calendar Permissions'                { Invoke-CalendarMenu }
            'Aliases'                             { Invoke-AliasesMenu }
            'Auto-Reply (Out of Office)'          { Invoke-AutoReplyMenu }
            'Load a different mailbox'            { if (-not (Invoke-LoadMailboxPrompt)) { return } }
            'Back to Main Menu'                   { return }
            default                               { Write-ToolLog "Unrecognized option." -Level Warning }
        }
    }
}

function Invoke-ManageMailboxMenu {
    if (-not (Test-ExoReady)) { return }
    if (-not (Invoke-LoadMailboxPrompt)) { return }
    Invoke-ManageMailboxLoop
}

# ================================================================================
# Feature: Compliance Search
# ================================================================================

function Invoke-ComplianceSearchMenu {
    Write-Heading "Compliance Search (Spam Cleanup)"
    if (-not $State.IppsConnected) {
        if (Read-YesNo "Not connected to IPPS (Search Only). Connect now?" -DefaultYes) { Connect-ToolCompliance | Out-Null }
    }
    if ($State.LastSearchName) { Write-Host "Last search: $($State.LastSearchName)  Items: $($State.LastSearchItems)" -ForegroundColor DarkGray }
    switch (Read-Choice @('Run a new search','Soft Delete Purge (last search)','Back')) {
        'Run a new search' {
            if (-not (Test-SearchReady)) { return }
            $from      = Read-OptionalString "From Address"
            $subject   = Read-OptionalString "Subject Contains"
            $recipient = Read-OptionalString "Recipient"
            $location  = if (Read-YesNo "Limit to a specific mailbox? (No = All Mailboxes)") { Read-RequiredString "Mailbox" } else { 'All' }
            $start = $null; $end = $null
            if (Read-YesNo "Filter by received date range?" -DefaultYes) {
                $start = Read-OptionalDate "Received Start" -Default (Get-Date).Date.AddDays(-3)
                $end   = Read-OptionalDate "Received End"   -Default (Get-Date).Date
            }
            $query = New-SpamComplianceQuery -From $from -Subject $subject -Recipient $recipient -StartDate $start -EndDate $end
            if ((Test-BroadComplianceQuery $query) -and -not (Read-YesNo "Your query is extremely broad and may return a huge number of items. Continue anyway?")) {
                Write-ToolLog "Search canceled due to broad query."; return
            }
            try { Invoke-SpamComplianceSearch -Query $query -ExchangeLocation $location | Out-Null }
            catch { Write-ToolLog "Search error: $($_.Exception.Message)" -Level Error }
        }
        'Soft Delete Purge (last search)' {
            if (-not (Test-PurgeReady)) { return }
            Write-Host "`nYou are about to SOFT DELETE messages for:" -ForegroundColor Yellow
            Write-Host "  Search Name: $($State.LastSearchName)"
            Write-Host "  Item Count:  $($State.LastSearchItems)"
            Write-Host "  This will move them into Recoverable Items."
            if (-not (Read-YesNo "Continue?")) { Write-ToolLog "Purge canceled by user."; return }
            try { Invoke-CompliancePurge | Out-Null } catch { Write-ToolLog "Purge error: $($_.Exception.Message)" -Level Error }
        }
        default { }
    }
}

# ================================================================================
# Feature: Message Trace
# ================================================================================

function Invoke-MessageTraceMenu {
    if (-not (Test-ExoReady)) { return }
    Write-Heading "Message Trace / Mail Flow"
    $sender    = Read-OptionalString "Sender"
    $recipient = Read-OptionalString "Recipient"
    $subject   = Read-OptionalString "Subject contains"
    $start     = Read-OptionalDate "Start" -Default (Get-Date).AddDays(-2)
    $end       = Read-OptionalDate "End"   -Default (Get-Date)
    Write-Host "Status filter:"
    $status    = Read-Choice (Get-MessageTraceStatuses) -Default '(Any)'

    try { $rows = Get-MessageTraceReport -Sender $sender -Recipient $recipient -Subject $subject -StartDate $start -EndDate $end -Status $status }
    catch { Write-ToolLog "Mail Flow search error: $($_.Exception.Message)" -Level Error; return }
    if ($rows.Count -eq 0) { return }
    Show-IndexedTable $rows -Properties Received,Sender,Recipient,Subject,Status

    while ($true) {
        $idx = Read-IndexSelection -Count $rows.Count -Prompt "Select a message # to investigate (0 to go back)"
        if ($idx -lt 0) { return }
        $row = $rows[$idx]
        Write-Host "`n$($row.Received)  $($row.Sender) -> $($row.Recipient)  '$($row.Subject)'" -ForegroundColor Cyan
        switch (Read-Choice @('View Transport Detail','Check Mailbox Activity','Show Inbox Rules','Choose a different message')) {
            'View Transport Detail'  { try { Show-Table (Get-MessageTraceDetailReport -TraceRow $row) } catch { Write-ToolLog "Transport detail error: $($_.Exception.Message)" -Level Error } }
            'Check Mailbox Activity' { try { Show-Table (Get-MailboxActivityReport -TraceRow $row) }    catch { Write-ToolLog "Mailbox activity error: $($_.Exception.Message)" -Level Error } }
            'Show Inbox Rules'       { try { Show-Table (Get-InboxRuleReport -Mailbox $row.Recipient) } catch { Write-ToolLog "Inbox rules error: $($_.Exception.Message)" -Level Error } }
            default { }
        }
    }
}

# ================================================================================
# Feature: Alias Search
# ================================================================================

function Invoke-AliasSearchMenu {
    if (-not (Test-ExoReady)) { return }
    Write-Heading "Alias Search"
    $term    = Read-RequiredString "Search term (alias, partial email, or full address)"
    $partial = Read-YesNo "Partial match?" -DefaultYes
    try { $rows = Find-RecipientByAddress -Term $term -Partial $partial }
    catch { Write-ToolLog "Alias Search ERROR: $($_.Exception.Message)" -Level Error; return }
    if ($rows.Count -eq 0) { return }
    Show-IndexedTable $rows
    if (Read-YesNo "Load one of these into Manage Mailbox?") {
        $idx = Read-IndexSelection -Count $rows.Count
        if ($idx -lt 0) { return }
        try { Get-MailboxContext -Identity $rows[$idx].PrimarySmtp | Out-Null; Invoke-ManageMailboxLoop } catch { }
    }
}

# ================================================================================
# Feature: Recurring Events
# ================================================================================

function Invoke-RecurringEventsMenu {
    if (-not (Test-ExoReady)) { return }
    Write-Heading "Recurring Events (Cancel Meetings)"
    Write-Host "Finds meetings the mailbox organizes (with attendees/resources) in the chosen window, then cancels them." -ForegroundColor DarkGray
    Write-Host "Recurring series with any occurrence in that window are cancelled in full." -ForegroundColor DarkGray

    $mailbox   = Read-RequiredString "Mailbox"
    $startDate = Read-OptionalDate "Start Date" -Default (Get-Date)
    $windowRaw = Read-Host "Window (days, Enter for 1)"
    $window    = 1
    [void][int]::TryParse($windowRaw, [ref]$window)
    $routing   = Read-YesNo "Use Custom Routing (experimental)?"
    $single    = Read-YesNo "Only show meetings with 0-1 other attendees? (requires Graph)"
    if ($single -and -not $State.GraphConnected) {
        if (Read-YesNo "Graph is not connected. Connect now?" -DefaultYes) { Connect-ToolGraph | Out-Null }
    }

    try {
        $p = Get-RecurringMeetingPreview -Mailbox $mailbox -StartDate $startDate -WindowDays $window -UseCustomRouting:$routing -FilterSingleAttendee:$single
    } catch { Write-ToolLog "ERROR: $($_.Exception.Message)" -Level Error; return }
    if ($p.Meetings.Count -eq 0) { return }
    Show-IndexedTable $p.Meetings -Properties Subject,StartDate

    Write-Host "`n$(Get-RecurringCancelWarning)" -ForegroundColor Yellow
    if (-not (Read-YesNo "Confirm cancellation")) { return }
    try { Remove-RecurringMeetings | Out-Null } catch { Write-ToolLog "ERROR (cancel): $($_.Exception.Message)" -Level Error }
}

# ================================================================================
# Main menu
# ================================================================================

Write-ToolLog "O365 Admin Tools (CLI) ready. Log file: $(Get-ToolLogPath)"

$running = $true
while ($running) {
    Show-ConnectionStatus
    Write-Host "== O365 Admin Tools (CLI) ==" -ForegroundColor White
    Write-Host " 1) Connect to Exchange Online"
    Write-Host " 2) Connect to IPPS (Search Only)"
    Write-Host " 3) Connect to Microsoft Graph (optional - Recurring Events attendee filter)"
    Write-Host " 4) Disconnect All"
    Write-Host " 5) Create Shared Mailbox"
    Write-Host " 6) Manage Mailbox (Permissions / Forwarding / Calendar / Aliases / Auto-Reply)"
    Write-Host " 7) Compliance Search (Spam Cleanup)"
    Write-Host " 8) Message Trace / Mail Flow Investigation"
    Write-Host " 9) Alias Search"
    Write-Host "10) Recurring Events (Cancel Meetings)"
    Write-Host " 0) Exit"
    switch (Read-Host "`nChoose an option") {
        '1'  { Connect-ToolExchangeOnline | Out-Null }
        '2'  { Connect-ToolCompliance | Out-Null }
        '3'  { Connect-ToolGraph | Out-Null }
        '4'  { Disconnect-ToolSessions }
        '5'  { Invoke-CreateSharedMailboxMenu }
        '6'  { Invoke-ManageMailboxMenu }
        '7'  { Invoke-ComplianceSearchMenu }
        '8'  { Invoke-MessageTraceMenu }
        '9'  { Invoke-AliasSearchMenu }
        '10' { Invoke-RecurringEventsMenu }
        '0'  { Disconnect-ToolSessions; Write-ToolLog "Goodbye."; $running = $false }
        default { Write-ToolLog "Unrecognized option." -Level Warning }
    }
}

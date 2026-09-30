#requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
    O365 Admin Tools - shared core module.
.DESCRIPTION
    All Exchange Online / Purview / Graph logic for the O365 Admin Tools lives here.
    Nothing in this module touches a UI: every function takes parameters and returns
    objects, and reports progress through Write-ToolLog. Front-ends (WinForms GUI,
    console CLI) import this module and only handle input and rendering.

    Optional: Microsoft.Graph.Calendar (only for the "0-1 other attendees" filter in
    Recurring Events). It is deliberately NOT in #requires so the rest of the tool
    works without it. Use Connect-ToolGraph / Test-GraphReady before calling that feature.
#>

# Version 1 catches uninitialized-variable typos without breaking on the variable
# property shapes of deserialized Exchange / audit-log objects (Version 2+ would).
Set-StrictMode -Version 1

# ================================================================================
# Configuration (tunable constants - formerly magic numbers scattered through the GUI)
# ================================================================================

$script:Config = @{
    ProvisionRetries            = 12          # New-Mailbox propagation polling attempts
    ProvisionDelaySeconds       = 5           # ...and delay between attempts
    SearchPollSeconds           = 5           # Compliance search status polling interval
    TraceMaxWindowDays          = 10          # Get-MessageTraceV2 hard limit
    SharedMailboxSizeLimitBytes = 50GB        # Unlicensed shared mailbox limit
    AliasSearchResultSize       = 200
    AuditLogResultSize          = 500
    CalendarPermissionLevels    = @('Owner','PublishingEditor','Editor','PublishingAuthor','Author',
                                    'NonEditingAuthor','Reviewer','AvailabilityOnly','LimitedDetails')
    MessageTraceStatuses        = @('(Any)','Delivered','Failed','FilteredAsSpam','Quarantined','Pending','Expanded')
    SystemPrincipalPattern      = 'NT AUTHORITY|\\SELF|S-1-5'
    LogDirectory                = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'O365AdminTools\Logs'
    GraphScopes                 = @('Calendars.Read')
}

function Get-ToolConfig { return $script:Config }

# ================================================================================
# State (one place instead of a dozen $script: variables)
# ================================================================================

$script:State = @{
    ExoConnected      = $false
    IppsConnected     = $false
    IppsMode          = 'Not Connected'
    GraphConnected    = $false
    LoadedMailbox     = $null      # Get-Mailbox object shared by Permissions / Aliases / Auto-Reply / Calendar
    PendingSearchName = $null      # Compliance search currently running (async polling)
    LastSearchName    = $null
    LastSearchItems   = 0
    RecurringPreview  = $null      # Last successful Recurring Events preview (needed for cancel)
}

function Get-ToolState { return $script:State }

function Reset-ToolMailboxContext {
    $script:State.LoadedMailbox = $null
}

# ================================================================================
# Logging - always to disk, optionally mirrored to a front-end sink
# ================================================================================

$script:LogSink = $null
$script:LogPath = $null

function Get-ToolLogPath {
    if (-not $script:LogPath) {
        try {
            if (-not (Test-Path $script:Config.LogDirectory)) {
                New-Item -ItemType Directory -Path $script:Config.LogDirectory -Force | Out-Null
            }
            $script:LogPath = Join-Path $script:Config.LogDirectory ("O365AdminTools_{0:yyyyMMdd}.log" -f (Get-Date))
        }
        catch { $script:LogPath = $null }
    }
    return $script:LogPath
}

function Register-ToolLogSink {
    <#
    .SYNOPSIS
    Front-ends register a scriptblock here to mirror log lines (to a TextBox, Write-Host, etc.).
    The scriptblock receives: $Line (formatted), $Level, $Message.
    #>
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock)
    $script:LogSink = $ScriptBlock
}

function Write-ToolLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info','Warning','Error','Success')][string]$Level = 'Info'
    )
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level.ToUpper(), $Message
    $path = Get-ToolLogPath
    if ($path) { try { Add-Content -Path $path -Value $line -ErrorAction SilentlyContinue } catch { } }
    if ($script:LogSink) { try { & $script:LogSink $line $Level $Message } catch { } }
}

# ================================================================================
# Connections
# ================================================================================

function Disconnect-ToolSessions {
    try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    try {
        Get-PSSession | Where-Object {
            $_.ComputerName -like "*ps.compliance.protection.outlook.com*" -or
            $_.ConfigurationName -like "Microsoft.Exchange*" -or
            $_.Name -like "*Exchange*"
        } | Remove-PSSession -ErrorAction SilentlyContinue
    } catch { }
    if ($script:State.GraphConnected) {
        try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
    }
    $script:State.ExoConnected   = $false
    $script:State.IppsConnected  = $false
    $script:State.IppsMode       = 'Not Connected'
    $script:State.GraphConnected = $false
    Write-ToolLog "Disconnected all sessions." -Level Success
}

function Connect-ToolExchangeOnline {
    try {
        Write-ToolLog "Connecting to Exchange Online..."
        Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
        $script:State.ExoConnected = $true
        Write-ToolLog "Connected to Exchange Online." -Level Success
        return $true
    }
    catch {
        $script:State.ExoConnected = $false
        Write-ToolLog "EXO connection error: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Connect-ToolCompliance {
    try {
        Write-ToolLog "Connecting to IPPS (SearchOnly)..."
        Connect-IPPSSession -EnableSearchOnlySession -ErrorAction Stop | Out-Null
        $script:State.IppsConnected = $true
        $script:State.IppsMode      = 'SearchOnly'
        Write-ToolLog "Connected to IPPS (SearchOnly)." -Level Success
        return $true
    }
    catch {
        $script:State.IppsConnected = $false
        $script:State.IppsMode      = 'Not Connected'
        Write-ToolLog "IPPS connection error: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Connect-ToolGraph {
    <#
    .SYNOPSIS
    Optional Microsoft Graph connection, used only by the Recurring Events attendee filter.
    NOTE: ExchangeOnlineManagement and Microsoft.Graph can conflict on interactive auth when
    both are loaded in one session. If this fails, connect Graph before EXO, or skip the filter.
    #>
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Calendar)) {
        Write-ToolLog "Microsoft.Graph.Calendar module is not installed. Install-Module Microsoft.Graph.Calendar to use the attendee filter." -Level Warning
        return $false
    }
    try {
        Write-ToolLog "Connecting to Microsoft Graph ($($script:Config.GraphScopes -join ', '))..."
        Connect-MgGraph -Scopes $script:Config.GraphScopes -NoWelcome -ErrorAction Stop | Out-Null
        $script:State.GraphConnected = $true
        Write-ToolLog "Connected to Microsoft Graph." -Level Success
        return $true
    }
    catch {
        $script:State.GraphConnected = $false
        Write-ToolLog "Graph connection error: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Test-ExoReady {
    if (-not $script:State.ExoConnected) {
        Write-ToolLog "Connect to Exchange Online first." -Level Warning
        return $false
    }
    return $true
}

function Test-SearchReady {
    if (-not $script:State.IppsConnected -or $script:State.IppsMode -ne 'SearchOnly') {
        Write-ToolLog "Connect to IPPS (Search Only) first." -Level Warning
        return $false
    }
    return $true
}

function Test-PurgeReady {
    if (-not (Test-SearchReady)) { return $false }
    if ($script:State.PendingSearchName) {
        Write-ToolLog "A compliance search is still running. Wait for it to finish before purging." -Level Warning
        return $false
    }
    if (-not $script:State.LastSearchName) {
        Write-ToolLog "No completed search found to purge." -Level Warning
        return $false
    }
    if ($script:State.LastSearchItems -lt 1) {
        Write-ToolLog "The last search returned 0 items. Nothing to purge." -Level Warning
        return $false
    }
    return $true
}

function Test-GraphReady {
    if (-not $script:State.GraphConnected) {
        Write-ToolLog "Connect to Microsoft Graph first (required for the attendee filter)." -Level Warning
        return $false
    }
    return $true
}

# ================================================================================
# Validation helpers
# ================================================================================

function Test-MailAlias {
    param([string]$Alias)
    if ([string]::IsNullOrWhiteSpace($Alias)) { return $false }
    if ($Alias -match '[@\s]') { return $false }
    return $Alias -match '^[A-Za-z0-9][A-Za-z0-9\!\#\$\%\&''\*\+\-\/=\?\^_`\{\|\}~\.]*[A-Za-z0-9]$' -or $Alias.Length -eq 1
}

function Test-EmailAddressFormat {
    param([string]$Address)
    return $Address -match '^[^@\s]+@[^@\s]+\.[^@\s]+$'
}

function Split-Entries {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $raw = ($Text -split "(`r`n|`n|,|;)" | ForEach-Object { $_.Trim() }) | Where-Object { $_ }
    return @($raw | Select-Object -Unique)
}

function Get-RecipientSafe {
    param([string]$Identity)
    try { return Get-Recipient -Identity $Identity -ErrorAction Stop }
    catch {
        Write-ToolLog "Recipient lookup failed for '$Identity': $($_.Exception.Message)" -Level Warning
        return $null
    }
}

function ConvertFrom-HtmlToText {
    param([string]$Html)
    return [System.Text.RegularExpressions.Regex]::Replace([string]$Html, '<[^>]+>', '')
}

# ================================================================================
# Shared Mailbox creation
# ================================================================================

function Test-SharedMailboxRequest {
    <#
    .SYNOPSIS
    Validates a shared-mailbox request. Returns IsValid, per-entry Rows, Errors, and the
    resolved primary SMTP lists for Full Access / Send As.
    #>
    param(
        [string]$DisplayName,
        [string]$Alias,
        [string]$PrimarySmtp,
        [string[]]$FullAccess = @(),
        [string[]]$SendAs     = @()
    )
    $errors = New-Object System.Collections.Generic.List[string]
    $rows   = New-Object System.Collections.Generic.List[object]
    $validFull   = New-Object System.Collections.Generic.List[string]
    $validSendAs = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($DisplayName)) { $errors.Add("Display Name is required.") }
    if (-not (Test-MailAlias -Alias $Alias))        { $errors.Add("Alias is invalid - use alphanumeric only, no @ symbol.") }
    if (-not [string]::IsNullOrWhiteSpace($PrimarySmtp) -and -not (Test-EmailAddressFormat $PrimarySmtp)) {
        $errors.Add("Primary SMTP doesn't look like a valid email address.")
    }

    foreach ($u in $FullAccess) {
        $r = Get-RecipientSafe $u
        if ($null -ne $r) {
            $validFull.Add($r.PrimarySmtpAddress.ToString())
            $rows.Add([PSCustomObject]@{ Type='FullAccess'; Identity=$u; Status='OK' })
        } else {
            $rows.Add([PSCustomObject]@{ Type='FullAccess'; Identity=$u; Status='NOT FOUND' })
            $errors.Add("Full Access user not found: $u")
        }
    }
    foreach ($u in $SendAs) {
        $r = Get-RecipientSafe $u
        if ($null -ne $r) {
            $validSendAs.Add($r.PrimarySmtpAddress.ToString())
            $rows.Add([PSCustomObject]@{ Type='SendAs'; Identity=$u; Status='OK' })
        } else {
            $rows.Add([PSCustomObject]@{ Type='SendAs'; Identity=$u; Status='NOT FOUND' })
            $errors.Add("Send As user not found: $u")
        }
    }

    [PSCustomObject]@{
        IsValid     = ($errors.Count -eq 0)
        Errors      = @($errors)
        Rows        = @($rows)
        ValidFull   = @($validFull)
        ValidSendAs = @($validSendAs)
    }
}

function New-SharedMailboxRequest {
    <#
    .SYNOPSIS
    Submits New-Mailbox -Shared and returns the identity to poll for. Does NOT wait.
    #>
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$Alias,
        [string]$PrimarySmtp
    )
    Write-ToolLog "Creating shared mailbox: DisplayName='$DisplayName'  Alias='$Alias'  SMTP='$PrimarySmtp'"
    $params = @{ Shared=$true; Name=$DisplayName; DisplayName=$DisplayName; Alias=$Alias; ErrorAction='Stop' }
    if (-not [string]::IsNullOrWhiteSpace($PrimarySmtp)) { $params.PrimarySmtpAddress = $PrimarySmtp }
    New-Mailbox @params | Out-Null
    Write-ToolLog "Mailbox creation submitted - waiting for EXO propagation..."
    if ($PrimarySmtp) { return $PrimarySmtp } else { return $Alias }
}

function Test-MailboxProvisioned {
    <#
    .SYNOPSIS
    Single non-blocking probe. Returns the mailbox object if it exists yet, otherwise $null.
    GUIs call this from a Timer tick; the CLI uses Wait-MailboxProvisioned.
    #>
    param([Parameter(Mandatory)][string]$Identity)
    return Get-Mailbox -Identity $Identity -ErrorAction SilentlyContinue
}

function Wait-MailboxProvisioned {
    param([Parameter(Mandatory)][string]$Identity)
    for ($i = 1; $i -le $script:Config.ProvisionRetries; $i++) {
        Start-Sleep -Seconds $script:Config.ProvisionDelaySeconds
        $mbx = Test-MailboxProvisioned -Identity $Identity
        if ($mbx) { return $mbx }
        Write-ToolLog "  Waiting... attempt $i/$($script:Config.ProvisionRetries)"
    }
    throw "Mailbox not found after waiting. Permissions can be applied manually once it appears."
}

function Set-SharedMailboxPermissions {
    param(
        [Parameter(Mandatory)][string]$MailboxId,
        [string[]]$FullAccess = @(),
        [string[]]$SendAs     = @()
    )
    foreach ($u in $FullAccess) {
        Write-ToolLog "  FullAccess  -> $u"
        Add-MailboxPermission -Identity $MailboxId -User $u -AccessRights FullAccess `
            -InheritanceType All -AutoMapping:$true -ErrorAction Stop | Out-Null
    }
    foreach ($u in $SendAs) {
        Write-ToolLog "  SendAs      -> $u"
        Add-RecipientPermission -Identity $MailboxId -Trustee $u -AccessRights SendAs `
            -Confirm:$false -ErrorAction Stop | Out-Null
    }
    Write-ToolLog "Shared mailbox ready and permissions applied: $MailboxId" -Level Success
}

# ================================================================================
# Mailbox context (shared by Permissions / Forwarding / Calendar / Aliases / Auto-Reply)
# ================================================================================

function Get-MailboxContext {
    <#
    .SYNOPSIS
    Loads a mailbox into State.LoadedMailbox (the single source of truth that used to be
    split across $loadedMbx and $loadedOOOMbx). Throws on failure.
    #>
    param([Parameter(Mandatory)][string]$Identity)
    Write-ToolLog "Loading mailbox $Identity ..."
    try {
        $mbx = Get-Mailbox -Identity $Identity -ErrorAction Stop
    }
    catch {
        $script:State.LoadedMailbox = $null
        Write-ToolLog "Mailbox load failed: $($_.Exception.Message)" -Level Error
        throw
    }
    $script:State.LoadedMailbox = $mbx
    Write-ToolLog "Loaded: $($mbx.DisplayName)  [$($mbx.RecipientTypeDetails)]  ($($mbx.PrimarySmtpAddress))" -Level Success
    return $mbx
}

function Update-MailboxContext {
    # Re-fetch the loaded mailbox after a change (aliases, forwarding, SOB).
    if ($script:State.LoadedMailbox) {
        $smtp = $script:State.LoadedMailbox.PrimarySmtpAddress.ToString()
        try { $script:State.LoadedMailbox = Get-Mailbox -Identity $smtp -ErrorAction Stop }
        catch { Write-ToolLog "Could not refresh mailbox $smtp : $($_.Exception.Message)" -Level Warning }
    }
    return $script:State.LoadedMailbox
}

function Get-MailboxPermissionReport {
    <#
    .SYNOPSIS
    One row per user with FullAccess / SendAs / SendOnBehalf columns.
    Errors in any of the three queries are logged (not swallowed) and flagged in the result.
    #>
    param([Parameter(Mandatory)][string]$Mailbox)
    $permMap = @{}
    $sysPat  = $script:Config.SystemPrincipalPattern

    try {
        Get-MailboxPermission -Identity $Mailbox -ErrorAction Stop |
            Where-Object { $_.AccessRights -contains 'FullAccess' -and -not $_.IsInherited -and $_.User -notmatch $sysPat } |
            ForEach-Object {
                $uid = $_.User.ToString()
                if (-not $permMap.ContainsKey($uid)) { $permMap[$uid] = @{FA=$false; SA=$false; SOB=$false} }
                $permMap[$uid].FA = $true
            }
    } catch { Write-ToolLog "Full Access query failed for $Mailbox : $($_.Exception.Message)" -Level Warning }

    try {
        Get-RecipientPermission -Identity $Mailbox -ErrorAction Stop |
            Where-Object { $_.AccessRights -contains 'SendAs' -and $_.Trustee -notmatch $sysPat } |
            ForEach-Object {
                $uid = $_.Trustee.ToString()
                if (-not $permMap.ContainsKey($uid)) { $permMap[$uid] = @{FA=$false; SA=$false; SOB=$false} }
                $permMap[$uid].SA = $true
            }
    } catch { Write-ToolLog "Send As query failed for $Mailbox : $($_.Exception.Message)" -Level Warning }

    try {
        $mbx = Get-Mailbox -Identity $Mailbox -ErrorAction Stop
        foreach ($sob in $mbx.GrantSendOnBehalfTo) {
            $uid = $sob.ToString()
            if (-not $permMap.ContainsKey($uid)) { $permMap[$uid] = @{FA=$false; SA=$false; SOB=$false} }
            $permMap[$uid].SOB = $true
        }
    } catch { Write-ToolLog "Send on Behalf query failed for $Mailbox : $($_.Exception.Message)" -Level Warning }

    $rows = foreach ($uid in ($permMap.Keys | Sort-Object)) {
        $p = $permMap[$uid]
        [PSCustomObject]@{
            User         = $uid
            FullAccess   = if ($p.FA)  { 'Yes' } else { '' }
            SendAs       = if ($p.SA)  { 'Yes' } else { '' }
            SendOnBehalf = if ($p.SOB) { 'Yes' } else { '' }
        }
    }
    return @($rows)
}

function Grant-MailboxAccess {
    <#
    .SYNOPSIS
    Grants any combination of Full Access / Send As / Send on Behalf. Each permission is
    attempted independently; returns one result row per permission attempted.
    #>
    param(
        [Parameter(Mandatory)][string]$Mailbox,
        [Parameter(Mandatory)][string]$User,
        [switch]$FullAccess,
        [bool]$AutoMapping = $true,
        [switch]$SendAs,
        [switch]$SendOnBehalf
    )
    $results = New-Object System.Collections.Generic.List[object]
    if ($FullAccess) {
        try {
            Remove-MailboxPermission -Identity $Mailbox -User $User -AccessRights FullAccess `
                -InheritanceType All -Confirm:$false -ErrorAction SilentlyContinue
            Add-MailboxPermission -Identity $Mailbox -User $User -AccessRights FullAccess `
                -InheritanceType All -AutoMapping $AutoMapping -ErrorAction Stop | Out-Null
            Write-ToolLog "Full Access granted to $User on $Mailbox (AutoMap=$AutoMapping)." -Level Success
            $results.Add([PSCustomObject]@{ Permission='FullAccess'; Success=$true; Message='' })
        } catch {
            Write-ToolLog "Full Access grant failed: $($_.Exception.Message)" -Level Error
            $results.Add([PSCustomObject]@{ Permission='FullAccess'; Success=$false; Message=$_.Exception.Message })
        }
    }
    if ($SendAs) {
        try {
            Add-RecipientPermission -Identity $Mailbox -Trustee $User -AccessRights SendAs -Confirm:$false -ErrorAction Stop | Out-Null
            Write-ToolLog "Send As granted to $User on $Mailbox." -Level Success
            $results.Add([PSCustomObject]@{ Permission='SendAs'; Success=$true; Message='' })
        } catch {
            Write-ToolLog "Send As grant failed: $($_.Exception.Message)" -Level Error
            $results.Add([PSCustomObject]@{ Permission='SendAs'; Success=$false; Message=$_.Exception.Message })
        }
    }
    if ($SendOnBehalf) {
        try {
            Set-Mailbox -Identity $Mailbox -GrantSendOnBehalfTo @{Add=$User} -ErrorAction Stop
            Write-ToolLog "Send on Behalf granted to $User on $Mailbox." -Level Success
            $results.Add([PSCustomObject]@{ Permission='SendOnBehalf'; Success=$true; Message='' })
        } catch {
            Write-ToolLog "Send on Behalf grant failed: $($_.Exception.Message)" -Level Error
            $results.Add([PSCustomObject]@{ Permission='SendOnBehalf'; Success=$false; Message=$_.Exception.Message })
        }
    }
    return @($results)
}

function Revoke-MailboxAccess {
    param(
        [Parameter(Mandatory)][string]$Mailbox,
        [Parameter(Mandatory)][string]$User,
        [switch]$FullAccess,
        [switch]$SendAs,
        [switch]$SendOnBehalf
    )
    $results = New-Object System.Collections.Generic.List[object]
    if ($FullAccess) {
        try {
            Remove-MailboxPermission -Identity $Mailbox -User $User -AccessRights FullAccess -InheritanceType All -Confirm:$false -ErrorAction Stop
            Write-ToolLog "Full Access revoked from $User on $Mailbox." -Level Success
            $results.Add([PSCustomObject]@{ Permission='FullAccess'; Success=$true; Message='' })
        } catch {
            Write-ToolLog "Full Access revoke failed: $($_.Exception.Message)" -Level Error
            $results.Add([PSCustomObject]@{ Permission='FullAccess'; Success=$false; Message=$_.Exception.Message })
        }
    }
    if ($SendAs) {
        try {
            Remove-RecipientPermission -Identity $Mailbox -Trustee $User -AccessRights SendAs -Confirm:$false -ErrorAction Stop
            Write-ToolLog "Send As revoked from $User on $Mailbox." -Level Success
            $results.Add([PSCustomObject]@{ Permission='SendAs'; Success=$true; Message='' })
        } catch {
            Write-ToolLog "Send As revoke failed: $($_.Exception.Message)" -Level Error
            $results.Add([PSCustomObject]@{ Permission='SendAs'; Success=$false; Message=$_.Exception.Message })
        }
    }
    if ($SendOnBehalf) {
        try {
            Set-Mailbox -Identity $Mailbox -GrantSendOnBehalfTo @{Remove=$User} -ErrorAction Stop
            Write-ToolLog "Send on Behalf revoked from $User on $Mailbox." -Level Success
            $results.Add([PSCustomObject]@{ Permission='SendOnBehalf'; Success=$true; Message='' })
        } catch {
            Write-ToolLog "Send on Behalf revoke failed: $($_.Exception.Message)" -Level Error
            $results.Add([PSCustomObject]@{ Permission='SendOnBehalf'; Success=$false; Message=$_.Exception.Message })
        }
    }
    return @($results)
}

# ---- Forwarding -----------------------------------------------------------------

function Get-MailboxForwardingReport {
    param([Parameter(Mandatory)]$MailboxObject)
    $fwdSmtp = $MailboxObject.ForwardingSmtpAddress
    $fwdInt  = $MailboxObject.ForwardingAddress
    $target  = if ($fwdSmtp) { $fwdSmtp.ToString() -replace '^smtp:', '' } elseif ($fwdInt) { $fwdInt.ToString() } else { '' }
    [PSCustomObject]@{
        ForwardTo = $target
        KeepCopy  = [bool]$MailboxObject.DeliverToMailboxAndForward
    }
}

function Set-MailboxForwarding {
    param([Parameter(Mandatory)][string]$Mailbox, [Parameter(Mandatory)][string]$ForwardTo, [bool]$KeepCopy = $false)
    Set-Mailbox -Identity $Mailbox -ForwardingSmtpAddress "smtp:$ForwardTo" -DeliverToMailboxAndForward $KeepCopy -ErrorAction Stop
    Write-ToolLog "Forwarding -> $ForwardTo set on $Mailbox (KeepCopy=$KeepCopy)." -Level Success
}

function Clear-MailboxForwarding {
    param([Parameter(Mandatory)][string]$Mailbox)
    Set-Mailbox -Identity $Mailbox -ForwardingSmtpAddress $null -ForwardingAddress $null -DeliverToMailboxAndForward $false -ErrorAction Stop
    Write-ToolLog "Forwarding cleared on $Mailbox." -Level Success
}

# ---- Calendar permissions -------------------------------------------------------

function Get-CalendarIdentity {
    <#
    .SYNOPSIS
    Returns "mailbox:\Calendar", falling back to folder statistics for non-English tenants.
    #>
    param([Parameter(Mandatory)][string]$Mailbox)
    $defaultPath = "${Mailbox}:\Calendar"
    try {
        Get-MailboxFolderPermission -Identity $defaultPath -ErrorAction Stop | Out-Null
        return $defaultPath
    }
    catch {
        Write-ToolLog "Default calendar path not found for $Mailbox, probing folder statistics..." -Level Info
        try {
            $calFolder = Get-MailboxFolderStatistics -Identity $Mailbox -FolderScope Calendar -ErrorAction Stop |
                         Where-Object { $_.FolderType -eq 'Calendar' } | Select-Object -First 1
            if ($calFolder) {
                $fp = $calFolder.FolderPath.TrimStart('/').Replace('/', '\')
                return "${Mailbox}:\${fp}"
            }
        }
        catch { Write-ToolLog "Calendar folder probe failed for $Mailbox : $($_.Exception.Message)" -Level Warning }
        return $defaultPath
    }
}

function Get-CalendarPermissionLevels { return $script:Config.CalendarPermissionLevels }

function Get-CalendarPermissionReport {
    param([Parameter(Mandatory)][string]$Mailbox)
    $calPath = Get-CalendarIdentity -Mailbox $Mailbox
    $perms   = Get-MailboxFolderPermission -Identity $calPath -ErrorAction Stop
    $rows = foreach ($p in $perms) {
        [PSCustomObject]@{
            User         = $p.User.ToString()
            AccessRights = ($p.AccessRights -join ', ')
            IsInherited  = if ($p.IsInherited) { 'Yes' } else { 'No' }
            IsSystem     = ($p.User.ToString() -in @('Default','Anonymous'))
        }
    }
    return @($rows)
}

function Grant-CalendarPermission {
    <#
    .SYNOPSIS
    Adds or updates a calendar folder permission. Returns 'Granted' or 'Updated'.
    #>
    param(
        [Parameter(Mandatory)][string]$Mailbox,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$AccessRights
    )
    if ($AccessRights -notin $script:Config.CalendarPermissionLevels) { throw "Unknown calendar permission level '$AccessRights'." }
    $calPath  = Get-CalendarIdentity -Mailbox $Mailbox
    $existing = Get-MailboxFolderPermission -Identity $calPath -User $User -ErrorAction SilentlyContinue
    if ($existing) {
        Set-MailboxFolderPermission -Identity $calPath -User $User -AccessRights $AccessRights -ErrorAction Stop | Out-Null
        Write-ToolLog "Calendar permission updated: $User -> $AccessRights on $Mailbox." -Level Success
        return 'Updated'
    }
    Add-MailboxFolderPermission -Identity $calPath -User $User -AccessRights $AccessRights -ErrorAction Stop | Out-Null
    Write-ToolLog "Calendar permission granted: $User -> $AccessRights on $Mailbox." -Level Success
    return 'Granted'
}

function Revoke-CalendarPermission {
    param([Parameter(Mandatory)][string]$Mailbox, [Parameter(Mandatory)][string]$User)
    if ($User -in @('Default','Anonymous')) { throw "'$User' is a system entry - use Grant/Update to change its level instead." }
    $calPath = Get-CalendarIdentity -Mailbox $Mailbox
    Remove-MailboxFolderPermission -Identity $calPath -User $User -Confirm:$false -ErrorAction Stop
    Write-ToolLog "Calendar permission removed for $User on $Mailbox." -Level Success
}

# ---- Aliases ------------------------------------------------------------------

function Get-MailboxAliasReport {
    param([Parameter(Mandatory)]$MailboxObject)
    $rows = foreach ($addr in $MailboxObject.EmailAddresses) {
        $addrStr = $addr.ToString()
        if ($addrStr -match '^[Ss][Mm][Tt][Pp]:(.+)$') {
            $isPrimary = $addrStr -cmatch '^SMTP:'
            [PSCustomObject]@{
                Address   = $Matches[1]
                Type      = if ($isPrimary) { 'Primary' } else { 'Alias' }
                IsPrimary = $isPrimary
            }
        }
    }
    return @($rows)
}

function Add-MailboxAlias {
    param([Parameter(Mandatory)][string]$Mailbox, [Parameter(Mandatory)][string]$Alias)
    if (-not (Test-EmailAddressFormat $Alias)) { throw "'$Alias' doesn't look like a valid email address." }
    Set-Mailbox -Identity $Mailbox -EmailAddresses @{Add="smtp:$Alias"} -ErrorAction Stop
    Write-ToolLog "Alias $Alias added to $Mailbox." -Level Success
}

function Remove-MailboxAlias {
    param([Parameter(Mandatory)][string]$Mailbox, [Parameter(Mandatory)][string]$Alias)
    $current = Get-Mailbox -Identity $Mailbox -ErrorAction Stop
    if ($current.PrimarySmtpAddress.ToString() -ieq $Alias) { throw "Cannot remove the Primary SMTP address." }
    Set-Mailbox -Identity $Mailbox -EmailAddresses @{Remove="smtp:$Alias"} -ErrorAction Stop
    Write-ToolLog "Alias $Alias removed from $Mailbox." -Level Success
}

function Find-RecipientByAddress {
    <#
    .SYNOPSIS
    Searches all recipient types by email address (partial or exact).
    #>
    param([Parameter(Mandatory)][string]$Term, [bool]$Partial = $true)
    $filter = if ($Partial) { "EmailAddresses -like '*$Term*'" } else { "EmailAddresses -eq 'smtp:$Term'" }
    $recipients = @(Get-Recipient -Filter $filter -ResultSize $script:Config.AliasSearchResultSize -ErrorAction Stop | Where-Object { $null -ne $_ })
    $rows = foreach ($r in $recipients) {
        $matched = @($r.EmailAddresses | ForEach-Object { $_.ToString() -replace '^smtp:','' -replace '^SMTP:','' } |
                    Where-Object { if ($Partial) { $_ -like "*$Term*" } else { $_ -ieq $Term } })
        [PSCustomObject]@{
            DisplayName    = [string]$r.DisplayName
            PrimarySmtp    = [string]$r.PrimarySmtpAddress
            Type           = [string]$r.RecipientTypeDetails
            MatchedAddress = ($matched -join ', ')
        }
    }
    Write-ToolLog "Alias Search: $(@($rows).Count) recipient(s) matched '$Term'."
    return @($rows)
}

# ---- Auto-Reply -----------------------------------------------------------------

function Get-MailboxAutoReplyReport {
    param([Parameter(Mandatory)][string]$Mailbox)
    $ooo = Get-MailboxAutoReplyConfiguration -Identity $Mailbox -ErrorAction Stop
    [PSCustomObject]@{
        Enabled         = ($ooo.AutoReplyState -eq 'Enabled')
        State           = [string]$ooo.AutoReplyState
        InternalMessage = ConvertFrom-HtmlToText $ooo.InternalMessage
        ExternalMessage = ConvertFrom-HtmlToText $ooo.ExternalMessage
    }
}

function Set-MailboxAutoReply {
    param(
        [Parameter(Mandatory)][string]$Mailbox,
        [Parameter(Mandatory)][bool]$Enabled,
        [string]$InternalMessage = '',
        [string]$ExternalMessage = ''
    )
    $state  = if ($Enabled) { 'Enabled' } else { 'Disabled' }
    $params = @{ Identity=$Mailbox; AutoReplyState=$state; ErrorAction='Stop' }
    if ($Enabled) {
        $params.InternalMessage  = $InternalMessage
        $params.ExternalMessage  = $ExternalMessage
        $params.ExternalAudience = 'All'
    }
    Set-MailboxAutoReplyConfiguration @params
    Write-ToolLog "Auto-reply set to '$state' on $Mailbox." -Level Success
}

# ================================================================================
# Compliance Search (Spam Cleanup) - split into start / poll / complete so a GUI can
# drive it from a Timer instead of blocking with Start-Sleep + DoEvents.
# ================================================================================

function Get-QuotedKqlValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function New-SpamComplianceQuery {
    param([string]$From, [string]$Subject, [string]$Recipient, [Nullable[datetime]]$StartDate, [Nullable[datetime]]$EndDate)
    $clauses = New-Object System.Collections.Generic.List[string]
    $clauses.Add("kind:email")
    if (-not [string]::IsNullOrWhiteSpace($From))    { $clauses.Add("from:"    + (Get-QuotedKqlValue $From.Trim())) }
    if (-not [string]::IsNullOrWhiteSpace($Subject)) { $clauses.Add("subject:" + (Get-QuotedKqlValue $Subject.Trim())) }
    if ($StartDate) { $clauses.Add("received>=" + $StartDate.Value.ToString("MM/dd/yyyy")) }
    if ($EndDate)   { $clauses.Add("received<"  + $EndDate.Value.Date.AddDays(1).ToString("MM/dd/yyyy")) }
    if (-not [string]::IsNullOrWhiteSpace($Recipient)) {
        $rv = Get-QuotedKqlValue $Recipient.Trim()
        $clauses.Add("(to:$rv OR recipients:$rv)")
    }
    return ($clauses -join " AND ")
}

function Test-BroadComplianceQuery {
    param([string]$Query)
    return ([string]::IsNullOrWhiteSpace($Query) -or $Query -eq "kind:email")
}

function Start-SpamComplianceSearch {
    <#
    .SYNOPSIS
    Creates and starts a compliance search, records it as pending, returns the search name.
    #>
    param([Parameter(Mandatory)][string]$Query, [string]$ExchangeLocation = 'All')
    if (-not (Test-SearchReady)) { return $null }
    if ($script:State.PendingSearchName) { throw "Search '$($script:State.PendingSearchName)' is still running." }
    $searchName = "SpamCleanup_{0:yyyyMMdd_HHmmss}" -f (Get-Date)
    Write-ToolLog "Creating compliance search: $searchName"
    Write-ToolLog "ExchangeLocation: $ExchangeLocation"
    Write-ToolLog "Query: $Query"
    New-ComplianceSearch -Name $searchName -ExchangeLocation $ExchangeLocation -ContentMatchQuery $Query `
        -AllowNotFoundExchangeLocationsEnabled $true -ErrorAction Stop | Out-Null
    Start-ComplianceSearch -Identity $searchName -ErrorAction Stop | Out-Null
    $script:State.PendingSearchName = $searchName
    Write-ToolLog "Compliance search started."
    return $searchName
}

function Get-SpamComplianceSearchStatus {
    param([Parameter(Mandatory)][string]$Name)
    $s = Get-ComplianceSearch -Identity $Name -ErrorAction Stop
    [PSCustomObject]@{
        Name       = $Name
        Status     = [string]$s.Status
        Items      = [int]$s.Items
        IsFinished = ($s.Status -in @('Completed','Failed'))
    }
}

function Complete-SpamComplianceSearch {
    <#
    .SYNOPSIS
    Records a finished search into state. Call once IsFinished is true.
    #>
    param([Parameter(Mandatory)]$Status)
    $script:State.PendingSearchName = $null
    if ($Status.Status -eq 'Failed') {
        Write-ToolLog "Compliance search $($Status.Name) failed. Check Purview / Compliance Center for detail." -Level Error
        return $false
    }
    $script:State.LastSearchName  = $Status.Name
    $script:State.LastSearchItems = $Status.Items
    Write-ToolLog "Search completed. Name: $($Status.Name)  Items: $($Status.Items)" -Level Success
    return $true
}

function Invoke-SpamComplianceSearch {
    <#
    .SYNOPSIS
    Synchronous convenience wrapper (used by the CLI): start, poll until done, complete.
    #>
    param([Parameter(Mandatory)][string]$Query, [string]$ExchangeLocation = 'All')
    $name = Start-SpamComplianceSearch -Query $Query -ExchangeLocation $ExchangeLocation
    if (-not $name) { return $null }
    do {
        Start-Sleep -Seconds $script:Config.SearchPollSeconds
        $st = Get-SpamComplianceSearchStatus -Name $name
        Write-ToolLog "Search status: $($st.Status)"
    } while (-not $st.IsFinished)
    Complete-SpamComplianceSearch -Status $st | Out-Null
    return $st
}

function Reset-SpamComplianceSearch {
    $script:State.LastSearchName  = $null
    $script:State.LastSearchItems = 0
}

function Invoke-CompliancePurge {
    <#
    .SYNOPSIS
    Soft-deletes the results of the last completed search. Caller is responsible for confirming.
    #>
    if (-not (Test-PurgeReady)) { return $false }
    $name = $script:State.LastSearchName
    Write-ToolLog "Submitting SoftDelete purge for: $name  ($($script:State.LastSearchItems) items)" -Level Warning
    New-ComplianceSearchAction -SearchName $name -Purge -PurgeType SoftDelete -ErrorAction Stop | Out-Null
    Write-ToolLog "Purge action submitted for $name. Monitor in Microsoft Purview / Compliance Center." -Level Success
    return $true
}

# ================================================================================
# Message Trace / Mail Flow
# ================================================================================

function Get-MessageTraceStatuses { return $script:Config.MessageTraceStatuses }

function Get-MessageTraceReport {
    param(
        [string]$Sender, [string]$Recipient, [string]$Subject,
        [Parameter(Mandatory)][datetime]$StartDate,
        [Parameter(Mandatory)][datetime]$EndDate,
        [string]$Status
    )
    $params = @{ StartDate=$StartDate; EndDate=$EndDate; ErrorAction='Stop' }
    if (-not [string]::IsNullOrWhiteSpace($Sender))    { $params.SenderAddress    = $Sender.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($Recipient)) { $params.RecipientAddress = $Recipient.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($Subject))   { $params.Subject          = $Subject.Trim() }
    if ($Status -and $Status -ne '(Any)') { $params.Status = $Status }
    if (($EndDate - $StartDate).TotalDays -gt $script:Config.TraceMaxWindowDays) {
        Write-ToolLog "Date range > $($script:Config.TraceMaxWindowDays) days - Get-MessageTraceV2 max window; results may be incomplete." -Level Warning
    }
    # Filter $null - EXO cmdlets can emit $null when empty, and @($null).Count is 1.
    $results = @(Get-MessageTraceV2 @params | Where-Object { $null -ne $_ -and -not [string]::IsNullOrEmpty($_.SenderAddress) })
    $rows = foreach ($r in $results) {
        [PSCustomObject]@{
            Received       = if ($r.Received) { ([datetime]$r.Received).ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
            Sender         = [string]$r.SenderAddress
            Recipient      = [string]$r.RecipientAddress
            Subject        = [string]$r.Subject
            Status         = [string]$r.Status
            MessageTraceId = $r.MessageTraceId
            ReceivedRaw    = $r.Received
        }
    }
    Write-ToolLog "Mail Flow: $(@($rows).Count) message(s) found."
    return @($rows)
}

function Get-MessageTraceDetailReport {
    param([Parameter(Mandatory)]$TraceRow)
    $details = @(Get-MessageTraceDetailV2 -MessageTraceId $TraceRow.MessageTraceId -RecipientAddress $TraceRow.Recipient -ErrorAction Stop)
    if ($details.Count -eq 0) { Write-ToolLog "Mail Flow: no transport events returned."; return @() }
    $propNames  = $details[0].PSObject.Properties.Name
    $dateProp   = 'Date','ReceivedTime','TimeStamp' | Where-Object { $propNames -contains $_ } | Select-Object -First 1
    $eventProp  = 'Event','MessageTraceDetailEvent' | Where-Object { $propNames -contains $_ } | Select-Object -First 1
    $detailProp = 'Detail','Data','Comments'        | Where-Object { $propNames -contains $_ } | Select-Object -First 1
    $sorted = if ($dateProp) { $details | Sort-Object $dateProp } else { $details }
    $rows = foreach ($d in $sorted) {
        [PSCustomObject]@{
            Time   = if ($dateProp -and $d.$dateProp) { ([datetime]$d.$dateProp).ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
            Event  = if ($eventProp)  { [string]$d.$eventProp }  else { '' }
            Detail = if ($detailProp) { [string]$d.$detailProp } else { ($d | Out-String).Trim() }
        }
    }
    Write-ToolLog "Mail Flow: $($details.Count) transport event(s) loaded."
    return @($rows)
}

function Get-MailboxActivityReport {
    <#
    .SYNOPSIS
    Best-effort match of unified audit log Move/Delete events to a traced message
    (recipient + subject + after delivery). Audit log can lag up to an hour.
    #>
    param([Parameter(Mandatory)]$TraceRow)
    $start   = if ($TraceRow.ReceivedRaw) { [datetime]$TraceRow.ReceivedRaw } else { [datetime]$TraceRow.Received }
    $records = @(Search-UnifiedAuditLog -StartDate $start -EndDate (Get-Date) -RecordType ExchangeItem `
        -Operations Move,SoftDelete,HardDelete,MoveToDeletedItems -UserIds $TraceRow.Recipient `
        -ResultSize $script:Config.AuditLogResultSize -ErrorAction Stop)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($rec in $records) {
        try { $ad = $rec.AuditData | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (-not $ad.Item -or $ad.Item.Subject -ne $TraceRow.Subject) { continue }
        $rows.Add([PSCustomObject]@{
            Time      = ([datetime]$ad.CreationTime).ToString('yyyy-MM-dd HH:mm:ss')
            Operation = $ad.Operation
            Folder    = "$($ad.Item.ParentFolder.Path)"
            Details   = "Id=$($ad.Item.Id)"
        })
    }
    Write-ToolLog "Mail Flow: $($rows.Count) matching mailbox activity record(s) out of $($records.Count) candidate(s) for $($TraceRow.Recipient)."
    return @($rows)
}

function Get-InboxRuleSummary {
    param($Rule)
    $conditionProps = 'From','FromAddressContainsWords','SubjectContainsWords','SubjectOrBodyContainsWords',
                      'SentTo','MyNameInToBox','MyNameInCcBox','HasAttachment','FlaggedForAction'
    $actionProps    = 'MoveToFolder','CopyToFolder','DeleteMessage','ForwardTo','RedirectTo','MarkAsRead','StopProcessingRules'
    $conditions = foreach ($p in $conditionProps) {
        $prop = $Rule.PSObject.Properties[$p]
        if ($prop -and $prop.Value) { "$p=$($prop.Value -join ',')" }
    }
    $actions = foreach ($p in $actionProps) {
        $prop = $Rule.PSObject.Properties[$p]
        if ($prop -and $prop.Value) { "$p=$($prop.Value -join ',')" }
    }
    [PSCustomObject]@{
        Conditions = if ($conditions) { $conditions -join '; ' } else { '(none matched)' }
        Actions    = if ($actions)    { $actions    -join '; ' } else { '(none)' }
    }
}

function Get-InboxRuleReport {
    param([Parameter(Mandatory)][string]$Mailbox)
    $rules = @(Get-InboxRule -Mailbox $Mailbox -ErrorAction Stop)
    $rows = foreach ($rule in $rules) {
        $summary = Get-InboxRuleSummary -Rule $rule
        [PSCustomObject]@{
            Name       = $rule.Name
            Enabled    = if ($rule.Enabled) { 'Yes' } else { 'No' }
            Priority   = [string]$rule.Priority
            Conditions = $summary.Conditions
            Actions    = $summary.Actions
        }
    }
    Write-ToolLog "Mail Flow: $($rules.Count) inbox rule(s) for $Mailbox."
    return @($rows)
}

# ================================================================================
# Recurring Events (cancel organized meetings)
# ================================================================================

function Get-MailboxHoldWarning {
    param([Parameter(Mandatory)][string]$Mailbox)
    $warnings = New-Object System.Collections.Generic.List[string]
    try { $mbx = Get-Mailbox -Identity $Mailbox -ErrorAction Stop }
    catch {
        try {
            Get-Mailbox -Identity $Mailbox -InactiveMailboxOnly -ErrorAction Stop | Out-Null
            $warnings.Add("Mailbox is INACTIVE (soft-deleted). Remove-CalendarEvents cannot modify it - restore first.")
        }
        catch { Write-ToolLog "Hold check: mailbox '$Mailbox' not found (active or inactive)." -Level Warning }
        return @($warnings)
    }
    if ($mbx.LitigationHoldEnabled -or ($mbx.InPlaceHolds -and $mbx.InPlaceHolds.Count -gt 0)) {
        $holds = if ($mbx.InPlaceHolds) { ", InPlaceHolds=$($mbx.InPlaceHolds -join ',')" } else { '' }
        $warnings.Add("Mailbox has a hold enabled (LitigationHold=$($mbx.LitigationHoldEnabled)$holds). Remove-CalendarEvents often fails with a server-side error while a hold is active.")
    }
    if ($mbx.RecipientTypeDetails -eq 'SharedMailbox') {
        try {
            $stats = Get-MailboxStatistics -Identity $Mailbox -ErrorAction Stop
            if ($stats.TotalItemSize.Value.ToBytes() -gt $script:Config.SharedMailboxSizeLimitBytes) {
                $warnings.Add("Shared mailbox is $($stats.TotalItemSize.Value) - mailboxes over 50 GB need a license or they enter a restricted state that can break calendar cmdlets.")
            }
        }
        catch { Write-ToolLog "Hold check: could not read statistics for $Mailbox : $($_.Exception.Message)" -Level Warning }
    }
    return @($warnings)
}

function Invoke-CalendarEventCancellation {
    <#
    .SYNOPSIS
    Wraps Remove-CalendarEvents (preview or real) and parses the verbose stream into meetings.
    #>
    param(
        [Parameter(Mandatory)][string]$Mailbox,
        [Parameter(Mandatory)][datetime]$StartDate,
        [Parameter(Mandatory)][int]$WindowDays,
        [switch]$PreviewOnly,
        [switch]$UseCustomRouting
    )
    $params = @{
        Identity = $Mailbox; CancelOrganizedMeetings = $true
        QueryStartDate = $StartDate; QueryWindowInDays = $WindowDays
        Confirm = $false; Verbose = $true
        ErrorAction = 'SilentlyContinue'; ErrorVariable = 'cmdletNonTerminatingErrors'
    }
    if ($PreviewOnly)      { $params.PreviewOnly      = $true }
    if ($UseCustomRouting) { $params.UseCustomRouting = $true }
    $cmdletNonTerminatingErrors = $null
    $rawLines = @(Remove-CalendarEvents @params 4>&1 | ForEach-Object { $_.ToString() })
    if ($cmdletNonTerminatingErrors) {
        foreach ($e in $cmdletNonTerminatingErrors) {
            $rawLines += "[non-terminating, ignored] $($e.ToString())"
            Write-ToolLog "Remove-CalendarEvents non-terminating error: $($e.ToString())" -Level Warning
        }
    }
    $meetings = foreach ($line in $rawLines) {
        if ($line -match 'subject\s+"(?<Subject>.*?)"\s+and start date\s+"(?<StartDate>.*?)"') {
            [PSCustomObject]@{ Subject = $Matches.Subject; StartDate = $Matches.StartDate }
        }
    }
    [PSCustomObject]@{ Meetings = @($meetings); RawLines = $rawLines }
}

function Get-CalendarAttendeeCountsBySubject {
    param([Parameter(Mandatory)][string]$Mailbox, [Parameter(Mandatory)][datetime]$StartDate, [Parameter(Mandatory)][datetime]$EndDate)
    $counts = @{}
    $events = Get-MgUserCalendarView -UserId $Mailbox `
        -StartDateTime $StartDate.ToString('yyyy-MM-ddTHH:mm:ss') -EndDateTime $EndDate.ToString('yyyy-MM-ddTHH:mm:ss') `
        -All -Property "Subject,Attendees,Organizer" -ErrorAction Stop
    foreach ($ev in $events) {
        if ([string]::IsNullOrWhiteSpace($ev.Subject)) { continue }
        $key   = $ev.Subject.Trim().ToLowerInvariant()
        $count = @($ev.Attendees | Where-Object { $_.Type -ne 'resource' }).Count
        if (-not $counts.ContainsKey($key) -or $count -lt $counts[$key]) { $counts[$key] = $count }
    }
    return $counts
}

function Get-RecurringMeetingPreview {
    <#
    .SYNOPSIS
    Previews meetings that Remove-CalendarEvents would cancel. Stores the preview in state
    so Remove-RecurringMeetings can re-run with identical parameters.
    #>
    param(
        [Parameter(Mandatory)][string]$Mailbox,
        [Parameter(Mandatory)][datetime]$StartDate,
        [int]$WindowDays = 1,
        [switch]$UseCustomRouting,
        [switch]$FilterSingleAttendee
    )
    $script:State.RecurringPreview = $null
    if ($WindowDays -lt 1) { $WindowDays = 1 }
    $startDate = $StartDate.Date

    foreach ($w in (Get-MailboxHoldWarning -Mailbox $Mailbox)) { Write-ToolLog "Recurring Events WARNING: $w" -Level Warning }

    $routing = if ($UseCustomRouting) { ' [Custom Routing]' } else { '' }
    Write-ToolLog "Recurring Events: Searching $Mailbox from $($startDate.ToShortDateString()) + $WindowDays day(s) ...$routing"
    $raw        = Invoke-CalendarEventCancellation -Mailbox $Mailbox -StartDate $startDate -WindowDays $WindowDays -PreviewOnly -UseCustomRouting:$UseCustomRouting
    $meetings   = $raw.Meetings
    $totalFound = $meetings.Count
    $filterApplied = $false
    $filterWarning = $null

    if ($FilterSingleAttendee -and $totalFound -gt 0) {
        if (-not (Test-GraphReady)) {
            $filterWarning = "Graph not connected - attendee filter skipped; showing all $totalFound meeting(s)."
            Write-ToolLog "Recurring Events: $filterWarning" -Level Warning
        }
        else {
            try {
                $counts    = Get-CalendarAttendeeCountsBySubject -Mailbox $Mailbox -StartDate $startDate -EndDate $startDate.AddDays($WindowDays)
                $kept      = New-Object System.Collections.Generic.List[object]
                $unmatched = 0
                foreach ($m in $meetings) {
                    $key = $m.Subject.Trim().ToLowerInvariant()
                    if ($counts.ContainsKey($key)) { if ($counts[$key] -le 1) { $kept.Add($m) } }
                    else { $unmatched++ }
                }
                $meetings      = @($kept)
                $filterApplied = $true
                $note = if ($unmatched -gt 0) { " ($unmatched could not be matched - verify manually)" } else { '' }
                Write-ToolLog "Recurring Events: '0-1 other attendees' filter kept $($meetings.Count) of $totalFound meeting(s)$note."
            }
            catch {
                $filterWarning = "Could not apply attendee filter ($($_.Exception.Message)) - showing all $totalFound meeting(s)."
                Write-ToolLog "Recurring Events: $filterWarning" -Level Warning
            }
        }
    }

    $preview = [PSCustomObject]@{
        Mailbox          = $Mailbox
        StartDate        = $startDate
        WindowDays       = $WindowDays
        UseCustomRouting = [bool]$UseCustomRouting
        Meetings         = @($meetings)
        TotalFound       = $totalFound
        FilteredCount    = $meetings.Count
        FilterApplied    = $filterApplied
        FilterWarning    = $filterWarning
    }
    if ($meetings.Count -gt 0) {
        $script:State.RecurringPreview = $preview
        Write-ToolLog "Recurring Events: $($meetings.Count) meeting(s) would be cancelled."
    } else {
        Write-ToolLog "Recurring Events: No organized meetings with attendees found in that window."
    }
    return $preview
}

function Get-RecurringCancelWarning {
    <#
    .SYNOPSIS
    Builds the confirmation text for the last preview, including the non-selective warning
    when the attendee filter hid some meetings.
    #>
    $p = $script:State.RecurringPreview
    if (-not $p) { return $null }
    $text = "Cancel all $($p.TotalFound) meeting(s) organized by '$($p.Mailbox)' in this window?`r`n" +
            "Attendees will receive cancellation notices. This cannot be undone."
    if ($p.FilterApplied -and $p.TotalFound -gt $p.FilteredCount) {
        $text += "`r`n`r`nNOTE: The attendee filter is showing $($p.FilteredCount) of $($p.TotalFound) meeting(s). " +
                 "Exchange's cancel operation is NOT selective - it will cancel ALL $($p.TotalFound) organized meetings in this window."
    }
    return $text
}

function Remove-RecurringMeetings {
    <#
    .SYNOPSIS
    Cancels the meetings from the last preview. Caller must confirm first. Returns count.
    #>
    $p = $script:State.RecurringPreview
    if (-not $p) { throw "Run a preview first." }
    $routing = if ($p.UseCustomRouting) { ' [Custom Routing]' } else { '' }
    Write-ToolLog "Recurring Events: Cancelling meetings for $($p.Mailbox) ...$routing" -Level Warning
    $result = Invoke-CalendarEventCancellation -Mailbox $p.Mailbox -StartDate $p.StartDate -WindowDays $p.WindowDays -UseCustomRouting:$p.UseCustomRouting
    $script:State.RecurringPreview = $null
    Write-ToolLog "Recurring Events: Cancellation submitted for $($result.Meetings.Count) meeting(s) on $($p.Mailbox)." -Level Success
    return $result.Meetings.Count
}

# ================================================================================
# Exports
# ================================================================================

Export-ModuleMember -Function @(
    # config / state / log
    'Get-ToolConfig','Get-ToolState','Reset-ToolMailboxContext','Get-ToolLogPath','Register-ToolLogSink','Write-ToolLog',
    # connections
    'Connect-ToolExchangeOnline','Connect-ToolCompliance','Connect-ToolGraph','Disconnect-ToolSessions',
    'Test-ExoReady','Test-SearchReady','Test-PurgeReady','Test-GraphReady',
    # validation
    'Test-MailAlias','Test-EmailAddressFormat','Split-Entries','Get-RecipientSafe','ConvertFrom-HtmlToText',
    # shared mailbox
    'Test-SharedMailboxRequest','New-SharedMailboxRequest','Test-MailboxProvisioned','Wait-MailboxProvisioned','Set-SharedMailboxPermissions',
    # mailbox context
    'Get-MailboxContext','Update-MailboxContext','Get-MailboxPermissionReport','Grant-MailboxAccess','Revoke-MailboxAccess',
    'Get-MailboxForwardingReport','Set-MailboxForwarding','Clear-MailboxForwarding',
    'Get-CalendarIdentity','Get-CalendarPermissionLevels','Get-CalendarPermissionReport','Grant-CalendarPermission','Revoke-CalendarPermission',
    'Get-MailboxAliasReport','Add-MailboxAlias','Remove-MailboxAlias','Find-RecipientByAddress',
    'Get-MailboxAutoReplyReport','Set-MailboxAutoReply',
    # compliance
    'New-SpamComplianceQuery','Test-BroadComplianceQuery','Start-SpamComplianceSearch','Get-SpamComplianceSearchStatus',
    'Complete-SpamComplianceSearch','Invoke-SpamComplianceSearch','Reset-SpamComplianceSearch','Invoke-CompliancePurge',
    # mail flow
    'Get-MessageTraceStatuses','Get-MessageTraceReport','Get-MessageTraceDetailReport','Get-MailboxActivityReport','Get-InboxRuleSummary','Get-InboxRuleReport',
    # recurring events
    'Get-MailboxHoldWarning','Get-RecurringMeetingPreview','Get-RecurringCancelWarning','Remove-RecurringMeetings'
)

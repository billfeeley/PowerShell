#Requires -Modules ActiveDirectory

<# GUI to create new Active Directory users. Template / starter version. #>

param([switch]$Elevated)

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

if (-not (Test-Admin)) {
    if (-not $Elevated) {
        Start-Process powershell.exe -Verb RunAs -ArgumentList (
            '-NoProfile -NoExit -File "{0}" -Elevated' -f $MyInvocation.MyCommand.Definition)
    }
    exit
}

Import-Module ActiveDirectory

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# --- Configuration ---------------------------------------------------------
# Edit these to match your environment.

$UserOU            = 'OU=Users,OU=Contoso,DC=contoso,DC=local'
$PrimaryDomain     = 'contoso.com'
$MailRoutingDomain = 'contoso.mail.onmicrosoft.com'

$Offices = [ordered]@{
    'Headquarters' = @{ Street = '100 Main Street, Ste 100'; City = 'Springfield';  State = 'IL'; Zip = '62701'; Country = 'US' }
    'North Office' = @{ Street = '200 Oak Avenue';           City = 'Madison';      State = 'WI'; Zip = '53703'; Country = 'US' }
    'East Office'  = @{ Street = '300 Pine Road, Ste 5';     City = 'Indianapolis'; State = 'IN'; Zip = '46204'; Country = 'US' }
    'South Office' = @{ Street = '400 Maple Lane';           City = 'St. Louis';    State = 'MO'; Zip = '63101'; Country = 'US' }
    'West Office'  = @{ Street = '500 Cedar Boulevard';      City = 'Des Moines';   State = 'IA'; Zip = '50309'; Country = 'US' }
    'Remote'       = @{ Street = '';                         City = '';             State = ''  ; Zip = '';      Country = 'US' }
}

# Office -> extra Locks group beyond the defaults baked into every template.
$ExtraOfficeLocks = @{
    'North Office' = 'Locks-North'
    'East Office'  = 'Locks-East'
    'South Office' = 'Locks-South'
    'West Office'  = 'Locks-West'
}

$Companies      = @('Contoso','Contoso Subsidiary')
$Departments    = @('Administration','Engineering','Finance','Marketing','Operations','Sales','Support','Warehouse')
$SubDepartments = @(
    'Accounts Payable','Accounts Receivable','Admin','Customer Success','Dispatch',
    'Drivers','Executive','Field Service','Human Resources','Inside Sales',
    'IT Operations','Logistics','Outside Sales','Parts','Procurement','Product',
    'QA','R&D','Reception','Security','Shipping','Software Engineering','Warehouse Staff'
)
$EmployeeTypes  = @('Full Time','Part Time','Hourly','Temporary','Intern','Contractor')

# Group templates -- replace these names with real groups from your AD.
$GroupTemplates = [ordered]@{
    'General Staff' = @(
        'All Staff','L-Email Signature','L-M365-E3',
        'Locks-Headquarters','SSO-MFA','SSO-Knowbe4','SSO-Paylocity','SSO-VPN'
    )
    'Executive' = @(
        'All Staff','AL-Executive','L-Email Signature','L-M365-E5',
        'Locks-Headquarters','SSO-MFA','SSO-Knowbe4','SSO-Paylocity','SSO-VPN'
    )
    'Sales' = @(
        'All Sales','All Staff','AL-Sales','FW-Sales','L-Email Signature',
        'L-M365-E3','Locks-Headquarters','SSO-CRM','SSO-MFA','SSO-Knowbe4',
        'SSO-Paylocity','SSO-VPN'
    )
    'Marketing' = @(
        'All Staff','AL-Marketing','FW-Marketing Templates','FW-Company Photos',
        'L-Email Signature','L-M365-E3','Locks-Headquarters','SSO-MFA',
        'SSO-Knowbe4','SSO-Paylocity','SSO-VPN'
    )
    'Finance' = @(
        'All Staff','AL-Finance','FR-Employee Info','FW-Finance',
        'L-Email Signature','L-M365-E3','Locks-Headquarters','SSO-ERP',
        'SSO-MFA','SSO-Knowbe4','SSO-Paylocity','SSO-VPN'
    )
    'Human Resources' = @(
        'All Staff','AL-HR','FR-Employee Info','FW-HR','L-Email Signature',
        'L-M365-E3','Locks-Headquarters','SSO-HRIS','SSO-MFA','SSO-Knowbe4',
        'SSO-Paylocity','SSO-VPN'
    )
    'Reception' = @(
        'All Staff','AL-Reception','FW-Reception','L-Email Signature',
        'L-M365-E3','Locks-Headquarters','SSO-MFA','SSO-Knowbe4',
        'SSO-Paylocity','SSO-VPN'
    )
    'Field Service Tech' = @(
        'All Staff','AL-Field Service','E-Dispatch Shortcut','FW-Service',
        'L-Email Signature','L-M365-E3','Locks-Headquarters','SSO-MFA',
        'SSO-Knowbe4','SSO-Paylocity','SSO-VPN','Service Department'
    )
    'IT Tier 1' = @(
        'All Staff','AL-IT Tier 1','FW-IT','L-Email Signature','L-M365-E3',
        'Locks-Headquarters','RS-Workstation Admins','Screenconnect-Quick Support',
        'SSO-ITSM','SSO-MFA','SSO-Knowbe4','SSO-Paylocity','SSO-VPN','Tech Alert'
    )
    'IT Tier 2' = @(
        'All Staff','AL-IT Tier 2','FW-IT','L-Email Signature','L-M365-E3',
        'Locks-Headquarters','RS-Server Admins','RS-Workstation Admins',
        'Screenconnect-All Clients','SSO-ITSM','SSO-MFA','SSO-Knowbe4',
        'SSO-Paylocity','SSO-VPN','Tech Alert'
    )
    'IT Tier 3' = @(
        'All Staff','AL-IT Tier 3','FW-IT','L-Email Signature','L-M365-E5',
        'Locks-Headquarters','RS-Domain Admins','RS-Server Admins',
        'RS-Workstation Admins','Screenconnect-All Clients','SSO-ITSM',
        'SSO-MFA','SSO-Knowbe4','SSO-Paylocity','SSO-VPN','Tech Alert'
    )
    'Software Engineer' = @(
        'All Staff','AL-Engineering','FW-Engineering','L-Email Signature',
        'L-M365-E5','Locks-Headquarters','RS-Source Control','SSO-GitHub',
        'SSO-Jira','SSO-MFA','SSO-Knowbe4','SSO-Paylocity','SSO-VPN'
    )
    'Warehouse Staff' = @(
        'All Staff','AL-Warehouse','FW-Warehouse','L-Email Signature',
        'L-M365-F3','Locks-Headquarters','SSO-MFA','SSO-Knowbe4',
        'SSO-Paylocity','SSO-VPN'
    )
}

# --- Helpers ---------------------------------------------------------------

function To-Title([string]$s) { (Get-Culture).TextInfo.ToTitleCase($s.ToLower()) }

function Get-UniqueSamAccountName([string]$First, [string]$Last) {
    $base = ($First.Substring(0,1) + $Last).ToLower()
    if (-not (Get-ADUser -LDAPFilter "(sAMAccountName=$base)")) { return $base }

    $alt = ($First.Substring(0,[Math]::Min(2,$First.Length)) + $Last).ToLower()
    if (-not (Get-ADUser -LDAPFilter "(sAMAccountName=$alt)")) { return $alt }

    for ($i = 2; $i -lt 10; $i++) {
        $try = "$alt$i"
        if (-not (Get-ADUser -LDAPFilter "(sAMAccountName=$try)")) { return $try }
    }
    throw "Could not find an available sAMAccountName starting with '$base'."
}

function Add-UserToGroupsSafe {
    param([string]$Sam, [string[]]$Groups)
    $failed = @()
    foreach ($g in ($Groups | Where-Object { $_ -and $_.Trim() })) {
        try { Add-ADGroupMember -Identity $g -Members $Sam -ErrorAction Stop }
        catch { $failed += "$g  ($($_.Exception.Message))" }
    }
    return $failed
}

# --- User creation ---------------------------------------------------------

function Invoke-CreateUser {
    $first = To-Title $FirstNameBox.Text.Trim()
    $last  = To-Title $LastNameBox.Text.Trim()
    $sam   = Get-UniqueSamAccountName -First $first -Last $last

    $password   = ConvertTo-SecureString $PasswordBox.Text -AsPlainText -Force
    $officeName = $MainOfficeDropDown.SelectedItem
    $office     = $Offices[$officeName]

    $managerName = $ManagerDropDown.SelectedItem
    $managerSam  = $null
    if ($managerName) {
        $managerSam = (Get-ADUser -Filter "DisplayName -eq '$managerName'" |
            Select-Object -First 1).SamAccountName
    }

    $userPrincipal = "$sam@$PrimaryDomain"
    $startDate     = $Calendar.SelectionStart.ToString('MM-dd-yyyy')

    $attrs = @{
        Path                  = $UserOU
        Enabled               = [bool]$UserEnabledCheckbox.Checked
        ChangePasswordAtLogon = [bool]$UserChangePasswordCheckbox.Checked
        AccountPassword       = $password
        Name                  = "$first $last"
        DisplayName           = "$first $last"
        SamAccountName        = $sam
        UserPrincipalName     = $userPrincipal
        GivenName             = $first
        Surname               = $last
        EmailAddress          = $userPrincipal
        Company               = $CompanyDropDown.SelectedItem
        Office                = $officeName
        StreetAddress         = $office.Street
        City                  = $office.City
        State                 = $office.State
        PostalCode            = $office.Zip
        Country               = $office.Country
        OtherAttributes       = @{
            ExtensionAttribute1 = $startDate
            mailNickname        = $sam
            employeeType        = $EmployeeTypeDropDown.SelectedItem
            ProxyAddresses      = @(
                "sip:$sam@$PrimaryDomain",
                "SMTP:$sam@$PrimaryDomain",
                "smtp:$sam@$MailRoutingDomain"
            )
            targetAddress       = "SMTP:$sam@$MailRoutingDomain"
            'msDS-SupportedEncryptionTypes' = 28
        }
    }

    if ($TitleBox.Text)           { $attrs.Title       = To-Title $TitleBox.Text.Trim() }
    if ($managerSam)              { $attrs.Manager     = $managerSam }
    if ($MobilePhoneBox.Text)     { $attrs.Mobile      = $MobilePhoneBox.Text.Trim() }
    if ($OfficePhoneBox.Text)     { $attrs.OfficePhone = $OfficePhoneBox.Text.Trim() }
    if ($OfficePhoneExtBox.Text)  { $attrs.OtherAttributes.ipPhone = $OfficePhoneExtBox.Text.Trim() }
    if ($DepartmentDropDown.SelectedItem)    { $attrs.Department = $DepartmentDropDown.SelectedItem }
    if ($SubDepartmentDropDown.SelectedItem) { $attrs.OtherAttributes.ExtensionAttribute2 = $SubDepartmentDropDown.SelectedItem }

    try {
        New-ADUser @attrs -ErrorAction Stop
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to create user '$sam':`n$($_.Exception.Message)",
            'User Creation Error','OK','Error') | Out-Null
        return
    }

    $groups = @($GroupTemplates[$GroupTemplateDropDown.SelectedItem])
    if ($ExtraOfficeLocks.ContainsKey($officeName)) { $groups += $ExtraOfficeLocks[$officeName] }
    if ($NeedsSampleSSOCheckBox.Checked)             { $groups += 'SSO-SampleApp' }
    $groups = $groups | Sort-Object -Unique

    $failed = Add-UserToGroupsSafe -Sam $sam -Groups $groups

    if (Get-ADUser -Filter "sAMAccountName -eq '$sam'") {
        $msg = "$((Get-ADUser $sam).Name) ($sam) was successfully created."
        if ($failed.Count) {
            $msg += "`n`nThe following group adds failed:`n - " + ($failed -join "`n - ")
            [System.Windows.Forms.MessageBox]::Show($msg,'User Created (with group errors)','OK','Warning') | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show($msg,'User Created','OK','Information') | Out-Null
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "There was an error and the user was not successfully created.",
            'User Creation Error','OK','Error') | Out-Null
    }
}

# --- UI builders -----------------------------------------------------------

function New-Label($text,$x,$y,$w=170) {
    New-Object System.Windows.Forms.Label -Property @{
        Location = New-Object Drawing.Point ($x,$y)
        Size     = New-Object Drawing.Size  ($w,20)
        Font     = 'Arial,11'
        Text     = $text
    }
}

function New-TextBox($x,$y,$w=150,[switch]$Password) {
    $tb = New-Object System.Windows.Forms.TextBox -Property @{
        Location = New-Object Drawing.Point ($x,$y)
        Size     = New-Object Drawing.Size  ($w,20)
        Font     = 'Arial,10'
    }
    if ($Password) { $tb.PasswordChar = '*' }
    $tb
}

function New-Combo($items,$x,$y,$w=170,$default=$null) {
    $cb = New-Object System.Windows.Forms.ComboBox -Property @{
        Location = New-Object Drawing.Point ($x,$y)
        Size     = New-Object Drawing.Size  ($w,150)
        Font     = 'Arial,10'
    }
    foreach ($i in $items) { [void]$cb.Items.Add($i) }
    if ($default) { $cb.SelectedIndex = $cb.FindString($default) }
    $cb
}

# --- Form ------------------------------------------------------------------

$Form = New-Object Windows.Forms.Form -Property @{
    StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    Size          = New-Object Drawing.Size (613,400)
    Text          = 'Create New AD User'
    Topmost       = $true
}

# Column 1: text fields
$FirstNameBox      = New-TextBox 7  30
$LastNameBox       = New-TextBox 7  80
$PasswordBox       = New-TextBox 7  130 -Password
$TitleBox          = New-TextBox 7  180
$MobilePhoneBox    = New-TextBox 7  230
$OfficePhoneBox    = New-TextBox 7  280
$OfficePhoneExtBox = New-TextBox 7  330

$Form.Controls.AddRange(@(
    (New-Label 'First Name:'   7 10),  $FirstNameBox,
    (New-Label 'Last Name:'    7 60),  $LastNameBox,
    (New-Label 'Password:'     7 110), $PasswordBox,
    (New-Label 'Title:'        7 160), $TitleBox,
    (New-Label 'Mobile Phone:' 7 210), $MobilePhoneBox,
    (New-Label 'Office Phone:' 7 260), $OfficePhoneBox,
    (New-Label 'Extension:'    7 310), $OfficePhoneExtBox
))

# Column 2: dropdowns
$CompanyDropDown       = New-Combo $Companies            180 30  -default 'Contoso'
$MainOfficeDropDown    = New-Combo $Offices.Keys         180 80  -default 'Headquarters'
$DepartmentDropDown    = New-Combo $Departments          180 130
$SubDepartmentDropDown = New-Combo $SubDepartments       180 180
$ManagerDropDown       = New-Combo @()                   180 230
$EmployeeTypeDropDown  = New-Combo $EmployeeTypes        180 280 -default 'Full Time'
$GroupTemplateDropDown = New-Combo $GroupTemplates.Keys  180 330

$adusers = (Get-ADUser -SearchBase $UserOU -Filter "Enabled -eq 'True'").Name | Sort-Object
[void]$ManagerDropDown.Items.AddRange($adusers)

$Form.Controls.AddRange(@(
    (New-Label 'Company:'        180 10),  $CompanyDropDown,
    (New-Label 'Main Office:'    180 60),  $MainOfficeDropDown,
    (New-Label 'Department:'     180 110), $DepartmentDropDown,
    (New-Label 'SubDepartment:'  180 160), $SubDepartmentDropDown,
    (New-Label 'Manager:'        180 210), $ManagerDropDown,
    (New-Label 'Employee Type:'  180 260), $EmployeeTypeDropDown,
    (New-Label 'Group Template:' 180 310), $GroupTemplateDropDown
))

# Column 3: calendar, options, button, SSO group box
$Calendar = New-Object System.Windows.Forms.MonthCalendar -Property @{
    Location          = New-Object Drawing.Point (370,30)
    ShowTodayCircle   = $true
    MaxSelectionCount = 1
}

$UserEnabledCheckbox = New-Object System.Windows.Forms.CheckBox -Property @{
    Location = New-Object Drawing.Size (370,199)
    Size     = New-Object Drawing.Size (90,15)
    Text     = 'Enable User'
    Checked  = $true
}
$UserChangePasswordCheckbox = New-Object System.Windows.Forms.CheckBox -Property @{
    Location = New-Object Drawing.Size (370,215)
    Size     = New-Object Drawing.Size (185,17)
    Text     = 'Change password at next logon'
    Checked  = $true
}

$CreateUserButton = New-Object System.Windows.Forms.Button -Property @{
    Location  = New-Object Drawing.Point (370,234)
    Size      = New-Object Drawing.Size  (120,30)
    Font      = 'Arial,11'
    Text      = 'Create User'
    ForeColor = 'White'
    BackColor = 'DarkBlue'
    Enabled   = $false
}
$CreateUserButton.Add_Click({ Invoke-CreateUser })

$groupBoxSSOGroup = New-Object System.Windows.Forms.GroupBox -Property @{
    Location = New-Object Drawing.Size (370,265)
    Size     = New-Object Drawing.Size (225,90)
    Text     = 'SSO Groups'
}
$NeedsSampleSSOCheckBox = New-Object System.Windows.Forms.CheckBox -Property @{
    Location = New-Object Drawing.Size (5,20)
    Size     = New-Object Drawing.Size (120,15)
    Text     = 'Sample App'
    Checked  = $false
}
$groupBoxSSOGroup.Controls.Add($NeedsSampleSSOCheckBox)

$Form.Controls.AddRange(@(
    (New-Label 'Start Date:' 370 10 90), $Calendar,
    $UserEnabledCheckbox, $UserChangePasswordCheckbox,
    $CreateUserButton, $groupBoxSSOGroup
))

# --- Validation ------------------------------------------------------------

$UpdateCreateEnabled = {
    $CreateUserButton.Enabled = (
        $FirstNameBox.Text.Length -gt 2 -and
        $LastNameBox.Text.Length  -gt 2 -and
        $TitleBox.Text.Length     -gt 3 -and
        $PasswordBox.Text.Length  -gt 13
    )
}
foreach ($tb in @($FirstNameBox,$LastNameBox,$TitleBox,$PasswordBox)) {
    $tb.add_TextChanged($UpdateCreateEnabled)
}

[void]$Form.ShowDialog()

<#=====================================================================================================================
 Script Name: CopyGroupsGUI.ps1
 Description: Will mirror the AD Groups from one user to another user
 Requirements: Active Directory Module must be installed
=======================================================================================================================#>


Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = "Mirror AD Groups"
$form.Size = New-Object System.Drawing.Size(400,250)
$form.StartPosition = "CenterScreen"

$label1 = New-Object System.Windows.Forms.Label
$label1.Location = New-Object System.Drawing.Point(10,20)
$label1.Size = New-Object System.Drawing.Size(280,20)
$label1.Text = "Enter the source username:"
$form.Controls.Add($label1)

$sourceUserBox = New-Object System.Windows.Forms.TextBox
$sourceUserBox.Location = New-Object System.Drawing.Point(10,40)
$sourceUserBox.Size = New-Object System.Drawing.Size(260,20)
$form.Controls.Add($sourceUserBox)

$label2 = New-Object System.Windows.Forms.Label
$label2.Location = New-Object System.Drawing.Point(10,70)
$label2.Size = New-Object System.Drawing.Size(280,20)
$label2.Text = "Enter the target username:"
$form.Controls.Add($label2)

$targetUserBox = New-Object System.Windows.Forms.TextBox
$targetUserBox.Location = New-Object System.Drawing.Point(10,90)
$targetUserBox.Size = New-Object System.Drawing.Size(260,20)
$form.Controls.Add($targetUserBox)

$button = New-Object System.Windows.Forms.Button
$button.Location = New-Object System.Drawing.Point(100,120)
$button.Size = New-Object System.Drawing.Size(100,20)
$button.Text = "Add Groups"
$button.Add_Click({
    $sourceUser = $sourceUserBox.Text
    $targetUser = $targetUserBox.Text
    $groups = Get-ADPrincipalGroupMembership -Identity $sourceUser | Select-Object -ExpandProperty Name

    foreach ($group in $groups) {
        Add-ADGroupMember -Identity $group -Members $targetUser
    }
    [System.Windows.Forms.MessageBox]::Show("You're Winner!!!!")
})
$form.Controls.Add($button)

$form.Add_Shown({$sourceUserBox.Focus()})
[void] $form.ShowDialog()

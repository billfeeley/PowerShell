<#=====================================================================================================================
 Script Name: UnlockADAccount.ps1
 Author: Bill Feeley
 Description: Unlocks a specified AD Account
 Requirements: Active Directory Module must be installed
=======================================================================================================================#>

Add-Type -AssemblyName System.Windows.Forms

$users = Get-ADUser -Filter * -SearchBase "OU=Users,OU=Company,DC=Domain,DC=COM" | Select-Object DistinguishedName

$form = New-Object System.Windows.Forms.Form
$form.Text = "Unlock AD Account"
$form.Size = New-Object System.Drawing.Size(300,200)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen

$label = New-Object System.Windows.Forms.Label
$label.Text = "Select the user:"
$label.AutoSize = $true
$label.Location = New-Object System.Drawing.Point(10,20)
$form.Controls.Add($label)

$comboBox = New-Object System.Windows.Forms.ComboBox
$comboBox.Location = New-Object System.Drawing.Point(10,50)
$comboBox.Size = New-Object System.Drawing.Size(250,20)
$comboBox.DataSource = $users
$comboBox.DisplayMember = "Name"
$form.Controls.Add($comboBox)

$button = New-Object System.Windows.Forms.Button
$button.Text = "Unlock Account"
$button.Size = New-Object System.Drawing.Size(100,30)
$button.Location = New-Object System.Drawing.Point(10,80)
$form.Controls.Add($button)

$button.Add_Click({
    $username = $comboBox.SelectedItem.DistinguishedName
    Unlock-ADAccount -Identity $username
    $form.Close()
})

$form.ShowDialog()

Add-Type -AssemblyName System.Windows.Forms

Connect-ExchangeOnline -UserPrincipalName bfeeley@provenit.com -ShowProgress $true

$form = New-Object System.Windows.Forms.Form
$form.Size = New-Object System.Drawing.Size(450,300)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Text = "Add Mailbox Permissions"

$pictureBox = New-Object System.Windows.Forms.PictureBox
$pictureBox.Image = [System.Drawing.Image]::FromFile("C:\Master\Images\jedi.gif")
$pictureBox.Size = New-Object System.Drawing.Size(50,50)
$pictureBox.Location = New-Object System.Drawing.Point(350,20)
$form.Controls.Add($pictureBox)

$mailboxLabel = New-Object System.Windows.Forms.Label
$mailboxLabel.Location = New-Object System.Drawing.Point(20,20)
$mailboxLabel.Size = New-Object System.Drawing.Size(100,20)
$mailboxLabel.Text = "Mailbox:"
$form.Controls.Add($mailboxLabel)

$mailboxTextBox = New-Object System.Windows.Forms.TextBox
$mailboxTextBox.Location = New-Object System.Drawing.Point(120,20)
$mailboxTextBox.Size = New-Object System.Drawing.Size(200,20)
$form.Controls.Add($mailboxTextBox)

$userLabel = New-Object System.Windows.Forms.Label
$userLabel.Location = New-Object System.Drawing.Point(20,60)
$userLabel.Size = New-Object System.Drawing.Size(100,20)
$userLabel.Text = "User:"
$form.Controls.Add($userLabel)

$userTextBox = New-Object System.Windows.Forms.TextBox
$userTextBox.Location = New-Object System.Drawing.Point(120,60)
$userTextBox.Size = New-Object System.Drawing.Size(200,20)
$form.Controls.Add($userTextBox)

$addButton = New-Object System.Windows.Forms.Button
$addButton.Location = New-Object System.Drawing.Point(150,100)
$addButton.Size = New-Object System.Drawing.Size(100,30)
$addButton.Text = "Add"
$addButton.Add_Click({
    Add-MailboxPermission -Identity $mailboxTextBox.Text -User $userTextBox.Text -AccessRights FullAccess -AutoMapping $true -InheritanceType All -Confirm:$false
    [System.Windows.Forms.MessageBox]::Show("You're Winner!!!!!!!!")
    $form.Close()
})
$form.Controls.Add($addButton)

$form.ShowDialog()

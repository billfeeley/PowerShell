# Load the System.Windows.Forms assembly
Add-Type -AssemblyName System.Windows.Forms

# Create a new form
$form = New-Object System.Windows.Forms.Form

# Set the form's properties
$form.Size = New-Object System.Drawing.Size(420, 300)
$form.Text = "SMTP Address Finder"

# Create a label for the form
$label = New-Object System.Windows.Forms.Label
$label.Size = New-Object System.Drawing.Size(360, 20)
$label.Location = New-Object System.Drawing.Point(20, 20)
$label.Text = "Enter the display name of the user:"

# Create a text box for the form
$textBox = New-Object System.Windows.Forms.TextBox
$textBox.Size = New-Object System.Drawing.Size(360, 20)
$textBox.Location = New-Object System.Drawing.Point(20, 50)

# Create a connect button for the form
$connectButton = New-Object System.Windows.Forms.Button
$connectButton.Size = New-Object System.Drawing.Size(120, 30)
$connectButton.Location = New-Object System.Drawing.Point(260, 80)
$connectButton.Text = "Connect to O365"

# Add an event handler for the connect button's click event
$connectButton.Add_Click({
    # Connect to Office 365 using the Connect-ExchangeOnline cmdlet
    Connect-ExchangeOnline -UserPrincipalName bfeeley@provenit.com -ShowProgress $true

    # Show a message box indicating that the connection was successful
    [System.Windows.Forms.MessageBox]::Show("Successfully connected to Office 365")
})

# Create a find button for the form
$findButton = New-Object System.Windows.Forms.Button
$findButton.Size = New-Object System.Drawing.Size(100, 30)
$findButton.Location = New-Object System.Drawing.Point(20, 80)
$findButton.Text = "Find"

# Add an event handler for the find button's click event
$findButton.Add_Click({
    # Get the display name from the text box
    $displayName = $textBox.Text

    # Find the SMTP address using the Get-Recipient cmdlet
    $smtpAddress = (Get-Recipient -Identity $displayName).PrimarySmtpAddress

    # Display the SMTP address in a message box
    [System.Windows.Forms.MessageBox]::Show("The SMTP address is: $smtpAddress")
})

# Add the controls to the form
$form.Controls.AddRange(@($label, $textBox, $connectButton, $findButton))

# Show the form
$form.ShowDialog()

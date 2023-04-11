# Create a GUI form with necessary fields
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Form = New-Object System.Windows.Forms.Form
$Form.Text = "Calculate Percentage Delays for Early Intervention"
$Form.Size = New-Object System.Drawing.Size(400, 200)
$Form.StartPosition = "CenterScreen"

# Add a label for chronological age
$LabelChronoAge = New-Object System.Windows.Forms.Label
$LabelChronoAge.Location = New-Object System.Drawing.Point(10, 20)
$LabelChronoAge.Size = New-Object System.Drawing.Size(200, 20)
$LabelChronoAge.Text = "Enter Chronological Age (months):"
$Form.Controls.Add($LabelChronoAge)

# Add a textbox for chronological age input
$TextboxChronoAge = New-Object System.Windows.Forms.TextBox
$TextboxChronoAge.Location = New-Object System.Drawing.Point(220, 20)
$TextboxChronoAge.Size = New-Object System.Drawing.Size(150, 20)
$Form.Controls.Add($TextboxChronoAge)

# Add a label for developmental age
$LabelDevAge = New-Object System.Windows.Forms.Label
$LabelDevAge.Location = New-Object System.Drawing.Point(10, 50)
$LabelDevAge.Size = New-Object System.Drawing.Size(200, 20)
$LabelDevAge.Text = "Enter Developmental Age (months):"
$Form.Controls.Add($LabelDevAge)

# Add a textbox for developmental age input
$TextboxDevAge = New-Object System.Windows.Forms.TextBox
$TextboxDevAge.Location = New-Object System.Drawing.Point(220, 50)
$TextboxDevAge.Size = New-Object System.Drawing.Size(150, 20)
$Form.Controls.Add($TextboxDevAge)

# Add a button to calculate percentage delay
$ButtonCalculate = New-Object System.Windows.Forms.Button
$ButtonCalculate.Location = New-Object System.Drawing.Point(100, 90)
$ButtonCalculate.Size = New-Object System.Drawing.Size(200, 30)
$ButtonCalculate.Text = "Calculate Percentage Delay"
$ButtonCalculate.Add_Click({
    # Get input values
    $ChronoAge = [int]$TextboxChronoAge.Text
    $DevAge = [int]$TextboxDevAge.Text

    # Calculate delay and percentage delay
    $Delay = $ChronoAge - $DevAge
    $PercentageDelay = [math]::Round(($Delay / $ChronoAge) * 100, 2)

    # Show result in message box
    $ResultMessage = "Delay: $Delay months`nPercentage Delay: $PercentageDelay%"
    [System.Windows.Forms.MessageBox]::Show($ResultMessage, "Result")
})
$Form.Controls.Add($ButtonCalculate)

# Show the form
$Form.ShowDialog() | Out-Null

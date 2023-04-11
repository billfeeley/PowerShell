
Add-Type -AssemblyName System.Windows.Forms

# Create a new form
$form = New-Object System.Windows.Forms.Form
$form.Text = "IPv6 Settings"
$form.AutoSize = $true

# Create a label to display instructions
$label = New-Object System.Windows.Forms.Label
$label.Location = New-Object System.Drawing.Point(10, 10)
$label.AutoSize = $true
$label.Text = "Select a network adapter to enable or disable IPv6:"
$form.Controls.Add($label)

# Create a list view to display the network adapters
$listView = New-Object System.Windows.Forms.ListView
$listView.Location = New-Object System.Drawing.Point(10, 32)
$listView.Size = New-Object System.Drawing.Size(400, 200)
$listView.View = [System.Windows.Forms.View]::Details

# Add columns to the list view
$listView.Columns.Add("Name", 275) | Out-Null
$listView.Columns.Add("IPv6 Enabled", 100) | Out-Null

# Add each network adapter to the list view
Get-NetAdapter | Select-Object Name, InterfaceDescription, @{Name="IPv6Enabled"; Expression={(Get-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6).Enabled}} | ForEach-Object {
    $listViewItem = New-Object System.Windows.Forms.ListViewItem($_.InterfaceDescription)
    $listViewItem.SubItems.Add($_.IPv6Enabled.ToString())
    $listViewItem.Tag = $_.Name
    $listView.Items.Add($listViewItem) | Out-Null
}
$form.Controls.Add($listView)

# Create a checkbox to enable or disable IPv6
$checkBox = New-Object System.Windows.Forms.CheckBox
$checkBox.Location = New-Object System.Drawing.Point(10, 240)
$checkBox.AutoSize = $true
$checkbox.Text = "Enable/Disable"
$form.Controls.Add($checkBox)

# Create a button to apply the changes
$button = New-Object System.Windows.Forms.Button
$button.Location = New-Object System.Drawing.Point(10, 270)
$button.Text = "Apply"
$button.add_Click({
    $adapterName = $listView.SelectedItems[0].Tag
    $adapter = Get-NetAdapter -Name $adapterName
    $binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6
    if ($binding.Enabled) {
        $checkBox.Checked = $true
        $binding.Enabled = $false
        Set-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -Enabled $false
        $listView.SelectedItems[0].SubItems[1].Text = "False"
    } else {
        $checkBox.Checked = $false
        $binding.Enabled = $true
        Set-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -Enabled $true
        $listView.SelectedItems[0].SubItems[1].Text = "True"
    }
})
$form.Controls.Add($button)

# Show the form
$form.ShowDialog()


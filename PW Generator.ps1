<# 
.NAME
    PW Generator
.SYNOPSIS
    Quick dictionary PW generator with 3 words and a 2 digit number with spaces inbetween
.DESCRIPTION
    GUI based PW generator that makes user friendly dictionary based passwords that comply with most strong complexity requirements :  PWs have 3 upper, many lower and 2 numbers with spaces (special characters ) You can also modify the text box as needed.
#>

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

$Form                            = New-Object system.Windows.Forms.Form
$Form.ClientSize                 = New-Object System.Drawing.Point(602,137)
$Form.text                       = "Password Generator v1 "
$Form.TopMost                    = $false

$Generate                        = New-Object system.Windows.Forms.Button
$Generate.text                   = "Generate Password"
$Generate.width                  = 141
$Generate.height                 = 30
$Generate.location               = New-Object System.Drawing.Point(225,87)
$Generate.Font                   = New-Object System.Drawing.Font('Microsoft Sans Serif',10)

$PWBox                           = New-Object system.Windows.Forms.TextBox
$PWBox.multiline                 = $false
$PWBox.width                     = 499
$PWBox.height                    = 20
$PWBox.location                  = New-Object System.Drawing.Point(11,41)
$PWBox.Font                      = New-Object System.Drawing.Font('Microsoft Sans Serif',14)

$Copy                            = New-Object system.Windows.Forms.Button
$Copy.text                       = "Copy"
$Copy.width                      = 60
$Copy.height                     = 30
$Copy.location                   = New-Object System.Drawing.Point(520,38)
$Copy.Font                       = New-Object System.Drawing.Font('Microsoft Sans Serif',10)

$Label1                          = New-Object system.Windows.Forms.Label
$Label1.text                     = "Character Count:"
$Label1.AutoSize                 = $true
$Label1.width                    = 25
$Label1.height                   = 10
$Label1.location                 = New-Object System.Drawing.Point(399,100)
$Label1.Font                     = New-Object System.Drawing.Font('Microsoft Sans Serif',10)

$Count                           = New-Object system.Windows.Forms.Label
$Count.AutoSize                  = $true
$Count.width                     = 25
$Count.height                    = 10
$Count.location                  = New-Object System.Drawing.Point(526,98)
$Count.Font                      = New-Object System.Drawing.Font('Microsoft Sans Serif',12,[System.Drawing.FontStyle]([System.Drawing.FontStyle]::Bold))

$Email                           = New-Object system.Windows.Forms.Button
$Email.text                      = "Email"
$Email.width                     = 60
$Email.height                    = 30
$Email.location                  = New-Object System.Drawing.Point(36,87)
$Email.Font                      = New-Object System.Drawing.Font('Microsoft Sans Serif',10)

$Lowercase                       = New-Object system.Windows.Forms.CheckBox
$Lowercase.text                  = "All lowercase"
$Lowercase.AutoSize              = $false
$Lowercase.width                 = 125
$Lowercase.height                = 20
$Lowercase.location              = New-Object System.Drawing.Point(418,18)
$Lowercase.Font                  = New-Object System.Drawing.Font('Microsoft Sans Serif',10)

$Form.controls.AddRange(@($Generate,$PWBox,$Copy,$Label1,$Count,$Email,$Lowercase))

$Copy.Add_Click({ Copy_Click })
$Generate.Add_Click({ Generate_click })
$Email.Add_Click({ Email_click })
$PWBox.Add_TextChanged({ Text_Change })

#region Logic 
function Text_Change { $count.text = ($PWBox.text | Measure-Object -Character).Characters}


function Email_click { 
$PW= $PWBox.text
$body = @"
This email is not to be fowarded or shared
Below are your credentials for: (system name here)
Username: ""
Password: "$pw"
"@

$ol = New-Object -comObject Outlook.Application
$mail = $ol.CreateItem(0)
$mail.Subject = "Jedi Council Credential delivery"
$mail.To = "REMEMBER TO ENCRYPT EMAIL BEFORE SENDING!!!"
$mail.bcc = ""
$mail.Body = "$body"
$mail.save()
$inspector = $mail.GetInspector
$inspector.Display()
}
####### add words to the dictionary to increase your "vocabulary" :) Google search "Grade School Vocab lists" #######
$Dictionary = @('Accident','Ache','Adjust','Affordable','Agree','Alarm','Alone','Apologize','Appetite','Applause','Arrive','Artistic','Astronomy','Atlas','Atmosphere','Attach','Attention','Award','Aware','Balance','Banner','Bare','Base','Bashful','Basket','Batch','Beach','Behave','Belong','Bend','Besides','Blast','Blink','Blush','Board','Bolt','Bolts','Borrow','Bounce','Brain','Branch','Brave','Bright','Bundle','Cabin','Cage','Calf','Calm','Career','Caterpillar','Caution','Cave','Celebrate','Centaur','Center','Champion','Chat','Cheat','Cheer','Chew','Chimney','Claw','Clear','Cliff','Club','Collect','Compass','Complain','Conductor','Connect','Construct','Core','Corner','Costume','Couple','Cozy','Cranky','Crash','Creak','Croak','Crowd','Crowded','Cue','Curious','Curved','Daily','Dainty','Damp','Dangerous','Dart','Dash','Dawn','Decorate','Deep','Delighted','Demolish','Denied','Deserve','Design','Discard','Dive','Divide','Dodge','Dome','Doubt','Dozen','Drenched','Drowsy','Earth','Enemy','Enormous','Equal','Evening','Exactly','Excess','Exclaim','Exhausted','Expensive','Factory','Fair','Famous','Fancy','Fasten','Feast','Field','Filthy','Finally','Flap','Flat','Flee','Float','Flood','Fog','Fold','Footprint','Forest','Freezing','Fresh','Frighten','Fuel','Gap','Gather','Gaze','Giant','Gift','Glad','Gleaming','Glum','Grab','Grateful','Gravity','Greedy','Grin','Grip','Groan','Harm','Hatch','Heap','Herd','Hide','Hobby','Honest','Howl','Idea','Illustrator','Injury','Insect','Instrument','Invent','Island','Jealous','Knob','Leader','Leap','Lively','Lizard','Local','Lonely','Loosen','Luxury','March','Mask','Mention','Misty','Modern','Motor','Mountain','Narrow','Nervous','Net','Nibble','Notice','Obey','Ocean','Pack','Pain','Pale','Parade','Passenger','Past','Pattern','Peak','Pest','Planet','Polish','Present','Pretend','Promise','Proof','Rapid','Reflect','Remove','Repeat','Rescue','Restart','Return','Ripe','Rise','Roar','Rough','Rumor','Rusty','Safe','Scholar','Scold','Scratch','Seal','Search','Seed','Selfish','Serious','Settle','Share','Shell','Shelter','Shiver','Shovel','Shriek','Shy','Sibling','Silent','Simple','Skill','Slight','Slippery','Sly','Smooth','Sneaky','Sob','Soil','Spiral','Splendid','Sprinkle','Squirm','Stack','Startle','Steady','Steep','Stormy','Strand','Stream','Striped','Support','Surround','Switch','Team','Telescope','Terrified','Thick','Thunder','Ticket','Timid','Tiny','Tower','Transportation','Travel','Tremble','Trust','Universe','Upset','Village','Warn','Weak','Wealthy','Whimper','Whirl','Whisper','Wicked','Wise','Wonder','Word','Worry','Yank','Yard','Zigzag')





function Generate_click {
####### This is the magic that actually generates the password #######    
    
$random = $dictionary |get-random -count 3
$base = $random -join " "
$number = get-random -minimum 10 -maximum 99
$PW = "$base $number" 
####### Adjust if All Lowercase is checked #######
If ($Lowercase.Checked -eq $true){$PWBox.text =$PW.ToLower()} Else {$PWBox.text =$PW}
$count.text = ($pw | Measure-Object -Character).Characters
}

function Copy_Click {$PWBox.text|clip }
#endregion

[void]$Form.ShowDialog()
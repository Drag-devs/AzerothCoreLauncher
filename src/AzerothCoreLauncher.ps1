[CmdletBinding()]
param(
    [ValidateSet('Gui', 'StartAll', 'StopAll', 'RestartAll', 'StartAuthserver', 'StopAuthserver', 'RestartAuthserver', 'StartWorldserver', 'StopWorldserver', 'RestartWorldserver', 'Preflight')]
    [string]$Action = 'Gui',

    [string]$ProfileId,

    [switch]$Headless
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    $script:RootPath = Split-Path -Parent $PSCommandPath
}
else {
    $executablePath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $executableDirectory = Split-Path -Parent $executablePath
    $script:RootPath = Join-Path $executableDirectory 'src'
}

if (-not (Test-Path -LiteralPath (Join-Path $script:RootPath 'Modules\ProfileStore.psm1') -PathType Leaf)) {
    throw "Launcher resources were not found at '$script:RootPath'. Keep AzerothCoreLauncher.exe beside src, build, and assets."
}

Import-Module (Join-Path $script:RootPath 'Modules\ProfileStore.psm1') -Force
Import-Module (Join-Path $script:RootPath 'Modules\AzerothConfig.psm1') -Force
Import-Module (Join-Path $script:RootPath 'Modules\ServerController.psm1') -Force
Import-Module (Join-Path $script:RootPath 'Modules\HealthMonitor.psm1') -Force
Import-Module (Join-Path $script:RootPath 'Modules\ScheduledStartup.psm1') -Force
$script:DataRoot = Initialize-AclDataStore

function Get-AclSelectedProfile {
    param([string]$RequestedProfileId)

    $profiles = @(Get-AclProfiles -DataRoot $script:DataRoot)
    if ($profiles.Count -eq 0) {
        throw 'No server profile exists. Create one in the GUI first.'
    }
    if ([string]::IsNullOrWhiteSpace($RequestedProfileId)) {
        if ($profiles.Count -eq 1) { return $profiles[0] }
        throw 'Specify -ProfileId when more than one profile exists.'
    }
    $profileMatches = @($profiles | Where-Object { $_.Id -eq $RequestedProfileId })
    $profile = if ($profileMatches.Count -gt 0) { $profileMatches[0] } else { $null }
    if ($null -eq $profile) { throw "Profile '$RequestedProfileId' was not found." }
    return $profile
}

function Invoke-AclHeadlessAction {
    param([psobject]$Profile, [string]$RequestedAction)

    switch ($RequestedAction) {
        'StartAll' { return Start-AclAll -Profile $Profile -DataRoot $script:DataRoot }
        'StopAll' { return Stop-AclAll -Profile $Profile -DataRoot $script:DataRoot }
        'RestartAll' { return Restart-AclAll -Profile $Profile -DataRoot $script:DataRoot }
        'StartAuthserver' { return Start-AclServer -Profile $Profile -Server Authserver -DataRoot $script:DataRoot }
        'StopAuthserver' { return Stop-AclServer -Profile $Profile -Server Authserver -DataRoot $script:DataRoot }
        'RestartAuthserver' { return Restart-AclServer -Profile $Profile -Server Authserver -DataRoot $script:DataRoot }
        'StartWorldserver' { return Start-AclServer -Profile $Profile -Server Worldserver -DataRoot $script:DataRoot }
        'StopWorldserver' { return Stop-AclServer -Profile $Profile -Server Worldserver -DataRoot $script:DataRoot }
        'RestartWorldserver' { return Restart-AclServer -Profile $Profile -Server Worldserver -DataRoot $script:DataRoot }
        'Preflight' {
            return [pscustomobject]@{
                Authserver = Test-AclServerPreflight -Profile $Profile -Server Authserver
                Worldserver = Test-AclServerPreflight -Profile $Profile -Server Worldserver
            }
        }
        default { throw "Unsupported headless action '$RequestedAction'." }
    }
}

function Resolve-AclServerInstallDirectory {
    param([Parameter(Mandatory)][string]$SelectedPath)

    $selectedPath = [IO.Path]::GetFullPath($SelectedPath)
    if ((Test-Path -LiteralPath (Join-Path $selectedPath 'authserver.exe') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $selectedPath 'worldserver.exe') -PathType Leaf)) {
        return $selectedPath
    }

    $authExecutable = Get-ChildItem -LiteralPath $selectedPath -Filter 'authserver.exe' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.DirectoryName 'worldserver.exe') -PathType Leaf } |
        Select-Object -First 1
    if ($null -eq $authExecutable) {
        throw "No folder containing both authserver.exe and worldserver.exe was found under '$selectedPath'."
    }
    return $authExecutable.DirectoryName
}

function Show-AclProfileDialog {
    param([psobject]$ExistingProfile)

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
    $dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="AzerothCore Launcher - Profile" SizeToContent="WidthAndHeight" WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <Grid Margin="18"><Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="360"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <TextBlock Grid.Row="0" Text="Name" VerticalAlignment="Center" Margin="0,0,10,10"/><TextBox x:Name="NameBox" Grid.Row="0" Grid.Column="1" Margin="0,0,0,10"/>
    <TextBlock Grid.Row="1" Text="Install folder" VerticalAlignment="Center" Margin="0,0,10,10"/><TextBox x:Name="InstallBox" Grid.Row="1" Grid.Column="1" Margin="0,0,0,10"/><Button x:Name="BrowseButton" Grid.Row="1" Grid.Column="2" Content="Browse" Margin="8,0,0,10"/>
    <TextBlock Grid.Row="2" Text="Auth config" VerticalAlignment="Center" Margin="0,0,10,10"/><TextBox x:Name="AuthBox" Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="2" Margin="0,0,0,10"/>
    <TextBlock Grid.Row="3" Text="World config" VerticalAlignment="Center" Margin="0,0,10,0"/><TextBox x:Name="WorldBox" Grid.Row="3" Grid.Column="1" Grid.ColumnSpan="2" Margin="0,0,0,0"/>
  </Grid>
</Window>
'@
    $dialog = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$dialogXaml)))
    $nameBox = $dialog.FindName('NameBox'); $installBox = $dialog.FindName('InstallBox')
    $authBox = $dialog.FindName('AuthBox'); $worldBox = $dialog.FindName('WorldBox')
    $browseButton = $dialog.FindName('BrowseButton')
    if ($null -ne $ExistingProfile) {
        $nameBox.Text = $ExistingProfile.Name; $installBox.Text = $ExistingProfile.InstallPath
        $authBox.Text = $ExistingProfile.AuthConfigPath; $worldBox.Text = $ExistingProfile.WorldConfigPath
    }
    $browseButton.Add_Click({
        $browser = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($browser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            try {
                $installDirectory = Resolve-AclServerInstallDirectory -SelectedPath $browser.SelectedPath
                $installBox.Text = $installDirectory
                $authBox.Text = Join-Path $installDirectory 'configs\authserver.conf'
                $worldBox.Text = Join-Path $installDirectory 'configs\worldserver.conf'
            }
            catch {
                [System.Windows.MessageBox]::Show($_.Exception.Message, 'Server Profile') | Out-Null
            }
        }
    })
    $okButton = New-Object System.Windows.Controls.Button -Property @{ Content = 'Save'; IsDefault = $true; Width = 80; Margin = '0,18,8,0' }
    $cancelButton = New-Object System.Windows.Controls.Button -Property @{ Content = 'Cancel'; IsCancel = $true; Width = 80; Margin = '0,18,0,0' }
    $buttonPanel = New-Object System.Windows.Controls.StackPanel -Property @{ Orientation = 'Horizontal'; HorizontalAlignment = 'Right' }
    [void]$buttonPanel.Children.Add($okButton); [void]$buttonPanel.Children.Add($cancelButton)
    [System.Windows.Controls.Grid]::SetRow($buttonPanel, 4); [System.Windows.Controls.Grid]::SetColumnSpan($buttonPanel, 3)
    [void]$dialog.Content.Children.Add($buttonPanel)
    $okButton.Add_Click({ $dialog.DialogResult = $true })
    if ($dialog.ShowDialog() -ne $true) { return $null }
    if ([string]::IsNullOrWhiteSpace($nameBox.Text) -or [string]::IsNullOrWhiteSpace($installBox.Text)) {
        [System.Windows.MessageBox]::Show('Name and install folder are required.', 'Server Profile') | Out-Null
        return $null
    }
    $profile = if ($null -eq $ExistingProfile) { New-AclProfile -Name $nameBox.Text -InstallPath $installBox.Text -AuthConfigPath $authBox.Text -WorldConfigPath $worldBox.Text } else { $ExistingProfile }
    $profile.Name = $nameBox.Text; $profile.InstallPath = [IO.Path]::GetFullPath($installBox.Text)
    $profile.AuthConfigPath = Resolve-AclProfilePath -Path $authBox.Text -InstallPath $profile.InstallPath
    $profile.WorldConfigPath = Resolve-AclProfilePath -Path $worldBox.Text -InstallPath $profile.InstallPath
    return $profile
}

function Start-AclGui {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
    $xamlPath = Join-Path $script:RootPath 'Views\MainWindow.xaml'
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml](Get-Content -LiteralPath $xamlPath -Raw))))
    $controls = @{}
    @('ProfileSelector','NewProfileButton','EditProfileButton','ImportProfileButton','DeleteProfileButton','StartAllButton','StopAllButton','RestartAllButton','RecoverySettingsButton','SnapshotButton','AuthState','AuthDetails','AuthLog','WorldState','WorldDetails','WorldLog','StartAuthButton','StopAuthButton','RestartAuthButton','EditAuthConfigButton','StartWorldButton','StopWorldButton','RestartWorldButton','EditWorldConfigButton','SqlStatus','TaskStatus','ScheduledMode','ScheduledDelay','SaveTaskButton','RunTaskButton','RemoveTaskButton','OpenInstallButton','LogSelector','LogFilter','ManagerLog','ActivityText') | ForEach-Object { $controls[$_] = $window.FindName($_) }
    $activity = New-Object 'System.Collections.Generic.List[string]'
    $script:AclStartAllJob = $null
    $script:AclRecoveryJob = $null
    $getProfile = { return $controls.ProfileSelector.SelectedItem }
    $renderLog = {
        $selection = $controls.LogSelector.SelectedItem
        $lines = @()
        if ($null -eq $selection -or $selection.Kind -eq 'Manager') {
            $lines = @($activity)
        }
        else {
            $lines = @(Get-AclConfiguredLogTail -LogDefinition $selection.LogDefinition)
            if ($lines.Count -eq 0) {
                $lines = @("No file is currently available for $($selection.DisplayName).")
            }
        }

        $filter = $controls.LogFilter.Text
        if (-not [string]::IsNullOrWhiteSpace($filter)) {
            $lines = @($lines | Where-Object { $_ -match [regex]::Escape($filter) })
        }
        $controls.ManagerLog.Text = $lines -join [Environment]::NewLine
        $controls.ManagerLog.ScrollToEnd()
    }
    $writeActivity = {
        param([string]$Message)
        $entry = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
        $activity.Add($entry)
        & $renderLog
        $controls.ActivityText.Text = $Message
    }
    $refreshConfiguredLogs = {
        $selectedKey = if ($null -ne $controls.LogSelector.SelectedItem) { $controls.LogSelector.SelectedItem.Key } else { 'manager' }
        $items = @([pscustomobject]@{ Key = 'manager'; DisplayName = 'Manager activity'; Kind = 'Manager'; LogDefinition = $null })
        $profile = & $getProfile
        if ($null -ne $profile) {
            try {
                foreach ($server in @('Authserver', 'Worldserver')) {
                    $definition = Get-AzerothServerDefinition -Profile $profile -Server $server
                    foreach ($logDefinition in $definition.LogDefinitions) {
                        $items += [pscustomobject]@{
                            Key = "{0}:{1}" -f $server, $logDefinition.Appender
                            DisplayName = "{0}: {1}" -f $server, $logDefinition.FileName
                            Kind = 'Server'
                            LogDefinition = $logDefinition
                        }
                    }
                }
            }
            catch {
                $controls.ActivityText.Text = "Profile configuration unavailable: $($_.Exception.Message)"
            }
        }
        $controls.LogSelector.ItemsSource = $items
        $selectedItems = @($items | Where-Object { $_.Key -eq $selectedKey })
        $controls.LogSelector.SelectedItem = if ($selectedItems.Count -gt 0) { $selectedItems[0] } else { $items[0] }
        & $renderLog
    }
    $refreshProfiles = {
        $selectedId = if ($null -ne $controls.ProfileSelector.SelectedItem) { $controls.ProfileSelector.SelectedItem.Id } else { '' }
        $profiles = @(Get-AclProfiles -DataRoot $script:DataRoot)
        $controls.ProfileSelector.ItemsSource = $profiles
        $selectedProfiles = @($profiles | Where-Object { $_.Id -eq $selectedId })
        $controls.ProfileSelector.SelectedItem = if ($selectedProfiles.Count -gt 0) { $selectedProfiles[0] } else { $null }
        if ($null -eq $controls.ProfileSelector.SelectedItem -and $profiles.Count -gt 0) { $controls.ProfileSelector.SelectedIndex = 0 }
    }
    $setServerDisplay = {
        param([string]$Prefix, [psobject]$Health)
        $controls["${Prefix}State"].Text = $Health.State
        $controls["${Prefix}State"].Foreground = switch ($Health.State) { 'Online' { '#2E7D5B' } 'Failed' { '#B33939' } 'Degraded' { '#B06A00' } default { '#687A80' } }
        $uptime = if ($null -ne $Health.Uptime) { (' Uptime {0:dd\.hh\:mm\:ss}' -f $Health.Uptime) } else { '' }
        $controls["${Prefix}Details"].Text = "Port $($Health.Port)  PID $($Health.ProcessId)$uptime  $($Health.Message)"
        $controls["${Prefix}Log"].Text = $Health.LastLogLine
    }
    $refreshHealth = {
        $profile = & $getProfile
        if ($null -eq $profile) { return }
        try {
            $authHealth = Get-AclServerHealth -Profile $profile -Server Authserver -DataRoot $script:DataRoot
            $worldHealth = Get-AclServerHealth -Profile $profile -Server Worldserver -DataRoot $script:DataRoot
            & $setServerDisplay 'Auth' $authHealth
            & $setServerDisplay 'World' $worldHealth
            $sqlStatus = Get-AclSqlServerStatus -Profile $profile
            $sqlEndpoints = @($sqlStatus.Servers | ForEach-Object { "{0}:{1}" -f $_.HostName, $_.Port }) -join ', '
            $controls.SqlStatus.Text = if ($sqlStatus.IsOnline) { "SQL: Online ($sqlEndpoints)" } else { "SQL: Unavailable ($sqlEndpoints)" }
            $controls.SqlStatus.Foreground = if ($sqlStatus.IsOnline) { '#2E7D5B' } else { '#B33939' }
            $authActive = $authHealth.State -notin @('Stopped', 'Failed')
            $worldActive = $worldHealth.State -notin @('Stopped', 'Failed')
            $canStart = $sqlStatus.IsOnline
            $controls.StartAuthButton.IsEnabled = $canStart -and $authHealth.State -ne 'Online'
            $controls.StopAuthButton.IsEnabled = $authActive
            $controls.RestartAuthButton.IsEnabled = $authActive
            $controls.StartWorldButton.IsEnabled = $canStart -and $worldHealth.State -ne 'Online'
            $controls.StopWorldButton.IsEnabled = $worldActive
            $controls.RestartWorldButton.IsEnabled = $worldActive
            $controls.StartAllButton.IsEnabled = $canStart -and ($authHealth.State -ne 'Online' -or $worldHealth.State -ne 'Online')
            $controls.StopAllButton.IsEnabled = $authActive -or $worldActive
            $controls.RestartAllButton.IsEnabled = $authActive -or $worldActive
            $task = Get-AclScheduledStartup -Profile $profile
            $controls.TaskStatus.Text = if ($task.Exists) { "Task $($task.Name): $($task.State), account $($task.Account), delay $($task.DelaySeconds)s, last result $($task.LastResult)" } else { 'No scheduled startup configured.' }
        }
        catch { & $writeActivity $_.Exception.Message }
    }
    $invokeAction = {
        param([scriptblock]$Operation, [string]$Label)
        try { & $writeActivity "$Label..."; & $Operation | Out-Null; & $writeActivity "$Label completed." }
        catch { & $writeActivity "$Label failed: $($_.Exception.Message)"; [System.Windows.MessageBox]::Show($_.Exception.Message, 'AzerothCore Launcher') | Out-Null }
        finally { & $refreshHealth }
    }
    $controls.NewProfileButton.Add_Click({ $profile = Show-AclProfileDialog; if ($null -ne $profile) { Save-AclProfile -Profile $profile -DataRoot $script:DataRoot | Out-Null; & $refreshProfiles; & $writeActivity "Created profile '$($profile.Name)'." } })
    $controls.EditProfileButton.Add_Click({ $profile = Show-AclProfileDialog -ExistingProfile (& $getProfile); if ($null -ne $profile) { Save-AclProfile -Profile $profile -DataRoot $script:DataRoot | Out-Null; & $refreshProfiles; & $writeActivity "Saved profile '$($profile.Name)'." } })
    $controls.ImportProfileButton.Add_Click({ $picker = New-Object System.Windows.Forms.OpenFileDialog; $picker.Filter = 'Profile JSON (*.json)|*.json'; if ($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $profile = Get-Content -LiteralPath $picker.FileName -Raw | ConvertFrom-Json; $profile.Id = [guid]::NewGuid().ToString(); Save-AclProfile -Profile $profile -DataRoot $script:DataRoot | Out-Null; & $refreshProfiles; & $writeActivity "Imported profile '$($profile.Name)'." } })
    $controls.DeleteProfileButton.Add_Click({
        $profile = & $getProfile
        if ($null -eq $profile) { return }
        $authHealth = Get-AclServerHealth -Profile $profile -Server Authserver -DataRoot $script:DataRoot
        $worldHealth = Get-AclServerHealth -Profile $profile -Server Worldserver -DataRoot $script:DataRoot
        if ($authHealth.State -notin @('Stopped', 'Failed') -or $worldHealth.State -notin @('Stopped', 'Failed')) {
            [System.Windows.MessageBox]::Show('Stop both managed servers before deleting this profile.', 'AzerothCore Manager') | Out-Null
            return
        }
        $confirmation = [System.Windows.MessageBox]::Show("Delete profile '$($profile.Name)' and its scheduled startup task?", 'AzerothCore Manager', 'YesNo', 'Warning')
        if ($confirmation -ne [System.Windows.MessageBoxResult]::Yes) { return }
        try {
            Remove-AclScheduledStartup -Profile $profile -Confirm:$false
            Remove-AclProfile -ProfileId $profile.Id -DataRoot $script:DataRoot -Confirm:$false
            & $refreshProfiles
            & $refreshHealth
            & $writeActivity "Deleted profile '$($profile.Name)'."
        }
        catch {
            & $writeActivity "Deleting profile '$($profile.Name)' failed: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'AzerothCore Manager') | Out-Null
        }
    })
    $controls.ProfileSelector.Add_SelectionChanged({ & $refreshConfiguredLogs; & $refreshHealth })
    $controls.LogSelector.Add_SelectionChanged({ & $renderLog })
    $controls.LogFilter.Add_TextChanged({ & $renderLog })
    $controls.StartAllButton.Add_Click({
        $profile = & $getProfile
        if ($null -eq $profile -or $null -ne $script:AclStartAllJob) { return }
        $script:AclStartAllJob = Start-Job -ArgumentList $profile, $script:DataRoot, $script:RootPath -ScriptBlock {
            param($jobProfile, $jobDataRoot, $jobRootPath)
            Import-Module (Join-Path $jobRootPath 'Modules\ProfileStore.psm1') -Force
            Import-Module (Join-Path $jobRootPath 'Modules\AzerothConfig.psm1') -Force
            Import-Module (Join-Path $jobRootPath 'Modules\ServerController.psm1') -Force
            Import-Module (Join-Path $jobRootPath 'Modules\HealthMonitor.psm1') -Force
            Start-AclAll -Profile $jobProfile -DataRoot $jobDataRoot
        }
        & $writeActivity 'Starting all servers in the background.'
    })
    $controls.RecoverySettingsButton.Add_Click({
        $profile = & $getProfile
        if ($null -eq $profile) { return }
        if ($null -eq $profile.PSObject.Properties['Recovery']) {
            $profile | Add-Member -NotePropertyName Recovery -NotePropertyValue ([pscustomobject]@{ Enabled=$false; RecoverAuthserver=$true; RecoverWorldserver=$true; MaxAttempts=5; InitialDelaySeconds=5; BackoffMultiplier=2; HealthyResetMinutes=10; RequireSqlOnline=$true })
        }
    $dialogXaml = @'
    <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Recovery Settings" SizeToContent="WidthAndHeight" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"><Grid Margin="18"><Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="110"/></Grid.ColumnDefinitions><CheckBox x:Name="Enabled" Grid.Row="0" Grid.ColumnSpan="2" Content="Enable automatic recovery"/><CheckBox x:Name="Auth" Grid.Row="1" Grid.ColumnSpan="2" Content="Recover Authserver"/><CheckBox x:Name="World" Grid.Row="2" Grid.ColumnSpan="2" Content="Recover Worldserver"/><CheckBox x:Name="Sql" Grid.Row="3" Grid.ColumnSpan="2" Content="Require SQL to be online"/><TextBlock Grid.Row="4" Text="Maximum attempts"/><TextBox x:Name="Attempts" Grid.Row="4" Grid.Column="1"/><TextBlock Grid.Row="5" Text="Initial delay (seconds)"/><TextBox x:Name="Delay" Grid.Row="5" Grid.Column="1"/><TextBlock Grid.Row="6" Text="Backoff multiplier"/><TextBox x:Name="Backoff" Grid.Row="6" Grid.Column="1"/><TextBlock Grid.Row="7" Text="Healthy reset (minutes)"/><TextBox x:Name="Healthy" Grid.Row="7" Grid.Column="1"/></Grid></Window>
'@
        
        $dialog = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$dialogXaml)))
        foreach ($name in @('Enabled','Auth','World','Sql','Attempts','Delay','Backoff','Healthy')) { Set-Variable -Name $name -Value $dialog.FindName($name) }
        $Enabled.IsChecked=$profile.Recovery.Enabled; $Auth.IsChecked=$profile.Recovery.RecoverAuthserver; $World.IsChecked=$profile.Recovery.RecoverWorldserver; $Sql.IsChecked=$profile.Recovery.RequireSqlOnline
        $Attempts.Text=$profile.Recovery.MaxAttempts; $Delay.Text=$profile.Recovery.InitialDelaySeconds; $Backoff.Text=$profile.Recovery.BackoffMultiplier; $Healthy.Text=$profile.Recovery.HealthyResetMinutes
        $save = New-Object System.Windows.Controls.Button -Property @{Content='Save';IsDefault=$true;Width=80}; $cancel = New-Object System.Windows.Controls.Button -Property @{Content='Cancel';IsCancel=$true;Width=80;Margin='8,0,0,0'}; $buttons=New-Object System.Windows.Controls.StackPanel -Property @{Orientation='Horizontal';HorizontalAlignment='Right';Margin='0,14,0,0'}; [void]$buttons.Children.Add($save);[void]$buttons.Children.Add($cancel);[System.Windows.Controls.Grid]::SetRow($buttons,8);[System.Windows.Controls.Grid]::SetColumnSpan($buttons,2);[void]$dialog.Content.Children.Add($buttons);$save.Add_Click({$dialog.DialogResult=$true})
        if ($dialog.ShowDialog() -ne $true) { return }
        $profile.Recovery.Enabled=[bool]$Enabled.IsChecked; $profile.Recovery.RecoverAuthserver=[bool]$Auth.IsChecked; $profile.Recovery.RecoverWorldserver=[bool]$World.IsChecked; $profile.Recovery.RequireSqlOnline=[bool]$Sql.IsChecked
        $profile.Recovery.MaxAttempts=[Math]::Min(20,[Math]::Max(1,[int]$Attempts.Text)); $profile.Recovery.InitialDelaySeconds=[Math]::Min(300,[Math]::Max(1,[int]$Delay.Text)); $profile.Recovery.BackoffMultiplier=[Math]::Min(5,[Math]::Max(1,[int]$Backoff.Text)); $profile.Recovery.HealthyResetMinutes=[Math]::Min(1440,[Math]::Max(1,[int]$Healthy.Text))
        Save-AclProfile -Profile $profile -DataRoot $script:DataRoot | Out-Null
        & $writeActivity "Saved recovery settings for '$($profile.Name)'."
    })
    $controls.StopAllButton.Add_Click({ $profile = & $getProfile; & $writeActivity 'Canceling automatic recovery for Authserver and Worldserver.'; & $invokeAction { Stop-AclAll -Profile $profile -DataRoot $script:DataRoot } 'Stopping all servers' })
    $controls.RestartAllButton.Add_Click({ $profile = & $getProfile; & $invokeAction { Restart-AclAll -Profile $profile -DataRoot $script:DataRoot } 'Restarting all servers' })
    $controls.StartAuthButton.Add_Click({ $profile = & $getProfile; & $invokeAction { Start-AclServer -Profile $profile -Server Authserver -DataRoot $script:DataRoot } 'Starting Authserver' })
    $controls.StopAuthButton.Add_Click({ $profile = & $getProfile; & $writeActivity 'Canceling automatic recovery for Authserver.'; & $invokeAction { Stop-AclServer -Profile $profile -Server Authserver -DataRoot $script:DataRoot } 'Stopping Authserver' })
    $controls.RestartAuthButton.Add_Click({ $profile = & $getProfile; & $invokeAction { Restart-AclServer -Profile $profile -Server Authserver -DataRoot $script:DataRoot } 'Restarting Authserver' })
    $controls.StartWorldButton.Add_Click({ $profile = & $getProfile; & $invokeAction { Start-AclServer -Profile $profile -Server Worldserver -DataRoot $script:DataRoot } 'Starting Worldserver' })
    $controls.StopWorldButton.Add_Click({ $profile = & $getProfile; & $writeActivity 'Canceling automatic recovery for Worldserver.'; & $invokeAction { Stop-AclServer -Profile $profile -Server Worldserver -DataRoot $script:DataRoot } 'Stopping Worldserver' })
    $controls.RestartWorldButton.Add_Click({ $profile = & $getProfile; & $invokeAction { Restart-AclServer -Profile $profile -Server Worldserver -DataRoot $script:DataRoot } 'Restarting Worldserver' })
    $controls.EditAuthConfigButton.Add_Click({ $profile = & $getProfile; if ($null -ne $profile) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $profile.AuthConfigPath) } })
    $controls.EditWorldConfigButton.Add_Click({ $profile = & $getProfile; if ($null -ne $profile) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $profile.WorldConfigPath) } })
    $controls.OpenInstallButton.Add_Click({ $profile = & $getProfile; if ($null -ne $profile) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $profile.InstallPath) } })
    $controls.SaveTaskButton.Add_Click({
        $profile = & $getProfile
        $mode = $controls.ScheduledMode.SelectedItem.Content
        $delay = [int]$controls.ScheduledDelay.Text
        $launcherPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { $PSCommandPath } else { [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
        & $invokeAction { Set-AclScheduledStartup -Profile $profile -Mode $mode -ScriptPath $launcherPath -DelaySeconds $delay } 'Saving scheduled startup'
    })
    $controls.RunTaskButton.Add_Click({ $profile = & $getProfile; & $invokeAction { Start-AclScheduledStartupNow -Profile $profile } 'Running scheduled startup task' })
    $controls.RemoveTaskButton.Add_Click({ $profile = & $getProfile; & $invokeAction { Remove-AclScheduledStartup -Profile $profile -Confirm:$false } 'Removing scheduled startup task' })
    $controls.SnapshotButton.Add_Click({ $profile = & $getProfile; $picker = New-Object System.Windows.Forms.SaveFileDialog; $picker.Filter = 'Zip archive (*.zip)|*.zip'; $picker.FileName = 'AzerothCoreSupportSnapshot.zip'; if ($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { & $invokeAction { Export-AclSupportSnapshot -Profile $profile -DestinationPath $picker.FileName } 'Exporting support snapshot' } })
    & $refreshProfiles; & $refreshConfiguredLogs; & $refreshHealth; & $writeActivity 'Manager ready.'
    $timer = New-Object System.Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromSeconds(3); $timer.Add_Tick({
        if ($null -ne $script:AclStartAllJob -and $script:AclStartAllJob.State -in @('Completed', 'Failed', 'Stopped')) {
            $jobOutput = Receive-Job -Job $script:AclStartAllJob -Keep -ErrorAction SilentlyContinue
            if ($script:AclStartAllJob.State -eq 'Completed') { & $writeActivity 'Ordered server startup completed.' }
            else { & $writeActivity "Ordered server startup ended: $jobOutput" }
            Remove-Job -Job $script:AclStartAllJob -Force
            $script:AclStartAllJob = $null
        }
        if ($null -ne $script:AclRecoveryJob -and $script:AclRecoveryJob.State -in @('Completed', 'Failed', 'Stopped')) {
            $recoveryOutput = @(Receive-Job -Job $script:AclRecoveryJob -ErrorAction SilentlyContinue)
            foreach ($recoveryMessage in $recoveryOutput) {
                if ($null -ne $recoveryMessage -and -not [string]::IsNullOrWhiteSpace([string]$recoveryMessage.Message)) {
                    & $writeActivity $recoveryMessage.Message
                }
            }
            if ($script:AclRecoveryJob.State -ne 'Completed') {
                & $writeActivity 'Automatic recovery supervisor ended unexpectedly.'
            }
            Remove-Job -Job $script:AclRecoveryJob -Force
            $script:AclRecoveryJob = $null
        }
        $profile = & $getProfile
        $recoveryEnabled = $null -ne $profile -and $null -ne $profile.PSObject.Properties['Recovery'] -and [bool]$profile.Recovery.Enabled
        if ($null -eq $script:AclRecoveryJob -and $recoveryEnabled) {
            $script:AclRecoveryJob = Start-Job -ArgumentList $profile, $script:DataRoot, $script:RootPath -ScriptBlock {
                param($jobProfile, $jobDataRoot, $jobRootPath)
                Import-Module (Join-Path $jobRootPath 'Modules\ProfileStore.psm1') -Force
                Import-Module (Join-Path $jobRootPath 'Modules\AzerothConfig.psm1') -Force
                Import-Module (Join-Path $jobRootPath 'Modules\ServerController.psm1') -Force
                Import-Module (Join-Path $jobRootPath 'Modules\HealthMonitor.psm1') -Force
                Invoke-AclRecoverySupervisor -Profile $jobProfile -DataRoot $jobDataRoot
            }
        }
        & $refreshHealth; & $renderLog
    }); $timer.Start()
    [void]$window.ShowDialog(); $timer.Stop()
}

if ($Action -eq 'Gui' -and -not $Headless) {
    Start-AclGui
}
else {
    $profile = Get-AclSelectedProfile -RequestedProfileId $ProfileId
    Invoke-AclHeadlessAction -Profile $profile -RequestedAction $Action | ConvertTo-Json -Depth 8
}
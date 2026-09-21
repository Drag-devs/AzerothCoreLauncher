Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ProfileStore.psm1') -ErrorAction Stop

function Test-AclAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-AclElevatedTaskOperation {
    param([psobject]$Profile, [ValidateSet('Set', 'Remove', 'Run')][string]$Operation, [string]$Mode, [string]$ScriptPath, [int]$DelaySeconds)
    $payloadPath = Join-Path ([IO.Path]::GetTempPath()) ("AclTask-{0}.json" -f [guid]::NewGuid())
    $helperPath = "$payloadPath.ps1"
    $Profile | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $payloadPath -Encoding UTF8
    @"
`$ErrorActionPreference = 'Stop'
Import-Module '$PSScriptRoot\ScheduledStartup.psm1' -Force
`$profile = Get-Content -LiteralPath '$payloadPath' -Raw | ConvertFrom-Json
if ('$Operation' -eq 'Set') { Set-AclScheduledStartup -Profile `$profile -Mode '$Mode' -ScriptPath '$ScriptPath' -DelaySeconds $DelaySeconds -SkipElevation }
elseif ('$Operation' -eq 'Remove') { Remove-AclScheduledStartup -Profile `$profile -SkipElevation }
else { Start-AclScheduledStartupNow -Profile `$profile -SkipElevation }
"@ | Set-Content -LiteralPath $helperPath -Encoding UTF8
    try {
        $process = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$helperPath`""
        if ($process.ExitCode -ne 0) { throw "Elevated Task Scheduler operation failed with exit code $($process.ExitCode)." }
    }
    finally { Remove-Item -LiteralPath $payloadPath, $helperPath -Force -ErrorAction SilentlyContinue }
}

function Get-AclScheduledTaskName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile
    )

    return "AzerothCoreLauncher-$($Profile.Id)"
}

function ConvertTo-AclXmlEscapedText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)

    return [System.Security.SecurityElement]::Escape($Value)
}

function New-AclScheduledTaskXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [Parameter(Mandatory)]
        [ValidateSet('SystemStartup', 'CurrentUserLogon')]
        [string]$Mode,

        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [ValidateRange(0, 86400)]
        [int]$DelaySeconds = 30
    )

    $launcherPath = [IO.Path]::GetFullPath($ScriptPath)
    $escapedLauncherPath = ConvertTo-AclXmlEscapedText -Value $launcherPath
    $escapedProfileId = ConvertTo-AclXmlEscapedText -Value $Profile.Id
    $action = 'ScheduledStart'
    if ([IO.Path]::GetExtension($launcherPath) -ieq '.exe') {
        $command = $escapedLauncherPath
        $arguments = "-Action $action -ProfileId `"$escapedProfileId`""
    }
    else {
        $command = 'powershell.exe'
        $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$escapedLauncherPath`" -Action $action -ProfileId `"$escapedProfileId`""
    }
    $delay = "PT{0}S" -f $DelaySeconds
    $trigger = if ($Mode -eq 'SystemStartup') {
@"
    <BootTrigger>
      <Enabled>true</Enabled>
      <Delay>$delay</Delay>
    </BootTrigger>
"@
    }
    else {
@"
    <LogonTrigger>
      <Enabled>true</Enabled>
      <Delay>$delay</Delay>
    </LogonTrigger>
"@
    }
    $principal = if ($Mode -eq 'SystemStartup') {
@'
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <LogonType>ServiceAccount</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
'@
    }
    else {
@'
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
'@
    }

    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Starts all AzerothCore services for profile $($Profile.Name).</Description></RegistrationInfo>
  <Triggers>
$trigger  </Triggers>
  <Principals>
$principal  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>$command</Command><Arguments>$arguments</Arguments></Exec>
  </Actions>
</Task>
"@
}

function Get-AclScheduledStartup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile
    )

    $taskName = Get-AclScheduledTaskName -Profile $Profile
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        return [pscustomobject]@{ Exists = $false; Name = $taskName; State = 'Not configured'; LastResult = $null; Account = ''; DelaySeconds = $null }
    }

    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    $delay = $null
    $trigger = $task.Triggers | Select-Object -First 1
    if ($null -ne $trigger -and $trigger.Delay) {
        $delay = [System.Xml.XmlConvert]::ToTimeSpan([string]$trigger.Delay).TotalSeconds
    }
    return [pscustomobject]@{
        Exists = $true
        Name = $taskName
        State = [string]$task.State
        LastResult = if ($null -ne $taskInfo) { $taskInfo.LastTaskResult } else { $null }
        Account = [string]$task.Principal.UserId
        DelaySeconds = $delay
    }
}

function Set-AclScheduledStartup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [Parameter(Mandatory)]
        [ValidateSet('SystemStartup', 'CurrentUserLogon')]
        [string]$Mode,

        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [switch]$SkipElevation,

        [ValidateRange(0, 86400)]
        [int]$DelaySeconds = 30
    )

    if (-not $SkipElevation -and -not (Test-AclAdministrator)) { Invoke-AclElevatedTaskOperation -Profile $Profile -Operation Set -Mode $Mode -ScriptPath $ScriptPath -DelaySeconds $DelaySeconds; return (Get-AclScheduledStartup -Profile $Profile) }

    if ($Mode -eq 'SystemStartup' -and $Profile.InstallPath -match '^(?:\\\\|[A-Za-z]:\\Users\\)') {
        Write-Warning 'SYSTEM startup may not be able to access this user-only or network path.'
    }

    $taskName = Get-AclScheduledTaskName -Profile $Profile
    $xml = New-AclScheduledTaskXml -Profile $Profile -Mode $Mode -ScriptPath $ScriptPath -DelaySeconds $DelaySeconds
    Register-ScheduledTask -TaskName $taskName -Xml $xml -Force | Out-Null
    return (Get-AclScheduledStartup -Profile $Profile)
}

function Start-AclScheduledStartupNow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Profile, [switch]$SkipElevation)

    if (-not $SkipElevation -and -not (Test-AclAdministrator)) { Invoke-AclElevatedTaskOperation -Profile $Profile -Operation Run; return }

    Start-ScheduledTask -TaskName (Get-AclScheduledTaskName -Profile $Profile)
}

function Remove-AclScheduledStartup {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][psobject]$Profile, [switch]$SkipElevation)

    if (-not $SkipElevation -and -not (Test-AclAdministrator)) { Invoke-AclElevatedTaskOperation -Profile $Profile -Operation Remove; return }

    $taskName = Get-AclScheduledTaskName -Profile $Profile
    if ($PSCmdlet.ShouldProcess($taskName, 'Remove scheduled startup task')) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Get-AclScheduledTaskName, New-AclScheduledTaskXml, Get-AclScheduledStartup, Set-AclScheduledStartup, Start-AclScheduledStartupNow, Remove-AclScheduledStartup
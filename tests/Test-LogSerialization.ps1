#requires -Version 5.1
[CmdletBinding()]
param([string]$ExecutablePath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourceRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('AclLogSerialization-' + [guid]::NewGuid().ToString('N'))

function Assert-PlainLogText {
    param([AllowEmptyString()][string]$Expected, [AllowEmptyString()][object]$Actual)

    if ($Actual -isnot [string] -or $Actual -cne $Expected) {
        throw 'The log reader changed the text or returned a non-string value.'
    }
    foreach ($propertyName in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider', 'ReadCount')) {
        if ($null -ne $Actual.PSObject.Properties[$propertyName]) {
            throw "Log text still carries $propertyName metadata; refusing deep JSON serialization."
        }
    }
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    Import-Module (Join-Path $sourceRoot 'Modules\HealthMonitor.psm1') -Force

    $logPath = Join-Path $testRoot 'World.log'
    $logText = @('World initialization', '', 'AzerothCore (worldserver-daemon) ready...', 'Calendar deletion of old events.')
    [IO.File]::WriteAllLines($logPath, $logText)
    $logDefinition = [pscustomobject]@{ PathPattern = $logPath }
    $rawLine = Get-Content -LiteralPath $logPath -Tail 1
    if ($PSVersionTable.PSVersion.Major -eq 5 -and $null -eq $rawLine.PSObject.Properties['PSProvider']) {
        throw 'The fixture did not reproduce the PowerShell 5.1 provider-enriched string.'
    }

    $lastLine = Get-AclRecentLogLine -LogDirectory $testRoot -LogDefinitions @($logDefinition)
    Assert-PlainLogText -Expected $logText[-1] -Actual $lastLine
    $tail = @(Get-AclConfiguredLogTail -LogDefinition $logDefinition -TailLines $logText.Count)
    if ($tail.Count -ne $logText.Count) { throw 'The configured log tail has the wrong number of lines.' }
    for ($lineIndex = 0; $lineIndex -lt $tail.Count; $lineIndex++) {
        Assert-PlainLogText -Expected $logText[$lineIndex] -Actual $tail[$lineIndex]
    }

    $health = [pscustomobject]@{
        Server = 'Worldserver'
        State = 'Online'
        ProcessId = 1234
        Uptime = [TimeSpan]::FromMinutes(3)
        Port = 8085
        IsTcpReachable = $true
        LastLogLine = $lastLine
        Message = 'Ready.'
    }
    $runtime = [pscustomobject]@{ ProcessId = 1234; State = 'Starting'; StartedUtc = [DateTime]::UtcNow.ToString('o'); IntentionalStop = $false }
    $result = [pscustomobject]@{ Authserver = $runtime; AuthHealth = $health; Worldserver = $runtime; WorldHealth = $health }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $json = $result | ConvertTo-Json -Depth 8
    $stopwatch.Stop()
    if ($json.Length -gt 32768 -or $json -match '"PSProvider"|"PSDrive"') {
        throw 'Health result JSON expanded unexpectedly.'
    }
    $roundTrip = $json | ConvertFrom-Json
    if ($roundTrip.WorldHealth.LastLogLine -cne $logText[-1]) { throw 'Log text did not survive the JSON round trip.' }
    Write-Output "PASS: actual log readers return plain strings; StartAll-shaped JSON is $($json.Length) characters ($($stopwatch.ElapsedMilliseconds) ms)."

    [IO.File]::WriteAllText($logPath, '')
    Assert-PlainLogText -Expected '' -Actual (Get-AclRecentLogLine -LogDirectory $testRoot -LogDefinitions @($logDefinition))
    if (@(Get-AclConfiguredLogTail -LogDefinition $logDefinition).Count -ne 0) { throw 'Empty logs should return an empty tail.' }
    $missingLog = [pscustomobject]@{ PathPattern = (Join-Path $testRoot 'Missing.log') }
    Assert-PlainLogText -Expected '' -Actual (Get-AclRecentLogLine -LogDirectory $testRoot -LogDefinitions @($missingLog))
    if (@(Get-AclConfiguredLogTail -LogDefinition $missingLog).Count -ne 0) { throw 'Missing logs should return an empty tail.' }
    Write-Output 'PASS: empty and missing logs remain safe.'

    Copy-Item -LiteralPath $sourceRoot -Destination $testRoot -Recurse
    $installPath = Join-Path $testRoot 'server'
    $configsPath = Join-Path $installPath 'configs'
    $profilesPath = Join-Path $testRoot 'data\Profiles'
    New-Item -ItemType Directory -Path $configsPath, $profilesPath -Force | Out-Null
    foreach ($server in @('authserver', 'worldserver')) {
        [IO.File]::WriteAllText((Join-Path $installPath "$server.exe"), '')
        [IO.File]::WriteAllLines((Join-Path $configsPath "$server.conf"), @(
            'RealmServerPort = 0'
            'WorldServerPort = 0'
            'LogsDir = "logs"'
            'LoginDatabaseInfo = "localhost;3306;test;do-not-persist-this-password;auth"'
        ))
    }
    $testProfile = [pscustomobject]@{
        Id = [guid]::NewGuid().ToString()
        Name = 'Serialization regression'
        InstallPath = $installPath
        AuthConfigPath = Join-Path $configsPath 'authserver.conf'
        WorldConfigPath = Join-Path $configsPath 'worldserver.conf'
    }
    $testProfile | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $profilesPath "$($testProfile.Id).json") -Encoding UTF8
    $output = @(& (Join-Path $testRoot 'src\AzerothCoreLauncher.ps1') -Action Preflight -ProfileId $testProfile.Id)
    if ($output.Count -ne 0) { throw 'Action mode emitted output to the host instead of saving the result.' }
    $resultPath = Join-Path $testRoot "data\Logs\action-Preflight-$($testProfile.Id).json"
    $savedJson = Get-Content -LiteralPath $resultPath -Raw
    if ($savedJson -match 'do-not-persist-this-password|LoginDatabaseInfo') { throw 'The result file contains config credentials.' }
    $savedResult = $savedJson | ConvertFrom-Json
    if (-not $savedResult.Authserver.IsValid -or -not $savedResult.Worldserver.IsValid) { throw 'Disposable preflight failed.' }
    Write-Output 'PASS: the actual Preflight entry point saves a per-profile result without host output or config credentials.'

    if (-not [string]::IsNullOrWhiteSpace($ExecutablePath)) {
        $testExecutable = Join-Path $testRoot 'AzerothCoreLauncher.exe'
        Copy-Item -LiteralPath $ExecutablePath -Destination $testExecutable
        Remove-Item -LiteralPath $resultPath
        $child = Start-Process -FilePath $testExecutable -ArgumentList @('-Action', 'Preflight', '-ProfileId', $testProfile.Id) -PassThru
        try {
            if (-not $child.WaitForExit(15000)) { throw 'The compiled Preflight action did not finish within the diagnostic limit.' }
            if ($child.ExitCode -ne 0) { throw "Compiled Preflight exited with code $($child.ExitCode)." }
            $savedJson = Get-Content -LiteralPath $resultPath -Raw
            $savedResult = $savedJson | ConvertFrom-Json
            if (-not $savedResult.Authserver.IsValid -or -not $savedResult.Worldserver.IsValid) { throw 'Compiled Preflight did not save successful results.' }
            if ($savedJson -match 'do-not-persist-this-password|LoginDatabaseInfo') { throw 'Compiled Preflight persisted config credentials.' }
            Write-Output 'PASS: rebuilt EXE completed the isolated Preflight action and wrote its result without a GUI output prompt.'
        }
        finally {
            if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
            $child.Dispose()
        }
    }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
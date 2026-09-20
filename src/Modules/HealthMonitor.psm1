Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ProfileStore.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'AzerothConfig.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ServerController.psm1') -ErrorAction Stop

function Test-AclTcpEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HostName,

        [Parameter(Mandatory)]
        [int]$Port,

        [int]$TimeoutMilliseconds = 1500
    )

    if ($Port -le 0) {
        return $false
    }

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $result = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $result.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            return $false
        }
        $client.EndConnect($result)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Get-AclSqlServerStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile
    )

    $servers = @()
    $groups = @(Get-AzerothDatabaseEndpoints -Profile $Profile | Group-Object { "{0}:{1}" -f $_.HostName, $_.Port })
    foreach ($group in $groups) {
        $endpoint = $group.Group[0]
        $servers += [pscustomobject]@{
            HostName = $endpoint.HostName
            Port = $endpoint.Port
            IsReachable = Test-AclTcpEndpoint -HostName $endpoint.HostName -Port $endpoint.Port
            UsedBy = @($group.Group | ForEach-Object { "$($_.Server) $($_.Setting)" })
        }
    }

    return [pscustomobject]@{
        Servers = @($servers)
        IsOnline = $servers.Count -gt 0 -and @($servers | Where-Object { -not $_.IsReachable }).Count -eq 0
    }
}

function Get-AclLatestConfiguredLogFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject[]]$LogDefinitions
    )

    $files = @()
    foreach ($logDefinition in $LogDefinitions) {
        $directory = Split-Path -Parent $logDefinition.PathPattern
        $filter = (Split-Path -Leaf $logDefinition.PathPattern) -replace '%s', '*'
        $files += @(Get-ChildItem -LiteralPath $directory -Filter $filter -File -ErrorAction SilentlyContinue)
    }
    $orderedFiles = @($files | Sort-Object LastWriteTimeUtc -Descending)
    if ($orderedFiles.Count -eq 0) {
        return $null
    }
    return $orderedFiles[0]
}

function Get-AclConfiguredLogTail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$LogDefinition,

        [int]$TailLines = 300
    )

    $logFile = Get-AclLatestConfiguredLogFile -LogDefinitions @($LogDefinition)
    if ($null -eq $logFile) {
        return @()
    }
    return @(Get-Content -LiteralPath $logFile.FullName -Tail $TailLines -ErrorAction SilentlyContinue)
}

function Get-AclRecentLogLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogDirectory,

        [psobject[]]$LogDefinitions = @(),

        [int]$TailLines = 100
    )

    $logFile = if ($LogDefinitions.Count -gt 0) {
        Get-AclLatestConfiguredLogFile -LogDefinitions $LogDefinitions
    }
    else {
        Get-ChildItem -LiteralPath $LogDirectory -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
    }
    if ($null -eq $logFile) {
        return ''
    }

    $meaningfulLines = @(Get-Content -LiteralPath $logFile.FullName -Tail $TailLines -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($meaningfulLines.Count -eq 0) {
        return ''
    }
    return $meaningfulLines[-1]
}

function Test-AclWorldserverReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogDirectory,

        [psobject[]]$LogDefinitions = @(),

        [int]$TailLines = 500
    )

    $logFile = if ($LogDefinitions.Count -gt 0) {
        Get-AclLatestConfiguredLogFile -LogDefinitions $LogDefinitions
    }
    else {
        Get-ChildItem -LiteralPath $LogDirectory -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
    }
    if ($null -eq $logFile) {
        return $false
    }

    $readyLines = @(Get-Content -LiteralPath $logFile.FullName -Tail $TailLines -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '(?i)worldserver.*ready|world.*initialized|ready for connections' })
    return $readyLines.Count -gt 0
}

function Get-AclServerHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [Parameter(Mandatory)]
        [ValidateSet('Authserver', 'Worldserver')]
        [string]$Server,

        [string]$DataRoot = (Get-AclDataRoot)
    )

    $definition = Get-AzerothServerDefinition -Profile $Profile -Server $Server
    $runtime = Get-AclServerRuntime -Profile $Profile -Server $Server -DataRoot $DataRoot
    $processes = @()
    if ($null -ne $runtime) {
        $processes = @(Get-Process -Id $runtime.ProcessId -ErrorAction SilentlyContinue)
    }
    $process = if ($processes.Count -gt 0) { $processes[0] } else { $null }
    $lastLogLine = Get-AclRecentLogLine -LogDirectory $definition.LogDirectory -LogDefinitions $definition.PrimaryLogDefinitions
    $databaseFailure = $lastLogLine -match '(?i)(database|mysql).*(fail|error|unable|cannot|could not connect)|could not connect.*(database|mysql)'

    if ($null -eq $process) {
        $state = if ($null -ne $runtime -and -not $runtime.IntentionalStop) { 'Failed' } else { 'Stopped' }
        return [pscustomobject]@{
            Server = $Server; State = $state; ProcessId = $null; Uptime = $null; Port = $definition.Port
            IsTcpReachable = $false; LastLogLine = $lastLogLine; Message = if ($databaseFailure) { 'Database startup failure detected in the log.' } elseif ($state -eq 'Failed') { 'Process exited unexpectedly.' } else { 'Not running.' }
        }
    }

    $tcpReady = Test-AclTcpEndpoint -HostName $definition.BindAddress -Port $definition.Port
    $worldReady = $Server -ne 'Worldserver' -or $runtime.State -eq 'Online' -or (Test-AclWorldserverReadiness -LogDirectory $definition.LogDirectory -LogDefinitions $definition.PrimaryLogDefinitions)
    $state = if ($tcpReady -and $worldReady) { 'Online' } elseif ($databaseFailure) { 'Failed' } elseif ($tcpReady) { 'Degraded' } else { 'Starting' }
    if ($null -ne $runtime -and $runtime.State -eq 'Stopping') { $state = 'Stopping' }
    if ($Server -eq 'Worldserver' -and $state -eq 'Online' -and $runtime.State -ne 'Online') {
        $runtime.State = 'Online'
        Set-AclServerRuntime -Profile $Profile -Server $Server -Runtime $runtime -DataRoot $DataRoot
    }
    $uptime = ([DateTime]::Now).Subtract([DateTime]$process.StartTime)

    return [pscustomobject]@{
        Server = $Server
        State = $state
        ProcessId = $process.Id
        Uptime = $uptime
        Port = $definition.Port
        IsTcpReachable = $tcpReady
        LastLogLine = $lastLogLine
        Message = if ($databaseFailure) { 'Database startup failure detected in the log.' } elseif ($state -eq 'Online') { 'Ready.' } else { 'Waiting for readiness.' }
    }
}

function Wait-AclServerReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [Parameter(Mandatory)]
        [ValidateSet('Authserver', 'Worldserver')]
        [string]$Server,

        [int]$TimeoutSeconds = 0,

        [string]$DataRoot = (Get-AclDataRoot)
    )

    while ($true) {
        $health = Get-AclServerHealth -Profile $Profile -Server $Server -DataRoot $DataRoot
        if ($health.State -eq 'Online') { return $health }
        if ($health.State -eq 'Failed') { throw "$Server failed to start: $($health.Message)" }
        Start-Sleep -Milliseconds 500
    }
}

function Start-AclAll {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [int]$TimeoutSeconds = 0,

        [string]$DataRoot = (Get-AclDataRoot)
    )

    $authRuntime = Start-AclServer -Profile $Profile -Server Authserver -DataRoot $DataRoot
    $authHealth = Wait-AclServerReady -Profile $Profile -Server Authserver -TimeoutSeconds $TimeoutSeconds -DataRoot $DataRoot
    $worldRuntime = Start-AclServer -Profile $Profile -Server Worldserver -DataRoot $DataRoot
    $worldHealth = Wait-AclServerReady -Profile $Profile -Server Worldserver -TimeoutSeconds $TimeoutSeconds -DataRoot $DataRoot
    return [pscustomobject]@{ Authserver = $authRuntime; AuthHealth = $authHealth; Worldserver = $worldRuntime; WorldHealth = $worldHealth }
}

function Stop-AclAll {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [int]$TimeoutSeconds = 30,

        [switch]$Force,

        [string]$DataRoot = (Get-AclDataRoot)
    )

    $worldResult = Stop-AclServer -Profile $Profile -Server Worldserver -TimeoutSeconds $TimeoutSeconds -Force:$Force -DataRoot $DataRoot
    $authResult = Stop-AclServer -Profile $Profile -Server Authserver -TimeoutSeconds $TimeoutSeconds -Force:$Force -DataRoot $DataRoot
    return [pscustomobject]@{ Worldserver = $worldResult; Authserver = $authResult }
}

function Restart-AclAll {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [int]$TimeoutSeconds = 0,

        [string]$DataRoot = (Get-AclDataRoot)
    )

    $stopResult = Stop-AclAll -Profile $Profile -TimeoutSeconds $TimeoutSeconds -DataRoot $DataRoot
    if ($stopResult.Worldserver.State -eq 'Stopping' -or $stopResult.Authserver.State -eq 'Stopping') {
        return $stopResult
    }
    return (Start-AclAll -Profile $Profile -TimeoutSeconds $TimeoutSeconds -DataRoot $DataRoot)
}

function Export-AclSupportSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("AzerothCoreLauncher-{0}" -f [guid]::NewGuid())
    New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
    try {
        $safeProfile = $Profile | Select-Object Id, Name, InstallPath, AuthConfigPath, WorldConfigPath, CrashRestartEnabled, Startup
        $safeProfile | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $temporaryDirectory 'profile.json') -Encoding UTF8
        foreach ($server in @('Authserver', 'Worldserver')) {
            $definition = Get-AzerothServerDefinition -Profile $Profile -Server $server
            Get-AzerothConfigRedactedText -Path $definition.ConfigPath | Set-Content -LiteralPath (Join-Path $temporaryDirectory ("{0}.conf.txt" -f $server)) -Encoding UTF8
            Get-AclServerHealth -Profile $Profile -Server $server | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $temporaryDirectory ("{0}.health.json" -f $server)) -Encoding UTF8
            Get-ChildItem -LiteralPath $definition.LogDirectory -Filter '*.log' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First 2 |
                ForEach-Object { Get-Content -LiteralPath $_.FullName -Tail 200 | Set-Content -LiteralPath (Join-Path $temporaryDirectory ("{0}-{1}" -f $server, $_.Name)) -Encoding UTF8 }
        }
        Compress-Archive -Path (Join-Path $temporaryDirectory '*') -DestinationPath $DestinationPath -Force
        return $DestinationPath
    }
    finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Test-AclTcpEndpoint, Get-AclSqlServerStatus, Get-AclLatestConfiguredLogFile, Get-AclConfiguredLogTail, Get-AclRecentLogLine, Test-AclWorldserverReadiness, Get-AclServerHealth, Wait-AclServerReady, Start-AclAll, Stop-AclAll, Restart-AclAll, Export-AclSupportSnapshot
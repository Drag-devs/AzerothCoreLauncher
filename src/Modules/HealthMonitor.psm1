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
    return @(Get-Content -LiteralPath $logFile.FullName -Tail $TailLines -ErrorAction SilentlyContinue |
        ForEach-Object { $_.ToString() })
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
    return $meaningfulLines[-1].ToString()
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

        [psobject]$Definition,

        [string]$DataRoot = (Get-AclDataRoot)
    )

    if ($null -eq $Definition) {
        $Definition = Get-AzerothServerDefinition -Profile $Profile -Server $Server
    }
    $definition = $Definition
    $runtime = Get-AclServerRuntime -Profile $Profile -Server $Server -DataRoot $DataRoot
    $processes = @()
    if ($null -ne $runtime -and $null -ne $runtime.ProcessId) {
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

function Get-AclRecoveryPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile
    )

    $defaults = @{
        Enabled = $false
        RecoverAuthserver = $true
        RecoverWorldserver = $true
        MaxAttempts = 5
        InitialDelaySeconds = 5
        BackoffMultiplier = 2
        HealthyResetMinutes = 10
        RequireSqlOnline = $true
    }
    $recovery = if ($null -ne $Profile.PSObject.Properties['Recovery']) { $Profile.Recovery } else { $null }
    $values = @{}
    foreach ($name in $defaults.Keys) {
        $values[$name] = if ($null -ne $recovery -and $null -ne $recovery.PSObject.Properties[$name]) { $recovery.$name } else { $defaults[$name] }
    }

    return [pscustomobject]@{
        Enabled = [bool]$values.Enabled
        RecoverAuthserver = [bool]$values.RecoverAuthserver
        RecoverWorldserver = [bool]$values.RecoverWorldserver
        MaxAttempts = [Math]::Max(1, [int]$values.MaxAttempts)
        InitialDelaySeconds = [Math]::Max(1, [int]$values.InitialDelaySeconds)
        BackoffMultiplier = [Math]::Max(1, [double]$values.BackoffMultiplier)
        HealthyResetMinutes = [Math]::Max(1, [int]$values.HealthyResetMinutes)
        RequireSqlOnline = [bool]$values.RequireSqlOnline
    }
}

function Get-AclRecoveryDelaySeconds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Policy,

        [Parameter(Mandatory)]
        [int]$Attempt
    )

    $delay = [double]$Policy.InitialDelaySeconds * [Math]::Pow([double]$Policy.BackoffMultiplier, [Math]::Max(0, $Attempt))
    return [Math]::Min(86400, [Math]::Max(1, [int][Math]::Ceiling($delay)))
}

function Invoke-AclRecoverySupervisor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [string]$DataRoot = (Get-AclDataRoot)
    )

    $policy = Get-AclRecoveryPolicy -Profile $Profile
    if (-not $policy.Enabled) {
        return @()
    }

    $sqlOnline = if ($policy.RequireSqlOnline) { (Get-AclSqlServerStatus -Profile $Profile).IsOnline } else { $true }
    $authHealth = Get-AclServerHealth -Profile $Profile -Server Authserver -DataRoot $DataRoot
    $authOnline = $authHealth.State -eq 'Online'
    $messages = New-Object 'System.Collections.Generic.List[object]'

    foreach ($server in @('Authserver', 'Worldserver')) {
        $enabled = if ($server -eq 'Authserver') { $policy.RecoverAuthserver } else { $policy.RecoverWorldserver }
        if (-not $enabled) {
            continue
        }

        $runtime = Get-AclServerRuntime -Profile $Profile -Server $server -DataRoot $DataRoot
        if ($null -eq $runtime -or $runtime.IntentionalStop -or ($null -ne $runtime.PSObject.Properties['RecoveryCanceled'] -and $runtime.RecoveryCanceled)) {
            continue
        }
        $runtime = Initialize-AclRecoveryRuntime -Runtime $runtime

        $process = if ($null -ne $runtime.ProcessId) { Get-Process -Id $runtime.ProcessId -ErrorAction SilentlyContinue } else { $null }
        if ($null -ne $process) {
            $health = if ($server -eq 'Authserver') { $authHealth } else { Get-AclServerHealth -Profile $Profile -Server $server -DataRoot $DataRoot }
            if ($health.State -eq 'Online') {
                if ([string]::IsNullOrWhiteSpace([string]$runtime.HealthySinceUtc)) {
                    $runtime.HealthySinceUtc = [DateTime]::UtcNow.ToString('o')
                    Set-AclServerRuntime -Profile $Profile -Server $server -Runtime $runtime -DataRoot $DataRoot
                }
                elseif ($runtime.RetryAttempt -gt 0 -and ([DateTime]::UtcNow - [DateTime]$runtime.HealthySinceUtc).TotalMinutes -ge $policy.HealthyResetMinutes) {
                    $runtime.RetryAttempt = 0
                    $runtime.RecoveryState = 'Idle'
                    Set-AclServerRuntime -Profile $Profile -Server $server -Runtime $runtime -DataRoot $DataRoot
                    $messages.Add([pscustomobject]@{ Server = $server; Message = "$server recovery attempts reset after the healthy period." })
                }
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$runtime.HealthySinceUtc)) {
                $runtime.HealthySinceUtc = ''
                Set-AclServerRuntime -Profile $Profile -Server $server -Runtime $runtime -DataRoot $DataRoot
            }
            continue
        }

        if ($runtime.RetryAttempt -ge $policy.MaxAttempts) {
            if ($runtime.RecoveryState -ne 'Exhausted') {
                $runtime.RecoveryState = 'Exhausted'
                $runtime.NextRetryUtc = ''
                $runtime.LastExitReason = 'Recovery retry limit reached'
                Set-AclServerRuntime -Profile $Profile -Server $server -Runtime $runtime -DataRoot $DataRoot
                $messages.Add([pscustomobject]@{ Server = $server; Message = "$server recovery canceled after $($policy.MaxAttempts) failed retry attempts." })
            }
            continue
        }

        $now = [DateTime]::UtcNow
        $nextRetryUtc = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$runtime.NextRetryUtc)) {
            try { $nextRetryUtc = ([DateTime]$runtime.NextRetryUtc).ToUniversalTime() } catch { $nextRetryUtc = $null }
        }
        if ($null -eq $nextRetryUtc) {
            $delaySeconds = Get-AclRecoveryDelaySeconds -Policy $policy -Attempt $runtime.RetryAttempt
            $nextRetryUtc = $now.AddSeconds($delaySeconds)
            $runtime.ProcessId = $null
            $runtime.State = 'RecoveryPending'
            $runtime.LastExitReason = 'Process exited unexpectedly'
            $runtime.RecoveryState = 'Pending'
            $runtime.HealthySinceUtc = ''
            $runtime.NextRetryUtc = $nextRetryUtc.ToString('o')
            Set-AclServerRuntime -Profile $Profile -Server $server -Runtime $runtime -DataRoot $DataRoot
            $messages.Add([pscustomobject]@{ Server = $server; Message = "$server exited unexpectedly. Recovery attempt $($runtime.RetryAttempt + 1) is pending at $($nextRetryUtc.ToLocalTime().ToString('T'))." })
            continue
        }

        if ($now -lt $nextRetryUtc) {
            continue
        }

        $blockedReason = if (-not $sqlOnline) { 'SQL is unavailable' } elseif ($server -eq 'Worldserver' -and -not $authOnline) { 'Authserver is not online' } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($blockedReason)) {
            $delaySeconds = Get-AclRecoveryDelaySeconds -Policy $policy -Attempt $runtime.RetryAttempt
            $runtime.NextRetryUtc = $now.AddSeconds($delaySeconds).ToString('o')
            $runtime.RecoveryState = 'Waiting'
            Set-AclServerRuntime -Profile $Profile -Server $server -Runtime $runtime -DataRoot $DataRoot
            $messages.Add([pscustomobject]@{ Server = $server; Message = "$server recovery is waiting because $blockedReason. Next retry is at $(([DateTime]$runtime.NextRetryUtc).ToLocalTime().ToString('T'))." })
            continue
        }

        try {
            $nextAttempt = [int]$runtime.RetryAttempt + 1
            $restartedRuntime = Start-AclServer -Profile $Profile -Server $server -DataRoot $DataRoot
            $restartedRuntime.RetryAttempt = $nextAttempt
            $restartedRuntime.RecoveryState = 'Recovering'
            $restartedRuntime.NextRetryUtc = ''
            Set-AclServerRuntime -Profile $Profile -Server $server -Runtime $restartedRuntime -DataRoot $DataRoot
            $messages.Add([pscustomobject]@{ Server = $server; Message = "$server recovery retry $nextAttempt of $($policy.MaxAttempts) started." })
            if ($server -eq 'Authserver') { $authOnline = $false }
        }
        catch {
            $runtime.RetryAttempt = [int]$runtime.RetryAttempt + 1
            $delaySeconds = Get-AclRecoveryDelaySeconds -Policy $policy -Attempt $runtime.RetryAttempt
            $runtime.State = 'RecoveryPending'
            $runtime.RecoveryState = 'Pending'
            $runtime.NextRetryUtc = $now.AddSeconds($delaySeconds).ToString('o')
            $runtime.LastExitReason = $_.Exception.Message
            Set-AclServerRuntime -Profile $Profile -Server $server -Runtime $runtime -DataRoot $DataRoot
            $messages.Add([pscustomobject]@{ Server = $server; Message = "$server recovery retry failed: $($_.Exception.Message). Next retry is at $(([DateTime]$runtime.NextRetryUtc).ToLocalTime().ToString('T'))." })
        }
    }

    return $messages.ToArray()
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

    $definition = Get-AzerothServerDefinition -Profile $Profile -Server $Server
    while ($true) {
        $health = Get-AclServerHealth -Profile $Profile -Server $Server -Definition $definition -DataRoot $DataRoot
        if ($health.State -eq 'Online') { return $health }
        if ($health.State -eq 'Failed') { throw "$Server failed to start: $($health.Message)" }
        Start-Sleep -Seconds 2
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

Export-ModuleMember -Function Test-AclTcpEndpoint, Get-AclSqlServerStatus, Get-AclLatestConfiguredLogFile, Get-AclConfiguredLogTail, Get-AclRecentLogLine, Test-AclWorldserverReadiness, Get-AclServerHealth, Invoke-AclRecoverySupervisor, Wait-AclServerReady, Start-AclAll, Stop-AclAll, Restart-AclAll, Export-AclSupportSnapshot
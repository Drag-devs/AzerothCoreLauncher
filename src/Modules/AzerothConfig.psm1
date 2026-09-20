Set-StrictMode -Version Latest

function Get-AzerothConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$Path
    )

    $settings = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*([A-Za-z][A-Za-z0-9_.]*)\s*=\s*(.*?)\s*$') {
            $key = $matches[1]
            $value = $matches[2].Trim()
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            $settings[$key] = $value
        }
    }

    return $settings
}

function Get-AzerothConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [Parameter(Mandatory)]
        [string[]]$Name,

        [string]$DefaultValue = ''
    )

    foreach ($candidate in $Name) {
        if ($Settings.ContainsKey($candidate) -and -not [string]::IsNullOrWhiteSpace($Settings[$candidate])) {
            return [string]$Settings[$candidate]
        }
    }
    return $DefaultValue
}

function Resolve-AzerothPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$BasePath
    )

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Get-AzerothConfiguredLogs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [Parameter(Mandatory)]
        [string]$LogDirectory
    )

    $rootAppenders = @()
    if ($Settings.ContainsKey('Logger.root')) {
        $rootParts = @([string]$Settings['Logger.root'] -split ',', 2)
        if ($rootParts.Count -gt 1) {
            $rootAppenders = @($rootParts[1] -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }

    $logs = @()
    foreach ($setting in @($Settings.GetEnumerator() | Where-Object { $_.Key -like 'Appender.*' })) {
        $parts = @([string]$setting.Value -split ',', 5)
        if ($parts.Count -lt 4 -or $parts[0].Trim() -ne '2') {
            continue
        }

        $fileName = $parts[3].Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($fileName)) {
            continue
        }

        $appenderName = $setting.Key.Substring('Appender.'.Length)
        $logs += [pscustomobject]@{
            Appender = $appenderName
            FileName = $fileName
            PathPattern = Resolve-AzerothPath -Path $fileName -BasePath $LogDirectory
            IsDynamic = $fileName -match '%s'
            IsRootAppender = $rootAppenders -contains $appenderName
        }
    }

    return @($logs | Sort-Object Appender)
}

function Get-AzerothServerDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [Parameter(Mandatory)]
        [ValidateSet('Authserver', 'Worldserver')]
        [string]$Server
    )

    $isAuth = $Server -eq 'Authserver'
    $workingDirectory = [IO.Path]::GetFullPath([string]$Profile.InstallPath)
    $configuredConfigPath = if ($isAuth) { [string]$Profile.AuthConfigPath } else { [string]$Profile.WorldConfigPath }
    $configPath = Resolve-AzerothPath -Path $configuredConfigPath -BasePath $workingDirectory
    $settings = Get-AzerothConfig -Path $configPath
    $executableName = if ($isAuth) { 'authserver.exe' } else { 'worldserver.exe' }
    $portNames = if ($isAuth) { @('RealmServerPort') } else { @('WorldServerPort', 'WorldServerPort') }
    $port = Get-AzerothConfigValue -Settings $settings -Name $portNames -DefaultValue '0'
    $bindAddress = Get-AzerothConfigValue -Settings $settings -Name @('BindIP') -DefaultValue '127.0.0.1'
    if ($bindAddress -eq '0.0.0.0' -or [string]::IsNullOrWhiteSpace($bindAddress)) {
        $bindAddress = '127.0.0.1'
    }
    $logsDirectory = if ($settings.ContainsKey('LogsDir')) { [string]$settings['LogsDir'] } else { 'logs' }
    $logDirectory = if ([string]::IsNullOrWhiteSpace($logsDirectory)) { $workingDirectory } else { Resolve-AzerothPath -Path $logsDirectory -BasePath $workingDirectory }
    $logDefinitions = @(Get-AzerothConfiguredLogs -Settings $settings -LogDirectory $logDirectory)
    $primaryLogDefinitions = @($logDefinitions | Where-Object { $_.IsRootAppender })
    if ($primaryLogDefinitions.Count -eq 0) {
        $primaryLogDefinitions = $logDefinitions
    }

    return [pscustomobject]@{
        Server = $Server
        ExecutablePath = Join-Path $workingDirectory $executableName
        WorkingDirectory = $workingDirectory
        ConfigPath = $configPath
        LogDirectory = $logDirectory
        BindAddress = $bindAddress
        Port = [int]$port
        Settings = $settings
        LogDefinitions = $logDefinitions
        PrimaryLogDefinitions = $primaryLogDefinitions
    }
}

function Get-AzerothDatabaseEndpoints {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile
    )

    $endpoints = @()
    foreach ($server in @('Authserver', 'Worldserver')) {
        $definition = Get-AzerothServerDefinition -Profile $Profile -Server $server
        foreach ($settingName in @('LoginDatabaseInfo', 'WorldDatabaseInfo', 'CharacterDatabaseInfo')) {
            if (-not $definition.Settings.ContainsKey($settingName) -or [string]::IsNullOrWhiteSpace($definition.Settings[$settingName])) {
                continue
            }

            $parts = @([string]$definition.Settings[$settingName] -split ';')
            if ($parts.Count -lt 2) {
                continue
            }
            $port = 0
            if (-not [int]::TryParse($parts[1], [ref]$port) -or $port -le 0) {
                continue
            }
            $hostName = if ([string]::IsNullOrWhiteSpace($parts[0])) { '127.0.0.1' } else { $parts[0] }
            $endpoints += [pscustomobject]@{
                Server = $server
                Setting = $settingName
                HostName = $hostName
                Port = $port
            }
        }
    }

    return @($endpoints)
}

function Get-AzerothConfigRedactedText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $text = Get-Content -LiteralPath $Path -Raw
    return [regex]::Replace($text, '(?im)^(\s*(?:Login|World|Character)DatabaseInfo\s*=\s*")[^"]*("\s*)$', '$1[REDACTED]$2')
}

Export-ModuleMember -Function Get-AzerothConfig, Get-AzerothConfigValue, Resolve-AzerothPath, Get-AzerothConfiguredLogs, Get-AzerothServerDefinition, Get-AzerothDatabaseEndpoints, Get-AzerothConfigRedactedText
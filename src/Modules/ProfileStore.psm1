Set-StrictMode -Version Latest

function Get-AclDataRoot {
    [CmdletBinding()]
    param()

    $distributionRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    return (Join-Path $distributionRoot 'data')
}

function Initialize-AclDataStore {
    [CmdletBinding()]
    param(
        [string]$DataRoot = (Get-AclDataRoot)
    )

    foreach ($path in @($DataRoot, (Join-Path $DataRoot 'Profiles'), (Join-Path $DataRoot 'Logs'), (Join-Path $DataRoot 'Runtime'))) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    return $DataRoot
}

function New-AclProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$InstallPath,

        [string]$AuthConfigPath,

        [string]$WorldConfigPath
    )

    $installPath = [IO.Path]::GetFullPath($InstallPath)
    if ([string]::IsNullOrWhiteSpace($AuthConfigPath)) {
        $AuthConfigPath = Join-Path $installPath 'configs\authserver.conf'
    }
    if ([string]::IsNullOrWhiteSpace($WorldConfigPath)) {
        $WorldConfigPath = Join-Path $installPath 'configs\worldserver.conf'
    }

    return [pscustomobject]@{
        Id = [guid]::NewGuid().ToString()
        Name = $Name
        InstallPath = $installPath
        AuthConfigPath = Resolve-AclProfilePath -Path $AuthConfigPath -InstallPath $installPath
        WorldConfigPath = Resolve-AclProfilePath -Path $WorldConfigPath -InstallPath $installPath
        CrashRestartEnabled = $false
        Recovery = [pscustomobject]@{
            Enabled = $false
            RecoverAuthserver = $true
            RecoverWorldserver = $true
            MaxAttempts = 5
            InitialDelaySeconds = 5
            BackoffMultiplier = 2
            HealthyResetMinutes = 10
            RequireSqlOnline = $true
        }
        Startup = [pscustomobject]@{
            Mode = 'Disabled'
            DelaySeconds = 30
            TaskName = ''
        }
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Resolve-AclProfilePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$InstallPath
    )

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $InstallPath $Path))
}

function Test-AclProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile
    )

    $errors = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrWhiteSpace([string]$Profile.Name)) {
        $errors.Add('Profile name is required.')
    }
    if (-not (Test-Path -LiteralPath $Profile.InstallPath -PathType Container)) {
        $errors.Add("Install path does not exist: $($Profile.InstallPath)")
    }
    foreach ($configPath in @($Profile.AuthConfigPath, $Profile.WorldConfigPath)) {
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            $errors.Add("Configuration file does not exist: $configPath")
        }
    }

    return [pscustomobject]@{
        IsValid = $errors.Count -eq 0
        Errors = @($errors)
    }
}

function Get-AclProfiles {
    [CmdletBinding()]
    param(
        [string]$DataRoot = (Get-AclDataRoot)
    )

    $profilesPath = Join-Path (Initialize-AclDataStore -DataRoot $DataRoot) 'Profiles'
    $profiles = @()
    foreach ($profileFile in Get-ChildItem -LiteralPath $profilesPath -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        try {
            $profiles += (Get-Content -LiteralPath $profileFile.FullName -Raw | ConvertFrom-Json)
        }
        catch {
            Write-Warning "Skipping invalid profile '$($profileFile.Name)': $($_.Exception.Message)"
        }
    }

    return @($profiles | Sort-Object Name)
}

function Save-AclProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [string]$DataRoot = (Get-AclDataRoot)
    )

    $idProperty = $Profile.PSObject.Properties['Id']
    if ($null -eq $idProperty) {
        $Profile | Add-Member -NotePropertyName Id -NotePropertyValue ([guid]::NewGuid().ToString())
    }
    elseif ([string]::IsNullOrWhiteSpace([string]$Profile.Id)) {
        $Profile.Id = [guid]::NewGuid().ToString()
    }

    $updatedUtc = [DateTime]::UtcNow.ToString('o')
    if ($null -eq $Profile.PSObject.Properties['UpdatedUtc']) {
        $Profile | Add-Member -NotePropertyName UpdatedUtc -NotePropertyValue $updatedUtc
    }
    else {
        $Profile.UpdatedUtc = $updatedUtc
    }
    $profilesPath = Join-Path (Initialize-AclDataStore -DataRoot $DataRoot) 'Profiles'
    $profilePath = Join-Path $profilesPath ("{0}.json" -f $Profile.Id)
    $Profile | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $profilePath -Encoding UTF8
    return $profilePath
}

function Remove-AclProfile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileId,

        [string]$DataRoot = (Get-AclDataRoot)
    )

    $profilePath = Join-Path (Join-Path $DataRoot 'Profiles') ("{0}.json" -f $ProfileId)
    if ((Test-Path -LiteralPath $profilePath) -and $PSCmdlet.ShouldProcess($profilePath, 'Remove profile')) {
        Remove-Item -LiteralPath $profilePath -Force
        $runtimePath = Join-Path $DataRoot 'Runtime'
        Remove-Item -LiteralPath (Join-Path $runtimePath ("{0}-authserver.json" -f $ProfileId)) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $runtimePath ("{0}-worldserver.json" -f $ProfileId)) -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Get-AclDataRoot, Initialize-AclDataStore, New-AclProfile, Resolve-AclProfilePath, Test-AclProfile, Get-AclProfiles, Save-AclProfile, Remove-AclProfile
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$companionRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputRoot = $companionRoot
$inputPath = Join-Path $companionRoot 'src\AzerothCoreLauncher.ps1'
$iconPath = Join-Path $companionRoot 'assets\AzerothCoreLauncher.ico'
$executablePath = Join-Path $outputRoot 'AzerothCoreLauncher.exe'

if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
    throw "Launcher script was not found: $inputPath"
}
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
    throw "Executable icon was not found: $iconPath"
}

$ps2exe = Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue
if ($null -eq $ps2exe) {
    Write-Output 'Installing ps2exe for the current user...'
    Install-Module -Name ps2exe -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
    Import-Module -Name ps2exe -Force -ErrorAction Stop
}

Invoke-ps2exe -InputFile $inputPath -OutputFile $executablePath -IconFile $iconPath -NoConsole -STA -Title 'AzerothCore Launcher'
Write-Output "Launcher executable: $executablePath"
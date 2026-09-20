Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ProfileStore.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'AzerothConfig.psm1') -ErrorAction Stop

function Initialize-AclNativeProcessSupport {
    [CmdletBinding()]
    param()

    if ('AzerothCoreLauncher.NativeProcess' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace AzerothCoreLauncher
{
    public static class NativeProcess
    {
        private const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
        private const uint CREATE_NO_WINDOW = 0x08000000;
        private const uint CTRL_BREAK_EVENT = 1;
        private const uint ATTACH_PARENT_PROCESS = 0xFFFFFFFF;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX;
            public int dwY;
            public int dwXSize;
            public int dwYSize;
            public int dwXCountChars;
            public int dwYCountChars;
            public int dwFillAttribute;
            public int dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public int dwProcessId;
            public int dwThreadId;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcess(string applicationName, string commandLine, IntPtr processAttributes,
            IntPtr threadAttributes, bool inheritHandles, uint creationFlags, IntPtr environment,
            string currentDirectory, ref STARTUPINFO startupInfo, out PROCESS_INFORMATION processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint processGroupId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AttachConsole(uint processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FreeConsole();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetConsoleCtrlHandler(IntPtr handlerRoutine, bool add);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public static int StartHidden(string executablePath, string arguments, string workingDirectory)
        {
            STARTUPINFO startupInfo = new STARTUPINFO();
            startupInfo.cb = Marshal.SizeOf(startupInfo);
            PROCESS_INFORMATION processInformation;
            string commandLine = "\"" + executablePath + "\" " + arguments;

            bool created = CreateProcess(executablePath, commandLine, IntPtr.Zero, IntPtr.Zero, false,
                CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW, IntPtr.Zero, workingDirectory,
                ref startupInfo, out processInformation);
            if (!created)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            CloseHandle(processInformation.hThread);
            CloseHandle(processInformation.hProcess);
            return processInformation.dwProcessId;
        }

        public static bool SendCtrlBreak(int processId)
        {
            FreeConsole();
            if (!AttachConsole((uint)processId))
            {
                return false;
            }

            SetConsoleCtrlHandler(IntPtr.Zero, true);
            bool sent = GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, (uint)processId);
            SetConsoleCtrlHandler(IntPtr.Zero, false);
            FreeConsole();
            AttachConsole(ATTACH_PARENT_PROCESS);
            return sent;
        }
    }
}
'@ -ErrorAction Stop
}

function Get-AclRuntimePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [Parameter(Mandatory)]
        [ValidateSet('Authserver', 'Worldserver')]
        [string]$Server,

        [string]$DataRoot = (Get-AclDataRoot)
    )

    $runtimeDirectory = Join-Path (Initialize-AclDataStore -DataRoot $DataRoot) 'Runtime'
    return (Join-Path $runtimeDirectory ("{0}-{1}.json" -f $Profile.Id, $Server.ToLowerInvariant()))
}

function Get-AclServerRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [Parameter(Mandatory)]
        [ValidateSet('Authserver', 'Worldserver')]
        [string]$Server,

        [string]$DataRoot = (Get-AclDataRoot)
    )

    $runtimePath = Get-AclRuntimePath -Profile $Profile -Server $Server -DataRoot $DataRoot
    if (-not (Test-Path -LiteralPath $runtimePath)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json)
    }
    catch {
        Remove-Item -LiteralPath $runtimePath -Force -ErrorAction SilentlyContinue
        return $null
    }
}

function Set-AclServerRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [Parameter(Mandatory)]
        [ValidateSet('Authserver', 'Worldserver')]
        [string]$Server,

        [Parameter(Mandatory)]
        [psobject]$Runtime,

        [string]$DataRoot = (Get-AclDataRoot)
    )

    $Runtime | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-AclRuntimePath -Profile $Profile -Server $Server -DataRoot $DataRoot) -Encoding UTF8
}

function Clear-AclServerRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [Parameter(Mandatory)]
        [ValidateSet('Authserver', 'Worldserver')]
        [string]$Server,

        [string]$DataRoot = (Get-AclDataRoot)
    )

    Remove-Item -LiteralPath (Get-AclRuntimePath -Profile $Profile -Server $Server -DataRoot $DataRoot) -Force -ErrorAction SilentlyContinue
}

function Get-AclProcessByExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath
    )

    $fullPath = [IO.Path]::GetFullPath($ExecutablePath)
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and ([IO.Path]::GetFullPath($_.Path) -ieq $fullPath) } catch { $false }
    })
}

function Test-AclPortConflict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Port
    )

    if ($Port -le 0) {
        return @()
    }

    return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Test-AclServerPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [Parameter(Mandatory)]
        [ValidateSet('Authserver', 'Worldserver')]
        [string]$Server
    )

    $errors = New-Object 'System.Collections.Generic.List[string]'
    try {
        $definition = Get-AzerothServerDefinition -Profile $Profile -Server $Server
        if (-not (Test-Path -LiteralPath $definition.ExecutablePath -PathType Leaf)) {
            $errors.Add("Server executable does not exist: $($definition.ExecutablePath)")
        }
        if (-not (Test-Path -LiteralPath $definition.ConfigPath -PathType Leaf)) {
            $errors.Add("Configuration file does not exist: $($definition.ConfigPath)")
        }
        if (-not (Test-Path -LiteralPath $definition.LogDirectory)) {
            try { New-Item -ItemType Directory -Path $definition.LogDirectory -Force -ErrorAction Stop | Out-Null }
            catch { $errors.Add("Log directory is unavailable: $($definition.LogDirectory)") }
        }
        $portConflicts = @(Test-AclPortConflict -Port $definition.Port)
        if ($portConflicts.Count -gt 0) {
            $errors.Add("TCP port $($definition.Port) is already listening.")
        }
    }
    catch {
        $definition = $null
        $errors.Add($_.Exception.Message)
    }

    return [pscustomobject]@{
        IsValid = $errors.Count -eq 0
        Errors = @($errors)
        Definition = $definition
    }
}

function Start-AclServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [Parameter(Mandatory)]
        [ValidateSet('Authserver', 'Worldserver')]
        [string]$Server,

        [string]$DataRoot = (Get-AclDataRoot)
    )

    $preflight = Test-AclServerPreflight -Profile $Profile -Server $Server
    if (-not $preflight.IsValid) {
        throw ($preflight.Errors -join [Environment]::NewLine)
    }

    $existing = @(Get-AclProcessByExecutable -ExecutablePath $preflight.Definition.ExecutablePath)
    if ($existing.Count -gt 0) {
        throw "$Server is already running (PID $($existing[0].Id))."
    }

    Initialize-AclNativeProcessSupport
    $arguments = '-c "{0}"' -f $preflight.Definition.ConfigPath
    $processId = [AzerothCoreLauncher.NativeProcess]::StartHidden($preflight.Definition.ExecutablePath, $arguments, $preflight.Definition.WorkingDirectory)
    $runtime = [pscustomobject]@{
        ProcessId = $processId
        State = 'Starting'
        StartedUtc = [DateTime]::UtcNow.ToString('o')
        IntentionalStop = $false
        LastExitReason = ''
    }
    Set-AclServerRuntime -Profile $Profile -Server $Server -Runtime $runtime -DataRoot $DataRoot
    return $runtime
}

function Stop-AclServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [Parameter(Mandatory)]
        [ValidateSet('Authserver', 'Worldserver')]
        [string]$Server,

        [int]$TimeoutSeconds = 30,

        [switch]$Force,

        [string]$DataRoot = (Get-AclDataRoot)
    )

    $runtime = Get-AclServerRuntime -Profile $Profile -Server $Server -DataRoot $DataRoot
    if ($null -eq $runtime) {
        return [pscustomobject]@{ Server = $Server; State = 'Stopped'; Message = 'No managed process is running.' }
    }

    $process = Get-Process -Id $runtime.ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        Clear-AclServerRuntime -Profile $Profile -Server $Server -DataRoot $DataRoot
        return [pscustomobject]@{ Server = $Server; State = 'Stopped'; Message = 'Process was already stopped.' }
    }

    $runtime.State = 'Stopping'
    $runtime.IntentionalStop = $true
    Set-AclServerRuntime -Profile $Profile -Server $Server -Runtime $runtime -DataRoot $DataRoot

    if (-not $Force) {
        Initialize-AclNativeProcessSupport
        [void][AzerothCoreLauncher.NativeProcess]::SendCtrlBreak([int]$runtime.ProcessId)
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            return [pscustomobject]@{ Server = $Server; State = 'Stopping'; Message = 'Graceful shutdown timed out. Use force stop to terminate the process.' }
        }
        Clear-AclServerRuntime -Profile $Profile -Server $Server -DataRoot $DataRoot
        return [pscustomobject]@{ Server = $Server; State = 'Stopped'; Message = 'Stopped gracefully.' }
    }

    $process.Kill()
    $process.WaitForExit()
    Clear-AclServerRuntime -Profile $Profile -Server $Server -DataRoot $DataRoot
    return [pscustomobject]@{ Server = $Server; State = 'Force-stopped'; Message = 'Process terminated.' }
}

function Restart-AclServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Profile,

        [Parameter(Mandatory)]
        [ValidateSet('Authserver', 'Worldserver')]
        [string]$Server,

        [int]$TimeoutSeconds = 30,

        [string]$DataRoot = (Get-AclDataRoot)
    )

    $stopResult = Stop-AclServer -Profile $Profile -Server $Server -TimeoutSeconds $TimeoutSeconds -DataRoot $DataRoot
    if ($stopResult.State -eq 'Stopping') {
        return $stopResult
    }
    return (Start-AclServer -Profile $Profile -Server $Server -DataRoot $DataRoot)
}

Export-ModuleMember -Function Get-AclServerRuntime, Set-AclServerRuntime, Test-AclServerPreflight, Start-AclServer, Stop-AclServer, Restart-AclServer, Get-AclProcessByExecutable
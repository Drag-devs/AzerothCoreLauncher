# AzerothCore Launcher

> **Windows Defender note:** The unsigned `ps2exe` build may be flagged as `Trojan:Win32/Wacatac.C!ml` because optional scheduled startup creates a hidden elevated task and uses PowerShell execution-policy bypass. These behaviors support server startup and recovery, but they are also commonly associated with malware.

<img width="1036" height="953" alt="Image" src="https://github.com/user-attachments/assets/4aa7cad2-c4e1-413f-a6b2-7fa6279b3d33" />

A portable Windows launcher and supervisor for existing AzerothCore installations. It manages `authserver.exe` and `worldserver.exe` without modifying AzerothCore source or provisioning databases.

## Distribution Layout

Keep these items together in one writable folder:

```text
AzerothCoreLauncher.exe
assets\
build\
src\
data\
```

`data\` is created automatically and contains:

```text
data\Profiles\     Profile JSON files
data\Runtime\      Per-server process and recovery state
data\Logs\         Launcher, supervisor, and action-result logs
data\Snapshots\    Exported support ZIP files
```

AzerothCore server configs remain in the server install selected by each profile.

## Run

Launch the compiled executable:

```text
AzerothCoreLauncher.exe
```

Or run the source script with Windows PowerShell 5.1 or later:

```powershell
.\src\AzerothCoreLauncher.ps1
```

The launcher sets execution policy bypass for its own process before importing its modules. Group Policy can still override this behavior.

### Command Actions

The script and executable accept these actions with a profile ID:

```text
-Action StartAll -ProfileId <profile-id>
-Action Supervise -ProfileId <profile-id>
-Action StopAll -ProfileId <profile-id>
-Action RestartAll -ProfileId <profile-id>
-Action StartAuthserver -ProfileId <profile-id>
-Action StopAuthserver -ProfileId <profile-id>
-Action RestartAuthserver -ProfileId <profile-id>
-Action StartWorldserver -ProfileId <profile-id>
-Action StopWorldserver -ProfileId <profile-id>
-Action RestartWorldserver -ProfileId <profile-id>
-Action Preflight -ProfileId <profile-id>
```

Non-GUI action results are saved under `data\Logs\action-<Action>-<profile-id>.json`. The next execution of the same action for the same profile overwrites that file. Preflight results include validation state and errors without full configuration settings.

## Profiles

Create a profile for each AzerothCore install. Use **Browse** to select either the executable directory or a parent directory; the launcher finds the folder containing both server executables and fills:

```text
<install>\configs\authserver.conf
<install>\configs\worldserver.conf
```

Profiles can be edited, imported, or deleted. Deletion removes the profile's launcher runtime records and scheduled startup task. A profile cannot be deleted while its managed servers are active.

## Server Controls

- **Start All** starts Authserver first, then waits for it to become healthy before starting Worldserver.
- Startup waits for readiness until a server becomes online or reports an actual failure.
- **Stop All** stops Worldserver before Authserver.
- Individual Start, Stop, and Restart controls are available for both servers.
- Start actions are disabled when configured SQL endpoints are unavailable.
- Restart is disabled for a stopped or failed server; Stop is disabled when the server is offline.
- Ordered Start All runs in a background job so Worldserver initialization does not block the WPF window.

Health is based on the configured server ports, process state, configured SQL endpoints, and root logger files. Worldserver readiness recognizes AzerothCore's daemon-ready log marker and keeps the ready state while the managed process and configured port remain healthy.

## Logs and SQL Status

The launcher parses each profile's `LogsDir`, `Appender.*`, and `Logger.root` configuration.

- Server status cards use root logger file appenders only, avoiding noisy optional logs such as Playerbots.
- The Activity Log selector includes every configured file appender plus Manager activity.
- The selected log has its own scrollbars and remains visible during health refreshes.
- SQL status monitors the host and port values in `LoginDatabaseInfo`, `WorldDatabaseInfo`, and `CharacterDatabaseInfo`.

## Scheduled Startup and Supervision

Scheduled startup is per profile:

```text
-Action ScheduledStart -ProfileId <profile-id>
```

`ScheduledStart` reads the current profile recovery policy when the task runs. With recovery disabled it starts the selected profile's servers in order and exits after startup. With recovery enabled it starts the servers in order and remains running to apply the recovery policy. Neither mode opens the launcher UI.

Both current-user logon and delayed system startup are supported. Task Scheduler operations request UAC elevation only when required. The normal launcher does not run elevated.

Supervisor events are written to:

```text
data\Logs\supervisor-<profile-id>.log
```

## Recovery Settings

The **Recovery Settings** dialog stores per-profile policy values:

- Enable automatic recovery
- Recover Authserver
- Recover Worldserver
- Maximum consecutive restart attempts: 1 to 20
- Initial retry delay: 1 to 300 seconds
- Backoff multiplier: 1 to 5
- Healthy reset period: 1 to 1440 minutes
- Require configured SQL endpoints to be online

When enabled, the launcher detects unexpected managed-process exits and restarts selected servers with bounded exponential backoff. Retry attempt count, next retry time, health time, cancellation state, and recovery state are stored in each server runtime record.

Recovery only acts on unexpected exits. Manual Stop cancels recovery for that server until it is started manually again. When SQL gating is enabled, recovery waits for configured SQL endpoints. Worldserver recovery waits for Authserver to be online.

## Support Snapshot

**Export Snapshot** creates a ZIP under `data\Snapshots\` containing redacted profile/configuration data, health information, and recent configured log tails.

## Build the EXE Yourself

The project is built with [ps2exe](https://www.powershellgallery.com/packages/ps2exe). From the distribution root:

```powershell
.\build\Build.ps1
```

The script installs `ps2exe` for the current user if it is missing, compiles `src\AzerothCoreLauncher.ps1`, applies `assets\AzerothCoreLauncher.ico`, and overwrites `AzerothCoreLauncher.exe` in the same folder.

Close the launcher before rebuilding, because Windows locks a running EXE.

The rebuilt EXE and the `src\` and `data\` folders form one portable distribution.

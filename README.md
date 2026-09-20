# AzerothCore Launcher

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

`data\` is created automatically and stores launcher-owned profiles, runtime records, logs, and support snapshots. AzerothCore server configs remain in the server install selected by each profile.

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

## Profiles

Create a profile for each AzerothCore install. Use **Browse** to select either the executable directory or a parent directory; the launcher finds the folder containing both server executables and fills:

```text
<install>\configs\authserver.conf
<install>\configs\worldserver.conf
```

Profiles can be edited, imported, or deleted. Deletion removes the profile's launcher runtime records and scheduled startup task. A profile cannot be deleted while its managed servers are active.

## Server Controls

- **Start All** starts Authserver first, then waits for it to become healthy before starting Worldserver.
- Startup has no readiness timeout. A server remains `Starting` until it is online or actually fails.
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

## Scheduled Startup

Scheduled startup is per profile. The task starts the selected profile with:

```text
-Action StartAll -ProfileId <profile-id> -Headless
```

Both current-user logon and delayed system startup are supported. Task Scheduler operations request UAC elevation only when required; the normal launcher does not run elevated.

## Recovery Settings

The Recovery Settings dialog stores per-profile policy values for automatic recovery: enabled state, server scope, retry limit, initial delay, backoff multiplier, healthy reset period, and SQL prerequisite.

The policy editor is available now. The background crash-restart supervisor is not yet active, so enabling recovery does not currently restart a crashed server.

## Support Snapshot

**Export Snapshot** creates a ZIP under `data\Snapshots\` containing redacted profile/configuration data, health information, and recent configured log tails.

## Build the EXE Yourself

The project is built with [ps2exe](https://www.powershellgallery.com/packages/ps2exe). From the distribution root:

```powershell
.\build\Build.ps1
```

The script installs `ps2exe` for the current user if it is missing, compiles `src\AzerothCoreLauncher.ps1`, applies `assets\AzerothCoreLauncher.ico`, and overwrites `AzerothCoreLauncher.exe` in the same folder.

Close the launcher before rebuilding, because Windows locks a running EXE.
# GitHub Actions Runner & macOS `launchd` Internals

This document records how the official GitHub Actions self-hosted runner
(`actions/runner`) configures and runs macOS services, what was verified
against the upstream `actions/runner` source code and macOS `launchd`, and what
still requires confirmation on a Mac with live registered runners.

---

## 1. Verified Against `actions/runner` Source (`main`)

### Service label and `.plist` layout

Verified in:
- `src/Runner.Listener/Configuration/OsxServiceControlManager.cs`
- `src/Runner.Listener/Configuration/ServiceControlManager.cs`
- `src/Misc/layoutbin/darwin.svc.sh.template`
- `src/Misc/layoutbin/actions.runner.plist.template`

Findings:
- **Service name pattern**: `actions.runner.<repoOrOrg>.<agentName>`, truncated
  with a 4-digit random suffix only if total length exceeds 150 characters.
  - Repository-level runner (`https://github.com/acme/app`):
    `RepoOrOrgName` is `acme/app`; `/` and any character outside
    `[0-9a-zA-Z._-]` are replaced with `-`, producing
    `actions.runner.acme-app.<agentName>`.
  - Organization-level runner (`https://github.com/acme`):
    `RepoOrOrgName` is `acme`, producing `actions.runner.acme.<agentName>`.
  - Spaces in `<SVC_NAME>` are replaced with `_` in `darwin.svc.sh.template`
    (`SVC_NAME=${SVC_NAME// /_}`).
- **Plist path**: `~/Library/LaunchAgents/<SVC_NAME>.plist`.
- **`.service` marker**: `<instance_dir>/.service` contains the full path to the
  `.plist` file.
- **Plist keys written by `svc.sh install`**:
  - `Label`: `<SVC_NAME>`
  - `ProgramArguments`: `[ "<RunnerRoot>/runsvc.sh" ]`
  - `UserName`: `<User>`
  - `WorkingDirectory`: `<RunnerRoot>`
  - `RunAtLoad`: `true`
  - `KeepAlive`: **not set** (launchd will not restart the service when
    `runsvc.sh` exits)
  - `StandardOutPath`: `~/Library/Logs/<SVC_NAME>/stdout.log`
  - `StandardErrorPath`: `~/Library/Logs/<SVC_NAME>/stderr.log`
  - `EnvironmentVariables`: `{ "ACTIONS_RUNNER_SVC": "1" }`
  - `ProcessType`: `Interactive`
  - `SessionCreate`: `true`

### Process hierarchy (`runsvc.sh` -> `RunnerService.js` -> `Runner.Listener` -> `Runner.Worker`)

Verified in:
- `src/Misc/layoutbin/runsvc.sh`
- `src/Misc/layoutbin/RunnerService.js`

Findings:
- `launchd` starts `<RunnerRoot>/runsvc.sh` (so the service PID reported by
  `launchctl` is the `bash` process executing `runsvc.sh`).
- `runsvc.sh` launches `./externals/<nodever>/bin/node ./bin/RunnerService.js &`
  and `wait`s on it while forwarding `SIGTERM`/`SIGINT` as `SIGINT`.
- `RunnerService.js` spawns `bin/Runner.Listener run --startuptype service`.
- While executing a job, `Runner.Listener` spawns `bin/Runner.Worker` as a child
  process. Because `Runner.Worker` is a **great-grandchild** of the `launchd`
  service PID (`runsvc.sh` -> `node` -> `Runner.Listener` -> `Runner.Worker`),
  `runnerkit` walks the descendant tree with `pgrep -P` rather than checking
  only direct children of the service PID.

### Listener return codes and when the service stops

Verified in:
- `src/Runner.Common/Constants.cs` (`Constants.Runner.ReturnCode`)
- `src/Misc/layoutbin/RunnerService.js`
- `src/Runner.Listener/Runner.cs`

| Code | Name in `Constants.cs` | `RunnerService.js` behavior |
|---|---|---|
| `0` | `Success` | Logs `"Runner listener exit with 0 return code, stop the service, no retry needed."` and stops. Note: `Runner.cs` also returns `0` after catching `TaskAgentAccessTokenExpiredException` (`"Runner OAuth token has been revoked. Shutting down."`). |
| `1` | `TerminatedError` | Logs `"Runner listener exit with terminated error, stop the service, no retry needed."` and stops. |
| `2` | `RetryableError` | Retries every 5s; stops after **10 consecutive** retryable failures (`"Stopping the runner after 10 consecutive re-tryable failures"` on `stderr`). Counter resets when `"Listening for Jobs"` appears on `stdout`. |
| `3` | `RunnerUpdating` | Retries in 5s (counts toward the 10-retry cap). |
| `4` | `RunOnceRunnerUpdating` | Retries in 5s (counts toward the 10-retry cap). |
| `5` | `SessionConflict` | Logs `"Runner listener exit with Session Conflict error, stop the service, no retry needed."` and stops. |
| other | undefined (e.g. signal/crash) | Retries in 5s indefinitely unless `GITHUB_ACTIONS_SERVICE_EXIT_AFTER_N_FAILURES` is set. |

Important logging detail in `RunnerService.js`:
- `RunnerService.js` forwards `listener.stderr` to **`process.stdout`**
  (`stdout.log`), not `stderr.log`! Only `console.error(...)` inside
  `RunnerService.js` and shell errors from `runsvc.sh` go to `stderr.log`.
  Therefore `runnerkit` checks `stderr.log`, recent lines of `stdout.log`, and
  `<dir>/_diag/Runner_*.log` (never `Worker_*.log`).

### `.runner` file format and UTF-8 BOM

Verified in:
- `src/Runner.Common/ConfigurationStore.cs` (`RunnerSettings`)
- `src/Runner.Common/Util/IOUtil.cs` (`IOUtil.SaveObject`)

Findings:
- `IOUtil.SaveObject` calls `File.WriteAllText(path, json, Encoding.UTF8)`. In
  .NET, `Encoding.UTF8` emits a 3-byte UTF-8 BOM (`0xEF 0xBB 0xBF`).
- JSON keys are camelCased (`agentId`, `agentName`, `poolId`, `poolName`,
  `serverUrl`, `gitHubUrl`, `workFolder`, `serverUrlV2`).
- `runnerkit` strips the leading `0xEF 0xBB 0xBF` BOM before parsing `.runner`.

### Server-side rejected registration messages

Verified in:
- `src/Runner.Listener/BrokerMessageListener.cs`
- `src/Runner.Listener/MessageListener.cs`
- `src/Runner.Listener/Runner.cs`

Exact messages emitted by `Runner.Listener`:
- When OAuth credential validation returns `invalid_client` (registration
  deleted in GitHub settings or auto-expired after inactivity):
  `"Failed to create a session. The runner registration has been deleted from the server, please re-configure. Runner registrations are automatically deleted for runners that have not connected to the service recently."`
- When `TaskAgentNotFoundException` is thrown during session creation:
  `"The runner no longer exists on the server. Please reconfigure the runner."`
- When the runner's OAuth token is revoked (`TaskAgentAccessTokenExpiredException`):
  `"Runner OAuth token has been revoked. Shutting down."` /
  `"Runner OAuth token has been revoked. Unable to pull message."`
- Non-retryable exceptions logged in `_diag/Runner_*.log`:
  `TaskAgentNotFoundException`, `RunnerNotFoundException`,
  `TaskAgentPoolNotFoundException`, `TaskAgentAccessTokenExpiredException`,
  `HostedRunnerDeprovisionedException`.

### Network health endpoints

Verified in:
- `src/Runner.Listener/Checks/InternetCheck.cs`
- `src/Runner.Listener/Checks/ActionsCheck.cs`

`actions/runner` checks `https://api.github.com` and
`https://vstoken.actions.githubusercontent.com/_apis/health` (plus
`https://pipelines.actions.githubusercontent.com/_apis/health`). `runnerkit doctor`
probes `https://api.github.com` and
`https://vstoken.actions.githubusercontent.com/_apis/health` over HTTPS with
stock `/usr/bin/curl`.

---

## 2. Verified Against Real `launchctl` on Hosted macOS CI

Verified automatically on every CI run in `tests/macos_launchd_test.sh`:
- `launchctl print gui/<uid>/<label>` exits non-zero (`113`) when unloaded and
  prints `state = running` / `pid = <N>` or `state = not running` /
  `last exit code = <N>` when loaded.
- `launchctl bootstrap gui/<uid> <plist>` loads an unloaded plist and starts it
  due to `RunAtLoad`.
- `launchctl kickstart -k gui/<uid>/<label>` restarts a stopped (loaded, no PID)
  service.
- `launchctl disable gui/<uid>/<label>` followed by
  `launchctl bootout gui/<uid>/<label>` stops the service and records a
  persistent disabled override in `launchd` without modifying the `.plist`.
- `launchctl enable gui/<uid>/<label>` followed by
  `launchctl bootstrap gui/<uid> <plist>` clears the disabled override and
  returns the service to running state.

---

## 3. Items to Confirm on a Physical Mac with Registered Runners

Before promoting `v1.0.0` out of pre-release (tracked in
[`docs/mac-checklist.md`](./mac-checklist.md)):
1. Confirm `launchctl kickstart -k gui/<uid>/<sibling-label>` and
   `launchctl disable` / `bootout` work from inside an active GitHub Actions
   runner job (`doctor.yml`) on macOS 13+.
2. Confirm `launchctl disable gui/<uid>/<label>` keeps a runner with
   `RunAtLoad = true` down across both GUI logout/login and full machine reboot.
3. Record any additional real-world exit codes or error lines observed in
   `~/Library/Logs/<label>/stderr.log` and `_diag/Runner_*.log`.

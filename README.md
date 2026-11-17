# RunnerKit

Keep the GitHub Actions self-hosted runners on your Mac healthy, and see what
is wrong with them without logging in to it.

## Why

GitHub's self-hosted runner installs as a `launchd` service. If it exits with
an error it stays down, and nothing tells you: jobs sit in the queue. Fixing it
means sitting at the Mac and remembering which folder and which log.

`runnerkit`:

- restarts runners that stopped, and shows why they stopped
- lets you pause a misbehaving runner (locally or from GitHub) so `heal` and
  reboots leave it out of rotation until you `resume` it
- tells a crash (restart it) from a runner GitHub has rejected (needs you)
  from a machine problem (disk full, Xcode changed, nobody logged in)
- gives you a `Runner doctor` workflow that checks, heals, pauses and resumes
  runners from the Actions tab or the API
- has stable, machine-readable `--json` output and a short procedure coding
  agents can follow

It works with runners installed the standard way (`config.sh`, then
`svc.sh install`), including ones you already have. It does not install or
register runners, replace GitHub's runner, or modify its files.

## Before you start (security)

Self-hosted runners execute whatever code a workflow tells them to.

- **Public repositories**: do not attach self-hosted runners to a public
  repository unless pull requests from forks cannot reach them.
- **Dedicated account**: run them under a macOS user account that holds no
  signing keys, Apple IDs, SSH keys or personal credentials. Everything in
  `runnerkit` runs as that user — never `sudo`.
- **GUI session & power**: that macOS account must stay logged in to the GUI,
  and the Mac must not sleep.
- **No tokens**: `runnerkit` handles no GitHub tokens at all. Log excerpts in
  `status`, `doctor` and `logs` read only the runner's own service and
  `Runner_*.log` diagnostic files (never job worker logs), cap their length,
  and redact token-like strings before printing or writing to a job summary.
- **Remote pause**: `pause --now` terminates a running job on the target
  runner, and anyone with permission to dispatch workflows in your repository
  can trigger it through `Runner doctor` — the same set of people who can
  already cancel workflow runs.

Requirements: macOS 13+ (Apple silicon or Intel), stock `/bin/bash` 3.2, and
one or more runners already configured as services
([GitHub's instructions](https://docs.github.com/en/actions/hosting-your-own-runners)).
To run several jobs at once, set up one runner per directory.

## Install (once, on the Mac)

```bash
git clone https://github.com/Liampronan/RunnerKit ~/.runnerkit
```

```bash
~/.runnerkit/install.sh
```

```bash
runnerkit status
```

It discovers your runners from `~/Library/LaunchAgents/actions.runner.*.plist`
and each directory's `.runner` file — no config file to maintain. Then keep
them running:

```bash
runnerkit agent install
```

That adds one background `launchd` check, every 15 minutes and at login
(`--interval MIN` to change it), with bounded logs in
`~/Library/Logs/runnerkit/heal.log`.

## Commands

| Command | What it does |
|---|---|
| `runnerkit status [--json]` | Every runner and its state, with log excerpts for any that are down |
| `runnerkit heal [--dry-run] [--force] [--json]` | Restart what a restart can fix; report the rest |
| `runnerkit doctor [--require-runtime iOS-26-0] [--min-free-gb 20] [--json]` | `status` plus machine checks: disk, login session, Xcode, simulator runtimes, sleep, network, paused runners |
| `runnerkit pause NAME [--reason TEXT] [--now]` | Take a runner out of rotation across `heal` runs and reboots |
| `runnerkit resume NAME` | Put a paused runner back into rotation and reset its restart counter |
| `runnerkit logs NAME [--lines N]` | The end of one runner's service and diagnostic logs |
| `runnerkit agent install\|uninstall\|status` | Manage the scheduled `heal` LaunchAgent |
| `runnerkit version` | Print the `runnerkit` version |

`NAME` is the runner's `agentName` (or its full `launchd` label if two targets
on the same Mac share a runner name).

```text
$ runnerkit doctor --require-runtime iOS-26-0
host: build-mac   kit: 1.0.0
NAME               TARGET                 STATE      DETAIL
build-mac-1        acme/app               idle       pid 512
build-mac-2        acme/app               busy       pid 518
build-mac-3        acme/app               stopped    last exit 1
    stderr: Runner listener exit with terminated error, stop the service
CHECKS
ok    disk      212 GB free
ok    session   GUI session for ci
ok    xcode     Xcode 26.5 (/Applications/Xcode.app/Contents/Developer)
fail  runtime   iOS-26-0 not installed (have iOS-26-5; Xcode 26.5 selected)
      remedy: Install the missing runtime with 'xcodebuild -downloadPlatform <Platform>' (or Xcode > Settings > Components), or update the workflow destination.
ok    sleep     system sleep disabled
ok    network   github.com and Actions reachable
```

### Instance states and exit codes

- `idle` / `busy`: running (`Runner.Worker` descendant distinguishes `busy`).
  `heal` never touches either, and inside a job `RUNNER_NAME` is never touched.
- `stopped` / `unloaded`: down or not in `gui/<uid>`. `heal` restarts
  (`kickstart -k`) or loads (`bootstrap`) up to 3 consecutive attempts before
  marking the runner `flapping` (left alone until `heal --force` or seen
  running).
- `paused`: intentionally disabled (`launchctl disable` + `bootout`). Does not
  make `status` or `heal` fail by itself; `doctor` emits `warn` when some
  runners are paused and `fail` when **every** runner is paused.
- `rejected` / `orphaned`: GitHub deleted or revoked the registration, or the
  runner directory is missing. Reported only — never restarted.

Exit codes: `0` healthy, `1` needs attention, `2` usage error, `3` not macOS or
missing stock system tool. Pass `--json` to `status`, `heal`, `doctor`, `pause`
or `resume` for versioned (`"schema": 1`) JSON output.

## Check, heal, pause and resume from GitHub

Add `.github/workflows/runner-doctor.yml` to your repository's **default
branch** (GitHub only allows `workflow_dispatch` on workflows present on the
default branch):

```yaml
name: Runner doctor
on:
  workflow_dispatch:
    inputs:
      heal: { type: boolean, default: true }
      pause: { type: string, description: "Runner names to take out of rotation" }
      resume: { type: string, description: "Runner names to put back" }
jobs:
  doctor:
    uses: Liampronan/RunnerKit/.github/workflows/doctor.yml@v1
    with:
      runs-on: '["self-hosted","macOS"]'
      heal: ${{ inputs.heal }}
      pause: ${{ inputs.pause }}
      resume: ${{ inputs.resume }}
      require-runtimes: iOS-26-0
```

Run it from the Actions tab or via `gh workflow run "Runner doctor"`. It lands
on any runner that is alive, runs `resume`, `pause` (with `--now` and the run
URL as the reason), `heal`, and `doctor` in that order, writes the full report
to the job summary, and uploads the JSON output as an artifact. If `pause`
names the runner that picked up the doctor job itself, the job reports it as
not done so you can dispatch once more after siblings are up. It needs no
secrets.

If every runner is down, this job queues too. The background `heal` agent on
the Mac covers everything a restart can fix; otherwise it needs a person.

## For coding agents

Paste this into your repository's agent instructions (`AGENTS.md`,
`CLAUDE.md`):

```markdown
## Self-hosted Mac runners

Jobs for the self-hosted labels run on a Mac managed by runnerkit.

- The Mac is the suspect when those jobs stay `queued` for more than a few
  minutes with none `in_progress`.
- Dispatch the `Runner doctor` workflow and read its job summary. It restarts
  stopped runners and lists what it could not fix.
- If the doctor's own job is still queued after 5 minutes, no runner is
  alive. Stop polling and tell the owner.
- When a job hangs or keeps failing on one runner while the others work,
  dispatch `Runner doctor` with `pause` set to that runner's name, then re-run
  the job. Tell the owner which runner was paused and why.
- Do not resume a runner someone else paused unless the owner asks.
- A failing `runtime`, `xcode`, `disk` or `session` check needs the owner.
  Quote the check's line.
- Do not register, re-register or remove runners unless the owner asks.
```

## What this cannot see

`runnerkit` knows whether a runner process is up, not whether a job running on
it is making progress. Put `timeout-minutes` on workflow jobs and steps that
talk to simulators or the network, and wrap `simctl` / simulator commands in
your own scripts with timeouts, so a hung simulator step turns into a clear
failure in minutes instead of blocking a runner for hours.

## What needs a person at the Mac

- The Mac is off, asleep, or the runner account is logged out.
- The disk is full.
- Xcode or a simulator runtime has to be installed.
- A paused runner: fix what was wrong with it, then `runnerkit resume NAME`.
- GitHub rejected a runner (`rejected`): configure/register it again.
- A runner keeps dying after restarts (`flapping`): inspect
  `runnerkit logs NAME`.

## How this differs from other tools

- **mac-runner** (`omniaura/mac-runner`) and **HomeRun** (`aGallea/homerun`)
  install runners and supervise them as child processes of a menu bar app or
  custom daemon rather than per-runner `launchd` services.
- **Tartelet**, **Cilicon** and **Graftery** boot a fresh macOS virtual machine
  per job (capped at two concurrent macOS VMs per Apple host).

`runnerkit` leaves GitHub's official per-runner `launchd` services untouched
and layers scheduled healing, pause/resume, Xcode/simulator drift checks, a
dispatchable `Runner doctor` workflow, and an agent procedure on top — in a
single Bash 3.2 script with no GUI and no custom daemon.

## Uninstall

```bash
runnerkit agent uninstall
```

```bash
~/.runnerkit/install.sh --uninstall
```

## License

[MIT](./LICENSE)

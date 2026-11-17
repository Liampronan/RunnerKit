# Manual macOS Release Checklist

Run this checklist on a real Mac with registered self-hosted runners before
cutting a non-prerelease tag (`v1.0.0`) and moving the `v1` tag.

---

## Prerequisites

- macOS 13 or later with a logged-in non-admin GUI user dedicated to runners.
- Three runner instances configured the standard way (`./config.sh` +
  `./svc.sh install` + `./svc.sh start`) in separate directories.
- A test or adopting repository with `.github/workflows/runner-doctor.yml` on
  its default branch calling `Liampronan/RunnerKit/.github/workflows/doctor.yml@v1`.

---

## Checklist

- [ ] **1. Baseline discovery (`status` and `doctor`)**
  - Run `runnerkit status` and `runnerkit status --json`.
  - Confirm all three instances appear as `idle` (or `busy` during a job) with
    accurate `name`, `label`, `target`, `dir`, and `pid`.
  - Run `runnerkit doctor` and confirm `disk`, `session`, `xcode`, `sleep`, and
    `network` report expected results.

- [ ] **2. Stopped runner recovery (`kickstart`)**
  - Force one runner service to exit non-zero (so `launchctl list` shows `-  1`
    or `runnerkit status` shows `stopped`).
  - Confirm `runnerkit status` prints `stopped` and shows log lines without
    leaking any tokens.
  - Run `runnerkit heal` and confirm the instance returns to `idle`.

- [ ] **3. Unloaded runner recovery (`bootstrap`)**
  - Run `launchctl bootout gui/$(id -u)/<label>` on one runner.
  - Confirm `runnerkit status` reports `unloaded`.
  - Run `runnerkit heal` and confirm `bootstrap` loads and starts the runner.

- [ ] **4. Flapping protection (`restarts` cap at 3)**
  - Temporarily break one runner's startup (for example, make its `runsvc.sh`
    non-executable or exit `1` immediately; restore afterward).
  - Run `runnerkit heal` three times and confirm the instance transitions to
    `flapping` on the third failed restart.
  - Run `runnerkit heal` a fourth time and confirm `launchd` is **not** called
    for the `flapping` instance.
  - Restore the runner, run `runnerkit heal --force`, and confirm it recovers
    to `idle` and resets `restarts` to `0` on the next `status`.

- [ ] **5. Pause and resume across logout and reboot**
  - Run `runnerkit pause <name> --reason "checklist reboot test"`.
  - Confirm `runnerkit status` shows `paused` with timestamp and reason, and
    exits `0`.
  - Run `runnerkit heal` and confirm the paused runner stays down.
  - Log out of the macOS GUI session and log back in; confirm the paused runner
    did **not** start despite `RunAtLoad` in its `.plist`, while the other two
    runners came up.
  - Reboot the Mac (with auto-login or manual login); confirm the paused runner
    still stays down and `runnerkit doctor` shows `warn` on the `paused` check.
  - Run `runnerkit resume <name>`, confirm it returns to `idle`, and trigger a
    workflow job to confirm it accepts work again.

- [ ] **6. Simulator runtime drift detection**
  - Run `runnerkit doctor --require-runtime iOS-99-0`.
  - Confirm `doctor` exits `1`, reports `fail` on `runtime`, and names the
    actually installed runtimes alongside the selected Xcode version.

- [ ] **7. Background heal agent**
  - Run `runnerkit agent install`, verify `runnerkit agent status` exits `0`,
    and inspect `~/Library/Logs/runnerkit/heal.log`.

- [ ] **8. Remote `Runner doctor` workflow from GitHub**
  - Stop one runner locally, then dispatch `Runner doctor` (`heal: true`) from
    GitHub Actions.
  - Confirm the job runs on a live sibling, restarts the stopped runner, writes
    the Markdown summary to `$GITHUB_STEP_SUMMARY`, and uploads the
    `runnerkit-doctor` JSON artifact.
  - Dispatch `Runner doctor` with `pause` set to a sibling runner's name;
    confirm the sibling is paused with the workflow run URL recorded as the
    reason.
  - Dispatch `Runner doctor` with `resume` set to that sibling's name; confirm
    it returns to `idle`.

---

## Release Tagging Procedure

1. Ensure `.github/workflows/doctor.yml` has `KIT_REF` set to `v1` (or the
   exact `v1.x.y` tag).
2. Tag and push the semantic version and update the floating major tag:
   ```bash
   git tag -a v1.0.0 -m "Release v1.0.0"
   git push origin v1.0.0
   git tag -fa v1 -m "Update v1 tag to v1.0.0"
   git push origin -f v1
   ```
3. Until all items above are checked and recorded below, mark GitHub Releases
   as **pre-release** (`gh release create v1.0.0-rc.1 --prerelease`).

---

## Verification Log

| Date | Release | macOS / Arch | Runner version | Verified by | Notes |
|---|---|---|---|---|---|
| _Pending_ | `v1.0.0-rc.1` | — | — | — | Pre-release until physical Mac checklist is run |

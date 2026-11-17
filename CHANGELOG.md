# Changelog

All notable changes to this project will be documented in this file.

## [1.0.0-rc.1] - 2026-11-16

Initial pre-release (pending physical Mac checklist verification in
`docs/mac-checklist.md` before `v1.0.0`).

### Added
- `runnerkit status`, `heal`, `doctor`, `pause`, `resume`, `logs`,
  `agent install|uninstall|status`, and `version` commands in a single stock
  macOS `/bin/bash` 3.2 script.
- Versioned `--json` output (`schema: 1`) across operational commands and
  `--summary` GitHub Step Summary Markdown output.
- Automatic discovery of official `svc.sh`-installed runners from
  `~/Library/LaunchAgents/actions.runner.*.plist` and UTF-8 BOM `.runner`
  metadata without modifying runner files.
- Flapping protection (3 consecutive failed restarts), rejected-registration
  detection, `RUNNER_NAME` self-skip inside jobs, and token masking in log
  tails.
- Machine health checks in `doctor`: `disk`, `session`, `xcode`, `runtime`,
  `sleep` (warn-only), `network`, and `paused` (`warn` when partial, `fail`
  when all runners are paused).
- Reusable `.github/workflows/doctor.yml` workflow supporting remote `resume`,
  `pause`, `heal`, and `doctor` runs.
- Cross-platform stub test suite (Linux and macOS Bash 3.2) and real `launchctl`
  integration test on hosted macOS CI.

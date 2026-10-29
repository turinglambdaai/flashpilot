# FlashPilot user guide

**English** · [简体中文](USER-GUIDE.zh-CN.md)

Validate declarative ECU flash plans with a deterministic engine, CLI/MCP and native desktop hosts.

## Availability

The AGPL engine, CLI and MCP remain free, including CI use under the existing licence. Validated official engineering assets are planned; no paid edition is on sale.

## Platforms and installation

Desktop source/preview paths target macOS, Windows and Linux. The published archive set does not imply every adapter, ECU or bus has been qualified.

Use [official Releases](https://github.com/turlamai/flashpilot/releases), select an explicitly listed OS/architecture asset, read its release notes and check supplied checksums. An absent asset/platform is not a delivery promise. Preview builds may lack publisher signing or notarization; do not disable system-wide security protections to install them.

Portable CLI archive entry points depend on the release: the published **v0.1.0 Windows ZIP** has `flashpilot.exe` at its root, while builds incorporating the [Windows archive-layout fix (#10)](https://github.com/turlamai/flashpilot/issues/10) use `bin/flashpilot.exe`. macOS and Linux CLI ZIPs use `bin/flashpilot`. Extract the **whole archive** without moving just the executable: Racket's support-library subdirectories are OS-specific and must remain intact.

## Your first successful session

1. Read the manual and choose a supplied simulator/example plan.
2. Validate the plan and inspect deterministic output, failure status and logs without touching physical equipment.
3. Before hardware use, match the exact adapter/firmware/ECU to a recorded qualification and establish recovery and power-loss procedures.

## Data, backup and recovery

Keep plan files, firmware digests, adapter versions and run logs together. Preserve the original ECU/firmware recovery material outside the application directory. Redact identifiers and proprietary firmware before sharing logs.

## Network, keys and privacy

Physical flashing writes to connected equipment; validation/simulator results alone authorize no such operation. External adapters and configured endpoints have their own access and data boundaries.

## Known limits

Packaged simulator acceptance is not hardware-in-the-loop qualification. Consult #4 for the supported/evidenced matrix; no universal ECU compatibility is claimed.

## Updates and removal

Back up data and read the destination release notes first. An in-app update check does not necessarily install an update for your channel; follow the manual for portable, installer and source paths. Never bypass a failed signature check or replace the program with an untrusted artifact. On failure, preserve data and the error, then recover with a trusted release. Removing the program does not necessarily erase its separate data directory; verify your backup before deleting personal data.

## Get help

Report problems in [GitHub Issues](https://github.com/turlamai/flashpilot/issues), in English or Chinese. Include the version, OS/architecture, installation channel, steps, expected result and actual result. Reproduce with synthetic input first; do not attach keys, credentials, databases, private source documents or complete logs. Public support has no guaranteed response time.

## Further reading

- [Flash-plan manual](../docs/guide.html)
- [Example plans](../examples)
- [Project overview and development](../README.md)
- [Current licence](../LICENSE)

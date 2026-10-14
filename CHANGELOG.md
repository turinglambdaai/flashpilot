# Changelog

All notable changes to FlashPilot are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is SemVer.

## [0.1.0] - 2026-10-14

First release. CLI-first, three platforms: the flashing core, a declarative
plan format and an agent-first CLI — no GUI in the release artifacts (the
native shells stay in-repo as a debug cockpit).

### Added

- **UDS (ISO 14229) core** — P2/P2* timing, NRC taxonomy, DTC read/clear
  (0x19 / 0x14), DID read (0x22), TesterPresent, ECU reset.
- **UDS flash workflow** — session → security access → erase → download →
  verify → reset, with a per-step audit on every run.
- **Declarative flash plans** — one JSON document per ECU: segments (inline
  hex or raw BIN files), session, security level, key deriver,
  recovery strategy (`retry` / `resetAndRetry`), in-programming power guard,
  and an `expectedFingerprint` gate validated before any driver call.
  Intel HEX / S-record parsing ships in the image model.
- **Security providers** — built-in seed-key derivers plus pluggable external
  algorithms via `command:<id>`; vendor code stays in vendor binaries.
- **Transports** — SocketCAN (Linux), PEAK PCAN (Windows), DoIP (Ethernet);
  ISO-TP (ISO 15765-2) underneath. UDS over LIN is planned, not in this release.
- **Built-in simulated ECU** — a real ISO-TP/UDS stack answering behind a
  simulated CAN bus, so the entire flash loop runs hardware-free, including CI.
- **Agent-first CLI** — `flash` / `verify` / `dtc` / `request` / `udid`;
  deterministic single-line JSON output, stable exit codes (0 ok · 1
  flash/assert failed · 2 usage · 3 not found · 4 transport), bounded failure
  evidence so an agent can diagnose and retry without a vendor tool.
- **User guide** — bilingual (Chinese/English) manual at
  <https://flashpilot.jrtx.site/guide.html>.
- **Release engineering** — tagged builds produce per-platform CLI archives
  (zip + SHA-256) and a combined SHA256SUMS on GitHub Releases.

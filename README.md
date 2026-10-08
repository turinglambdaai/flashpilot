# FlashPilot

**AI-native ECU flashing — UDS over CAN, DoIP and LIN, driven by declarative flash plans and built for coding agents.**
The focused, license-free alternative to vFlash: one resident-free CLI, deterministic JSON, exit codes that never lie, and failure evidence that lets an agent self-diagnose.

**English**

[![CI](https://github.com/turinglambdaai/flashpilot/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/flashpilot/actions/workflows/ci.yml)
![platform](https://img.shields.io/badge/platform-Windows_%7C_Linux-lightgrey)
[![built with](https://img.shields.io/badge/built%20with-Racket-9F1D35)](https://racket-lang.org/)
[![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

## Why FlashPilot?

Automotive flashing today means vFlash: expensive per-seat licenses, a Windows GUI, and automation only through a COM API that agents can't drive. The flashing knowledge itself — seed-key algorithms, memory layouts, sequences — used to be a moat of accumulated authoring. In the AI era that authoring cost collapses: an agent can draft a flash plan from an OEM spec. What remains valuable is the **closed loop**: generate a plan → verify its fingerprint → flash with power/sequence guards → collect evidence on failure → regenerate.

FlashPilot is built around that loop.

- **Declarative flash plans** — one JSON document per ECU: segments (inline, BIN, Intel HEX, S-record), session, security access with pluggable key providers, erase/download/verify routines, timings, recovery strategy, power guard, expected fingerprint.
- **Real transports** — SocketCAN (Linux), PEAK PCAN (Windows), DoIP (Ethernet). ISO-TP (ISO 15765-2) underneath; LIN planned.
- **Agent-first CLI** — deterministic JSON output, exit codes that never lie, and failure evidence (bounded, fingerprinted, audited) so an agent can diagnose and retry without a human opening a vendor tool.
- **Safety by default** — plans validate expected fingerprints before any driver call; in-programming power guards abort on out-of-band current; destructive plans say so.

Not a CANoe clone: no vehicle-network simulation, no CAPL, no analysis-window collection. One loop done honestly.

## Status

**v0.1.0 — core engine**: UDS (ISO 14229) with P2/P2* timing and NRC handling, UDS flash workflow (session → security access → erase → download → verify → reset) with per-step audit, declarative plans with recovery strategies (retry / reset-and-retry), image fingerprint gate, in-programming power guard, DTC read/clear, Intel HEX + S-record + BIN image models, pluggable security providers (`command:<id>` external algorithms), ISO-TP over simulated CAN and DoIP, and a built-in simulated ECU so the entire loop runs hardware-free in CI.

The next gates: UDS over LIN, DoIP Ethernet hardening against real ECUs, and a plan library.

## Quick start

```bash
git clone https://github.com/turinglambdaai/flashpilot.git
cd flashpilot
raco pkg install --auto --name flashpilot --link racket
racket app/cli.rkt flash examples/plan.sim.json
```

The default transport is a built-in simulated ECU — the whole flash loop runs hardware-free:

```json
{"ok":true,"bytes":300,"fingerprint":"…","steps":["diagnostic-session","security-access","erase","download","verify","ecu-reset"]}
```

Against a real ECU over DoIP:

```bash
racket app/cli.rkt flash plan.doip.json --transport doip --host 192.168.0.1
```

## CLI

| command | purpose |
|---|---|
| `flash <plan.json>` | run a declarative flash plan (fingerprint gate, power guard, recovery) |
| `verify <plan.json>` | plan + fingerprint checks only — no ECU contact |
| `dtc read \| clear` | diagnostic trouble codes (UDS 0x19 / 0x14) |
| `request <hex>` | one raw UDS request |
| `udid <did>` | read a DID (22 XX XX) |

Exit codes: `0` ok · `1` flash/assert failed · `2` usage · `3` not found · `4` transport.

Every command prints one JSON object — camelCase fields, stable names, bounded error text — so an agent parses output without ever screen-scraping.

## Flash plans

```json
{
  "segments": [{ "address": "0x08000000", "file": "app.hex" }],
  "securityLevel": 1,
  "keyDeriver": "xor0x5a",
  "onFail": "resetAndRetry",
  "powerGuard": { "minMa": 5, "maxMa": 1500, "pollMs": 200 },
  "expectedFingerprint": "e3400821709d3e50"
}
```

- `onFail` — `retry` or `resetAndRetry` (best-effort ECU reset, then one retry).
- `powerGuard` — polls the bench supply while programming; out-of-band current powers off and aborts.
- `expectedFingerprint` — pins the image; mismatch is rejected before any driver call.

Segments take inline hex, `.bin` files, or Intel HEX / S-record images (parsed into one segment per contiguous region). Seed-key algorithms beyond the built-ins plug in as external commands: `"keyDeriver": "command:./my-oem-algo"`.

## Testing

A built-in simulated ECU answers the real ISO-TP/UDS stack hardware-free:

```bash
raco test racket/flashpilot
```

## License

AGPL-3.0.

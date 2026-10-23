# FlashPilot product and pricing plan

**English** · [简体中文](PRICING.zh-CN.md)

## Launch status and implementation boundaries

- Policy version: `2026-10-v2`, 2026-10-23. The owner confirmed that every product is still in development and has no actual users. This document replaces conflicting previous pricing, early-bird and Pro proposals; there is no existing customer cohort to migrate. **Prices are launch targets, not live offers or claims that the listed features are implemented.**
- Entitlements cover delivered platforms only. New commercial plans do not change the LICENSE of released source. Source use, modification and redistribution rights are separate from official products, updates and services.
- Security fixes and reading, backing up or exporting your own data must not require another purchase. BYOK keys, payment-provider secrets and issuer private keys have different owners. Native hosts do not collect payment or issue credentials directly.

## Decision

**Free engine with a purchase for a validated engineering distribution**

Launch target: **Individual: ¥1,499 / US$219; 5 named seats: ¥5,999 / US$879. Optional 12-month update renewal: ¥599 / US$89 per individual, or ¥2,399 / US$359 for 5 seats**. CNY and USD are independently set regional targets, not a live exchange-rate conversion.

A free engine helps the agent ecosystem. Paid differentiation should be real hardware qualification and failure recovery, not an entitlement sold for unverified hardware support.

## Free and paid scope

Free / evaluation: The current AGPL engine, CLI, MCP, existing transports and simulated ECU remain free, including internal production, CI and agent automation. No per-flash charge and no paywall around basic safety checks.

Paid: An officially validated distribution, specific versioned adapter/reference-ECU combinations, reproducible flashing and recovery reports, validated plan assets and their updates/support. Payment is for official validation assets and services; it cannot restrict AGPL rights already granted.

## Purchase, trial and updates

A purchase includes 12 months of new-version eligibility. Versions obtained within that update window remain usable afterwards. Optional renewal adds 12 months from `max(payment time, current updates_through)`, with no back-billing for a gap and no automatic charge. Team renewals apply to the purchased number of named seats. There is no lifetime-all-future-updates plan. One named user can use their own computers; no hardware fingerprint is collected. Offline seat limits are contractual, not real-time concurrency enforcement. A team purchase combines seats; it does not imply a collaboration cloud.

A new paid tier has a full 14-day trial, then returns to the free tier. For a complete paid product, trial expiry preserves reading/search/backup/export. Offline trial state is a convenience and an agreement, not advertised as rollback-proof or impossible to reset. Do not presell codes before technical and platform gates pass. After a successful payment, Commerce issues Permit credentials idempotently. Use release time and `updates_through` for update eligibility; the current date must not suddenly invalidate an acquired version. Do not promise prompt offline refund/revocation enforcement that cannot be implemented.

The target price includes no custom development, hardware procurement, certification or response-time SLA. Support is asynchronous issue handling for the purchased version, supported platforms and validated combinations; a solo maintainer must not promise round-the-clock responses. Before sales, publish refund/cancellation rules, currency/tax totals, privacy terms and support scope, and confirm them at checkout. This plan is not a substitute for final checkout terms.

## Next gate before sales

Complete the hardware-in-the-loop support matrix, power-loss/timeout/recovery scenarios and artifact updates in #4. Establish a paid offer only after at least one real reference ECU/adapter combination has a reproducible report. Do not promise every OEM, security algorithm or safety certification.

Execution entry: [issue #4](https://github.com/turinglambdaai/flashpilot/issues/4). Complete this bounded slice before expanding commercial features.

Portfolio role and shared boundaries: [PORTFOLIO](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/PORTFOLIO.md).

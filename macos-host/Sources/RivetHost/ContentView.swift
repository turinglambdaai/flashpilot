import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            identityHeader
            Divider()
            Form {
                Section("Readiness") {
                    HStack {
                        Button("Validate bench") { model.validate() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy)
                            .accessibilityIdentifier("ValidateBenchButton")
                        if let ok = model.readinessOK {
                            badge(ok ? "Passed" : "Failed", ok: ok)
                        }
                    }
                    resultLine("ReadinessResult", model.readinessSummary)
                }
                Section("Plan verification") {
                    if let directory = model.fixturesDirectory, !model.fixtures.isEmpty {
                        ForEach(model.fixtures, id: \.self) { fixture in
                            Button("Verify \(fixture)") {
                                model.verifyPlan(at: directory.appendingPathComponent(fixture))
                            }
                            .disabled(model.busy)
                            .accessibilityIdentifier("FixtureVerifyButton-\(fixture)")
                        }
                        Text("Bundled plans are shipped inside the app, so verification completes without a source checkout. plan.sim-missing-image.json intentionally references a missing segment image to show failed verification and recovery.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Choose plan…") { model.choosePlan() }
                            .disabled(model.busy)
                            .accessibilityIdentifier("ChoosePlanButton")
                        if let picked = model.pickedPlanURL {
                            Text(picked.lastPathComponent).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    verificationCard
                }
                Section("Diagnostics") {
                    Button("Read DTCs") { model.readDtc() }
                        .disabled(model.busy)
                        .accessibilityIdentifier("ReadDtcButton")
                    resultLine("DtcResult", model.dtcSummary)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 560)
    }

    // Identity card: the target and its honesty label are always the first
    // thing on screen — simulator now, real adapters only after they are
    // qualified. Startup failure renders here with retry; the workflow
    // sections below stay visible but disabled rather than disappearing.
    private var identityHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(RivetGeneratedConfig.displayName).font(.title2).fontWeight(.semibold)
                Spacer()
                if let target = model.target {
                    Text("v\(target.version)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            switch model.phase {
            case .starting:
                Label("Starting embedded engine…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("EngineStatus")
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Engine failed to start", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("EngineStatus")
                    Text(message)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Text("FlashPilot verifies plans with an in-process engine. No ECU command was sent.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Retry") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("RetryBackendButton")
                }
            case .ready:
                if let target = model.target {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(target.ecu.isEmpty ? "No target attached" : target.ecu)
                            .font(.body)
                            .accessibilityIdentifier("TargetLabel")
                        Text("Mode: \(target.mode.isEmpty ? "unknown" : target.mode) · transport \(target.transport)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("TargetModeLabel")
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var verificationCard: some View {
        if let verification = model.verification {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    badge(verification.ok ? "Passed" : "Failed", ok: verification.ok)
                    Text(summary(verification))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("VerificationResult")
                if let kind = verification.errorKind {
                    Text(recoveryHint(kind))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("RecoveryHint")
                }
                if let message = verification.errorMessage {
                    Text(message)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                ForEach(verification.findings) { finding in
                    HStack(alignment: .top, spacing: 8) {
                        Text(finding.severity)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(finding.severity == "error" ? .red : .orange)
                            .frame(width: 56, alignment: .leading)
                        Text(finding.message)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                }
                if let fingerprint = verification.fingerprint {
                    fingerprintRow(verification, fingerprint: fingerprint)
                }
                Button("Export evidence…") { model.exportEvidence() }
                    .accessibilityIdentifier("ExportEvidenceButton")
                if !model.evidencePath.isEmpty {
                    Text(model.evidencePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("EvidencePath")
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        } else {
            Text("No plan verified yet. Start with a bundled simulator plan, or choose a plan file.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("NoPlanState")
        }
    }

    private func fingerprintRow(_ verification: PlanVerification, fingerprint: String) -> some View {
        HStack(spacing: 6) {
            Text("Fingerprint").font(.caption).foregroundStyle(.secondary)
            Text(fingerprint).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            if let expected = verification.expected {
                Text("expected \(expected)").font(.caption).foregroundStyle(.secondary)
                badge(verification.match == true ? "matches" : "mismatch", ok: verification.match == true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("FingerprintLabel")
    }

    private func summary(_ verification: PlanVerification) -> String {
        if let kind = verification.errorKind {
            return "\(kind): \(verification.errorMessage ?? "")"
        }
        let segments = verification.segments.map { "\($0) segment\($0 == 1 ? "" : "s")" } ?? "unknown size"
        return "\(segments) · fingerprint \(verification.fingerprint ?? "—")"
    }

    private func recoveryHint(_ kind: String) -> String {
        switch kind {
        case "plan-unreadable":
            return "The plan file could not be read. Check the path and permissions, then verify again."
        case "plan-invalid":
            return "This file is not a valid flash plan. Fix the reported problem, then verify again."
        case "segment-unavailable":
            return "A segment image referenced by the plan is missing next to the plan file. Restore the image or pick a plan whose images are present."
        default:
            return "Verification could not complete. Resolve the reported problem and try again."
        }
    }

    private func resultLine(_ identifier: String, _ value: String) -> some View {
        Text(value.isEmpty ? "—" : value)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }

    private func badge(_ label: String, ok: Bool) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(ok ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
            .foregroundStyle(ok ? Color.green : Color.red)
            .cornerRadius(6)
    }
}

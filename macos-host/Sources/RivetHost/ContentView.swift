import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationView {
            Form {
                Section("Bench") {
                    row("Status", model.benchStatus)
                    Button("Refresh status") { model.refreshStatus() }
                        .disabled(!model.ready)
                }
                Section("Readiness") {
                    row("Validate", model.validateResult)
                    Button("Validate bench") { model.validate() }
                        .disabled(!model.ready)
                }
                Section("Plan") {
                    row("Verify plan", model.planResult)
                    TextField("Plan path", text: $model.planPath)
                        .font(.system(.footnote, design: .monospaced))
                    Button("Verify plan") { model.verifyPlan() }
                        .disabled(!model.ready)
                }
                Section("Diagnostics") {
                    row("DTC read", model.dtcResult)
                    Button("Read DTCs") { model.readDtc() }
                        .disabled(!model.ready)
                }
            }
            .navigationTitle(RivetGeneratedConfig.displayName)
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

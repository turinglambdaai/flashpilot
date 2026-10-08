import SwiftUI
import RivetEmbedding
import RivetRuntime
import RivetSystem

@main
struct RivetHostApp: App {
    @StateObject private var model = AppModel()
    private let activationRouter = RivetActivationRouter()

    var body: some Scene {
        WindowGroup(RivetGeneratedConfig.displayName) {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 560, minHeight: 480)
                .task { model.start() }
                // URL schemes and file associations are declared from
                // rivet.rktd during packaging. Keep activation handling in the
                // native UI layer; forward only application-level data to the
                // Racket backend when the app actually needs it.
                .onOpenURL { url in activationRouter.handle([url]) }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var ready = false
    @Published var backendStatus = "Starting embedded Racket CS…"
    @Published var benchStatus = ""
    @Published var validateResult = ""
    @Published var planResult = ""
    @Published var planPath = "~/flashpilot/plan.json"
    @Published var dtcResult = ""

    private var backend: EmbeddedRacketBackend?

    func start() {
        guard backend == nil else { return }

        do {
            let config = try EmbeddedRacketConfiguration.resolvedDefault(
                moduleName: RivetGeneratedConfig.moduleName,
                entryName: RivetGeneratedConfig.entryName
            )
            let backend = EmbeddedRacketBackend(configuration: config)
            self.backend = backend

            Task.detached { [backend] in
                do {
                    try backend.start()
                    let api = RivetAPI(client: backend.client)
                    let status = try await api.bench_status()
                    await MainActor.run {
                        self.ready = true
                        self.benchStatus = status
                        self.backendStatus = "Embedded Racket CS is ready"
                    }
                } catch {
                    await MainActor.run {
                        self.ready = false
                        self.backendStatus = "Backend error: \(error)"
                    }
                }
            }
        } catch {
            backendStatus = "Configuration error: \(error)"
        }
    }

    func refreshStatus() {
        guard let backend, ready else { return }
        Task {
            do {
                let api = RivetAPI(client: backend.client)
                benchStatus = try await api.bench_status()
            } catch {
                backendStatus = "Status error: \(error)"
            }
        }
    }

    func validate() {
        guard let backend, ready else { return }
        Task {
            do {
                let api = RivetAPI(client: backend.client)
                validateResult = try await api.bench_validate()
            } catch {
                validateResult = "Error: \(error)"
            }
        }
    }

    func verifyPlan() {
        guard let backend, ready else { return }
        let path = planPath
        Task {
            do {
                let api = RivetAPI(client: backend.client)
                let expanded = (path as NSString).expandingTildeInPath
                planResult = try await api.verify_plan(planPath: expanded)
            } catch {
                planResult = "Error: \(error)"
            }
        }
    }

    func readDtc() {
        guard let backend, ready else { return }
        Task {
            do {
                let api = RivetAPI(client: backend.client)
                dtcResult = try await api.dtc_read()
            } catch {
                dtcResult = "Error: \(error)"
            }
        }
    }
}

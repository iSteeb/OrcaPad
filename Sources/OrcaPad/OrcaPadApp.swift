import SwiftUI

@main
struct OrcaPadApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            PlaterView()
                .environment(environment)
                .task { await environment.bootstrap() }
        }
    }
}

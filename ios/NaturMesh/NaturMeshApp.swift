import SwiftUI

@main
struct NaturMeshApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(Brand.signal)
                .preferredColorScheme(.dark)
                .onAppear { model.start() }
        }
    }
}

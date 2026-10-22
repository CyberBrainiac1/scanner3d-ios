import SwiftUI

@main
struct ScannerApplication: App {
    @State private var model = ScannerModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ScannerRoot(model: model)
                .preferredColorScheme(.light)
                .task { await model.foreground() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.background() }
                    else if phase == .active { model.resumeLink() }
                }
        }
    }
}

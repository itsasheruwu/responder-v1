import SwiftUI

@main
struct ResponderApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .defaultSize(width: 1380, height: 860)

        Window("Memory Inspector", id: "memory-inspector") {
            MemoryInspectorView(model: model)
        }
        .defaultSize(width: 980, height: 620)

        Window("Activity Log", id: "activity-log") {
            ActivityLogView(model: model)
        }
        .defaultSize(width: 980, height: 520)

        Settings {
            SettingsSceneView(model: model)
        }
    }
}

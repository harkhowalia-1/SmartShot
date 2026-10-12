import SwiftUI

@main
struct SmartShotApp: App {
    var body: some Scene {
        WindowGroup {
            CameraView()
                #if os(iOS)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                #else
                .frame(minWidth: 560, minHeight: 640)
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 720, height: 860)
        #endif
    }
}

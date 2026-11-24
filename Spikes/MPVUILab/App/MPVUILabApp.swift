import SwiftUI

/// Spike (never merged): the engine lab with MPVUI only. MPVKit and MPVUI both declare a
/// `Libmpv-GPL` target, so SwiftPM won't resolve them in one graph; this app has no MPVKit.
@main
struct MPVUILabApp: App {
    var body: some Scene {
        WindowGroup {
            if let lab = EngineLab.make() {
                EngineLabView(lab: lab)
            } else {
                Text("Set UITEST_ENGINE_LAB=<config.json>")
            }
        }
    }
}

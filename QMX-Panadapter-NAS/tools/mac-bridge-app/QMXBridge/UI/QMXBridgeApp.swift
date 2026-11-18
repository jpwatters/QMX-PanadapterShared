// QMXBridgeApp.swift - QMX Bridge: the QMX on the NAS as a serial port or a
// TCI radio on this Mac.

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: BridgeModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }
}

@main
struct QMXBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = BridgeModel()

    var body: some Scene {
        WindowGroup("QMX Bridge") {
            ContentView()
                .environmentObject(model)
                .onAppear { delegate.model = model }
        }
    }
}

// BridgeModel.swift - app state: settings, the running bridge or TCI server,
// discovery and probe results.

import Foundation
import SwiftUI

enum SerialMode: String, CaseIterable, Identifiable, Codable {
    case driver = "Virtual USB serial port (driver)"
    case pty = "Pseudo-terminal link (no driver)"
    var id: String { rawValue }
}

@MainActor
final class BridgeModel: ObservableObject {
    @Published var settings = BridgeSettings.load() { didSet { settings.save(); AppLog.shared.verbose = settings.verbose } }
    #if QMX_LITE
    static let hasDriver = false
    #else
    static let hasDriver = true
    #endif
    @Published var serialMode: SerialMode = BridgeModel.hasDriver
        ? (SerialMode(rawValue: UserDefaults.standard.string(forKey: "SerialMode") ?? "") ?? .driver) : .pty {
        didSet { UserDefaults.standard.set(serialMode.rawValue, forKey: "SerialMode") }
    }

    // discovery / probe
    @Published var relays: [Relay] = []
    @Published var discovering = false
    @Published var probeLines: [String] = []
    @Published var probing = false
    @Published var probePassed: Bool?

    // serial
    @Published private(set) var serialRunning = false
    @Published private(set) var serialPath = ""
    @Published private(set) var relayConnected = false
    @Published private(set) var relayHost: String?
    @Published private(set) var driverStatus = DriverEndpoint.Status()
    @Published var ringMode = 0

    // TCI
    @Published private(set) var tciRunning = false
    @Published private(set) var tciClient = false
    @Published private(set) var tciKeyed = false

    let installer = DriverInstaller()
    private var bridge: SerialBridge?
    private var driverEndpoint: DriverEndpoint?
    private var tci: TciServer?
    private var statusTimer: Timer?

    init() {
        AppLog.shared.verbose = settings.verbose
        installer.refresh()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollStatus() }
        }
    }

    private func pollStatus() {
        if let d = driverEndpoint { driverStatus = d.status(); serialPath = d.displayPath }
        if case .installed = installer.state {} else if installer.state != .installing && installer.state != .removing { installer.refresh() }
    }

    // MARK: discovery & probe

    func discover() {
        discovering = true
        let port = settings.discoveryPort
        DispatchQueue.global().async {
            let found = Discovery.discover(udpPort: port)
            DispatchQueue.main.async {
                self.relays = found
                self.discovering = false
                if found.isEmpty { logW("no relay answered QMXR? on UDP \(port)") }
                for r in found { logI("\(r)   -> serial port 3 at \(r.ip):\(self.settings.port)") }
            }
        }
    }

    func use(_ r: Relay) { settings.host = r.ip }

    func probe() {
        probing = true
        probeLines = []
        probePassed = nil
        let s = settings
        let tciOn = tciRunning
        DispatchQueue.global().async {
            let r = Probe.run(settings: s, requireIQ: tciOn)
            DispatchQueue.main.async {
                self.probeLines = r.lines
                self.probePassed = r.passed
                self.probing = false
            }
        }
    }

    // MARK: serial bridge

    func startSerial() {
        if tciRunning { stopTci() }
        let ep: SerialEndpoint
        switch serialMode {
        case .driver:
            let d = DriverEndpoint()
            driverEndpoint = d
            ep = d
        case .pty:
            ep = PtyEndpoint(linkPath: settings.linkPath)
        }
        let b = SerialBridge(settings: settings, endpoint: ep)
        b.onState = { [weak self] c, h in self?.relayConnected = c; self?.relayHost = h }
        do {
            try b.start()
            bridge = b
            serialRunning = true
            serialPath = ep.displayPath
            if let d = driverEndpoint { d.setRingMode(ringMode); driverStatus = d.status() }
        } catch {
            logE("serial port: \(error)")
            driverEndpoint = nil
        }
    }

    func stopSerial() {
        bridge?.stop()
        bridge = nil
        driverEndpoint = nil
        serialRunning = false
        relayConnected = false
        logI("serial port stopped")
    }

    func applyRingMode() { driverEndpoint?.setRingMode(ringMode) }

    // MARK: TCI

    func startTci() {
        if serialRunning { stopSerial() }
        let t = TciServer(settings: settings)
        t.onState = { [weak self] c, k in self?.tciClient = c; self?.tciKeyed = k }
        do {
            try t.start()
            tci = t
            tciRunning = true
        } catch {
            logE("TCI: \(error)")
        }
    }

    func stopTci() {
        tci?.stop()
        tci = nil
        tciRunning = false
        tciClient = false
        tciKeyed = false
        logI("TCI server stopped")
    }

    func shutdown() {
        stopSerial()
        stopTci()
    }
}

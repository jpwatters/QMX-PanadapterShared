// ContentView.swift - the QMX Bridge window.

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: BridgeModel

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                RelayView().tabItem { Text("Relay") }
                SerialView().tabItem { Text("Serial Port") }
                TciView().tabItem { Text("TCI") }
                if BridgeModel.hasDriver {
                    DriverView(installer: model.installer).tabItem { Text("Driver") }
                }
                SettingsView().tabItem { Text("Settings") }
            }
            .padding()
            Divider()
            LogView().frame(minHeight: 160)
        }
        .frame(minWidth: 720, minHeight: 620)
    }
}

// MARK: - Relay: discover + probe

struct RelayView: View {
    @EnvironmentObject var model: BridgeModel

    var body: some View {
        Form {
            Section("Find the NAS relay (QMXR? on UDP \(String(model.settings.discoveryPort)))") {
                HStack {
                    Button(model.discovering ? "Searching…" : "Discover") { model.discover() }
                        .disabled(model.discovering)
                    Text(model.settings.fixedHost.map { "Using fixed address \($0)" } ?? "Address: found automatically")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.relays, id: \.self) { r in
                    HStack {
                        Text(r.description).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Use this address") { model.use(r) }
                    }
                }
            }
            Section("Probe (read-only: ID; FA; MD; on port 3 and the I/Q copy's hello)") {
                HStack {
                    Button(model.probing ? "Probing…" : "Probe") { model.probe() }.disabled(model.probing)
                    if let p = model.probePassed {
                        Text(p ? "PASSED" : "FAILED").bold().foregroundStyle(p ? .green : .red)
                    }
                }
                ForEach(Array(model.probeLines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(.callout, design: .monospaced))
                        .foregroundStyle(l.hasPrefix("FAIL") ? .red : .primary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Serial port

struct SerialView: View {
    @EnvironmentObject var model: BridgeModel

    var body: some View {
        Form {
            Section("QMX serial port 3 on this Mac") {
                if BridgeModel.hasDriver {
                    Picker("Port type", selection: $model.serialMode) {
                        ForEach(SerialMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .disabled(model.serialRunning)
                }
                if model.serialMode == .pty {
                    TextField("Link path", text: $model.settings.linkPath).disabled(model.serialRunning)
                }
                HStack {
                    if model.serialRunning {
                        Button("Stop") { model.stopSerial() }
                    } else {
                        Button("Start") { model.startSerial() }
                    }
                    if model.tciRunning { Text("(starting stops the TCI server: both use port 3)").foregroundStyle(.secondary) }
                }
            }
            if model.serialRunning {
                Section("Status") {
                    LabeledContent("Port") {
                        HStack {
                            Text(model.serialPath).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.serialPath.components(separatedBy: "  ").first ?? model.serialPath, forType: .string)
                            }
                        }
                    }
                    LabeledContent("Relay", value: model.relayConnected ? "connected to \(model.relayHost ?? "?"):\(model.settings.port)"
                                   : "not connected (connects when a program talks to the port)")
                    if model.serialMode == .driver {
                        LabeledContent("Program", value: model.driverStatus.open ? "has the port open" : "none")
                        LabeledContent("Rings", value: model.driverStatus.queues ? "rx \(model.driverStatus.rxSize) / tx \(model.driverStatus.txSize) bytes" : "not connected")
                        if model.driverStatus.rxDropped > 0 {
                            LabeledContent("Dropped radio bytes", value: "\(model.driverStatus.rxDropped)")
                        }
                    }
                }
            }
            Section("Using it") {
                Text("Point WSJT-X, Hamlib/rigctld, fldigi, a logger or a terminal at the port above, as for a QMX on USB (rig: QRP Labs QMX or Kenwood TS-480; any baud rate). The relay is held only while a program talks to it and released after \(model.settings.idle) s idle.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - TCI

struct TciView: View {
    @EnvironmentObject var model: BridgeModel

    var body: some View {
        Form {
            Section("TCI server for WS / WSJT-X 3 / JTDX (receive and transmit audio)") {
                HStack {
                    if model.tciRunning {
                        Button("Stop") { model.stopTci() }
                    } else {
                        Button("Start") { model.startTci() }
                    }
                    Text("ws://\(model.settings.tciListen):\(String(model.settings.tciPort))").font(.system(.body, design: .monospaced))
                    if model.serialRunning { Text("(starting stops the serial port: both use port 3)").foregroundStyle(.secondary) }
                }
            }
            if model.tciRunning {
                Section("Status") {
                    LabeledContent("Program", value: model.tciClient ? "connected" : "waiting for a TCI program")
                    LabeledContent("Transmit", value: model.tciKeyed ? "KEYED" : "receive")
                }
            }
            Section("Setting up the program") {
                Text("In WS/WSJT-X: Settings -> Radio -> Rig 'TCI Client RX1', Network Server \(model.settings.tciListen):\(String(model.settings.tciPort)); Audio comes over TCI. FT8, FT4, JS8, WSPR and Tune transmit one tone at a time (TA<Hz>;). Voice SSB is not supported.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Driver

struct DriverView: View {
    @EnvironmentObject var model: BridgeModel
    @ObservedObject var installer: DriverInstaller

    var stateText: String {
        switch installer.state {
        case .unknown: return "checking…"
        case .notInstalled: return "not installed"
        case .waitingForApproval: return "waiting for your approval in System Settings"
        case .installing: return "installing…"
        case .installed: return DriverEndpoint.isDriverRunning ? "installed and running" : "installed (starting…)"
        case .removing: return "removing…"
        case .failed(let w): return "failed: \(w)"
        }
    }

    var body: some View {
        Form {
            Section("QMX virtual USB serial port driver (DriverKit)") {
                LabeledContent("State", value: stateText)
                HStack {
                    Button("Install / Update") { installer.install() }
                    Button("Remove") { installer.uninstall() }
                    Button("Check") { installer.refresh() }
                }
                Text("The driver makes /dev/cu.\(kQMXSerialTTYBaseName) appear like a USB serial adapter, so every program's port list shows it. macOS asks you to approve it once in System Settings. The app must be in /Applications.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Ring index mode (diagnostic)") {
                Picker("Mode", selection: $model.ringMode) {
                    Text("Free running (default)").tag(0)
                    Text("Wrapped at ring size").tag(1)
                }
                .onChange(of: model.ringMode) { _, _ in model.applyRingMode() }
                Text("Only change this if replies stop after about 16 KB of traffic; the driver also detects free-running indices by itself.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: BridgeModel

    var body: some View {
        Form {
            Section("Relay") {
                TextField("Fixed NAS address (empty = discover)", text: $model.settings.host)
                TextField("Fallback address", text: $model.settings.fallbackHost)
                Stepper("Discovery UDP port: \(String(model.settings.discoveryPort))", value: $model.settings.discoveryPort, in: 1...65535)
                Stepper("Port 3 TCP port: \(String(model.settings.port))", value: $model.settings.port, in: 1...65535)
                Stepper("I/Q copy TCP port: \(String(model.settings.iqPort))", value: $model.settings.iqPort, in: 1...65535)
            }
            Section("Serial port") {
                Stepper("Release the relay after \(model.settings.idle) s idle (0 = never)", value: $model.settings.idle, in: 0...3600, step: 10)
                Toggle("Keep connected all the time", isOn: $model.settings.keepConnected)
            }
            Section("TCI") {
                TextField("Listen address", text: $model.settings.tciListen)
                Stepper("Port: \(String(model.settings.tciPort))", value: $model.settings.tciPort, in: 1...65535)
            }
            Section("Log") {
                Toggle("Log every byte (verbose)", isOn: $model.settings.verbose)
            }
            Text("Changes apply the next time the serial port or TCI server is started.").font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Log

struct LogView: View {
    @ObservedObject var log = AppLog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.text, forType: .string)
                }
                Button("Clear") { log.clear() }
            }
            ScrollViewReader { proxy in
                List(log.lines) { l in
                    LogLineView(line: l).id(l.id)
                }
                .onChange(of: log.lines.count) { _, _ in
                    if let last = log.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding(8)
    }
}

struct LogLineView: View {
    let line: AppLog.Line

    private var color: Color {
        switch line.level {
        case .error: return .red
        case .warning: return .orange
        default: return .primary
        }
    }

    var body: some View {
        let stamp = line.time.formatted(date: .omitted, time: .standard)
        Text(stamp + " " + line.text)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(color)
            .textSelection(.enabled)
    }
}

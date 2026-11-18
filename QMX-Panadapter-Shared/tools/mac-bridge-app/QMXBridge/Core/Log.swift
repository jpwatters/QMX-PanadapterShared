// Log.swift - one log for the whole app, shown in the window and in Console.

import Foundation
import os

final class AppLog: ObservableObject {
    static let shared = AppLog()

    struct Line: Identifiable {
        let id: Int
        let time: Date
        let level: Level
        let text: String
    }

    enum Level: String { case debug = "DEBUG", info = "INFO", warning = "WARN", error = "ERROR" }

    @Published private(set) var lines: [Line] = []
    var verbose = false
    private var next = 0
    private let osLog = Logger(subsystem: "com.qmx.panadapter.bridge", category: "bridge")
    private let maxLines = 2000

    func log(_ level: Level, _ text: String) {
        if level == .debug && !verbose { return }
        switch level {
        case .debug: osLog.debug("\(text, privacy: .public)")
        case .info: osLog.info("\(text, privacy: .public)")
        case .warning: osLog.warning("\(text, privacy: .public)")
        case .error: osLog.error("\(text, privacy: .public)")
        }
        let now = Date()
        DispatchQueue.main.async {
            self.lines.append(Line(id: self.next, time: now, level: level, text: text))
            self.next += 1
            if self.lines.count > self.maxLines { self.lines.removeFirst(self.lines.count - self.maxLines) }
        }
    }

    func clear() { DispatchQueue.main.async { self.lines.removeAll() } }

    var text: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return lines.map { "\(f.string(from: $0.time)) \($0.level.rawValue) \($0.text)" }.joined(separator: "\n")
    }
}

func logD(_ s: @autoclosure () -> String) { if AppLog.shared.verbose { AppLog.shared.log(.debug, s()) } }
func logI(_ s: String) { AppLog.shared.log(.info, s) }
func logW(_ s: String) { AppLog.shared.log(.warning, s) }
func logE(_ s: String) { AppLog.shared.log(.error, s) }

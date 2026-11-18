// DriverInstaller.swift - install / remove the QMX serial driver
// (a DriverKit system extension embedded in the app).

import Foundation
import SystemExtensions

final class DriverInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static let dextIdentifier = "com.qmx.panadapter.bridge.serialdriver"

    enum State: Equatable {
        case unknown, notInstalled, waitingForApproval, installing, installed, removing, failed(String)
    }

    @Published var state: State = .unknown

    func refresh() {
        state = DriverEndpoint.isDriverRunning ? .installed : (state == .waitingForApproval ? state : .notInstalled)
    }

    func install() {
        state = .installing
        logI("driver: asking macOS to install \(Self.dextIdentifier)")
        let r = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.dextIdentifier, queue: .main)
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
    }

    func uninstall() {
        state = .removing
        logI("driver: asking macOS to remove \(Self.dextIdentifier)")
        let r = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.dextIdentifier, queue: .main)
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
    }

    // MARK: OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        logI("driver: replacing version \(existing.bundleShortVersion) (\(existing.bundleVersion)) with \(ext.bundleShortVersion) (\(ext.bundleVersion))")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        logW("driver: approve it in System Settings -> General -> Login Items & Extensions -> Driver Extensions (or Privacy & Security), then come back")
        state = .waitingForApproval
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            logI("driver: done")
        case .willCompleteAfterReboot:
            logW("driver: macOS will finish this after a restart")
        @unknown default:
            logI("driver: finished (\(result.rawValue))")
        }
        if state == .removing {
            state = .notInstalled
        } else {
            // the driver's services appear a moment after activation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
            state = .installed
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let e = error as NSError
        var why = e.localizedDescription
        if e.domain == OSSystemExtensionErrorDomain, let code = OSSystemExtensionError.Code(rawValue: e.code) {
            switch code {
            case .unsupportedParentBundleLocation:
                why = "move QMX Bridge.app to /Applications first (or turn on 'systemextensionsctl developer on')"
            case .missingEntitlement:
                why = "the app or driver is missing a DriverKit entitlement - see tools/mac-bridge-app/README.md"
            case .codeSignatureInvalid, .validationFailed:
                why = "macOS rejected the driver's signature - see README.md (development signing needs SIP relaxed and 'systemextensionsctl developer on')"
            case .requestCanceled:
                why = "cancelled"
            default: break
            }
        }
        logE("driver: \(why) [\(e.domain) \(e.code)]")
        state = .failed(why)
    }
}

import AppKit
import ServiceManagement
import SpikeLog

/// S10: launch at login with `SMAppService.mainApp` (docs/M0-PLAN.md, S10). Run from /Applications.
/// - No arguments at all (macOS at login, or `open` by hand as the control): record how the app was
///   launched and the service status, then quit. Nobody passes --stdout at login, so these runs also
///   write to the unified log: `log show --predicate 'subsystem == "org.izawa.nagi.spike"' --info`.
/// - `--run s10 --action status|register|unregister|settings`: the status before and after the action.
@MainActor enum LoginProbe {
    static func recordLaunch() {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let reason = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        SpikeLog.emit("s10-launch", [
            "eventClass": fourCC(event?.eventClass), "eventID": fourCC(event?.eventID), "propData": fourCC(reason),
            // macOS marks the open-application event of a login launch with this value.
            "launchedAsLoginItem": event?.eventID == AEEventID(kAEOpenApplication)
                && reason == OSType(keyAELaunchedAsLogInItem),
            "parentPID": Int(getppid()), "status": statusName(SMAppService.mainApp.status),
        ])
    }

    static func run(action: String) {
        let service = SMAppService.mainApp
        var fields: [String: any Sendable] = ["action": action, "statusBefore": statusName(service.status)]
        do {
            switch action {
            case "status": break
            case "register": try service.register()
            case "unregister": try service.unregister()
            case "settings": SMAppService.openSystemSettingsLoginItems()
            default: throw ProbeError("unknown --action \(action)")
            }
            fields["succeeded"] = true
        } catch {
            let ns = error as NSError
            fields.merge(["succeeded": false, "domain": ns.domain, "code": ns.code,
                          "message": error.localizedDescription]) { $1 }
        }
        fields["statusAfter"] = statusName(service.status)
        SpikeLog.emit("s10-action", fields)
    }

    private static func statusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }

    /// A four-character code such as "oapp", or "<none>".
    private static func fourCC(_ code: UInt32?) -> String {
        guard let code else { return "<none>" }
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? "\(code)"
    }
}

// PRD-66 Domain 5 — LocalAuthentication. macOS 10.10+. References:
// apple-developer-docs/LocalAuthentication/{LAContext,LAPolicy,LABiometryType}.md.

import Foundation
import LocalAuthentication

final class AuthDomain: DomainHandler, @unchecked Sendable {
    private let lock = NSLock()
    // Reuse a context to honor touchIDAuthenticationAllowableReuseDuration windows.
    private var sharedContext = LAContext()

    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let sub = action["sub"] as? String ?? command
        switch sub {
        case "status":         status(completion: completion)
        case "confirm":        confirm(action, completion: completion)
        case "invalidate":     invalidate(completion: completion)
        case "domain-state":   domainState(completion: completion)
        default:               completion(WireFormat.error("auth.\(sub) — unknown verb"))
        }
    }

    private func policy(from string: String?) -> LAPolicy {
        switch string {
        case "biometry":             return .deviceOwnerAuthenticationWithBiometrics
        case "biometry-or-watch":
            if #available(macOS 10.15, *) { return .deviceOwnerAuthenticationWithBiometricsOrWatch }
            return .deviceOwnerAuthenticationWithBiometrics
        case "watch":
            if #available(macOS 10.15, *) { return .deviceOwnerAuthenticationWithWatch }
            return .deviceOwnerAuthentication
        default:                     return .deviceOwnerAuthentication
        }
    }

    private func biometryString(_ t: LABiometryType) -> String {
        switch t {
        case .faceID: return "faceID"
        case .touchID: return "touchID"
        case .none: return "none"
        @unknown default:
            // .opticID lives on macOS 14+ visionOS — handled with a runtime mirror.
            return String(describing: t)
        }
    }

    private func status(completion: @escaping @Sendable ([String: Any]) -> Void) {
        let ctx = LAContext()
        var nsError: NSError?
        let policyArg: LAPolicy = .deviceOwnerAuthentication
        let canEvaluate = ctx.canEvaluatePolicy(policyArg, error: &nsError)
        var resp: [String: Any] = [
            "canEvaluate": canEvaluate,
            "policy": "deviceOwnerAuthentication",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        if canEvaluate {
            resp["biometryType"] = biometryString(ctx.biometryType)
            resp["error"] = NSNull()
        } else {
            resp["biometryType"] = "none"
            resp["error"] = nsError?.localizedDescription as Any? ?? NSNull()
            if let code = nsError?.code { resp["errorCode"] = code }
        }
        completion(WireFormat.success(resp))
    }

    private func confirm(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let reason = action["reason"] as? String else {
            completion(WireFormat.error("auth.confirm: <reason> required")); return
        }
        let pol = policy(from: action["policy"] as? String)
        lock.lock()
        let ctx = sharedContext
        if let title = action["fallback_title"] as? String { ctx.localizedFallbackTitle = title }
        if let title = action["cancel_title"] as? String { ctx.localizedCancelTitle = title }
        if let reuse = action["reuse_seconds"] as? Int {
            let clamped = min(Double(reuse), LATouchIDAuthenticationMaximumAllowableReuseDuration)
            ctx.touchIDAuthenticationAllowableReuseDuration = clamped
        }
        lock.unlock()

        let started = Date()
        ctx.evaluatePolicy(pol, localizedReason: reason) { ok, error in
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            if ok {
                completion(WireFormat.success([
                    "ok": true,
                    "policy": String(describing: pol),
                    "reason": reason,
                    "biometryType": self.biometryString(ctx.biometryType),
                    "domainState": ctx.evaluatedPolicyDomainState?.map { String(format: "%02x", $0) }.joined() as Any? ?? NSNull(),
                    "elapsedMs": elapsedMs,
                ]))
            } else {
                let nsErr = error as NSError?
                completion(WireFormat.success([
                    "ok": false,
                    "policy": String(describing: pol),
                    "errorCode": nsErr?.code as Any? ?? NSNull(),
                    "errorDomain": nsErr?.domain as Any? ?? NSNull(),
                    "error": nsErr?.localizedDescription as Any? ?? NSNull(),
                ]))
            }
        }
    }

    private func invalidate(completion: @escaping @Sendable ([String: Any]) -> Void) {
        lock.lock()
        sharedContext.invalidate()
        sharedContext = LAContext()
        lock.unlock()
        completion(WireFormat.success(["ok": true]))
    }

    private func domainState(completion: @escaping @Sendable ([String: Any]) -> Void) {
        lock.lock(); let ctx = sharedContext; lock.unlock()
        let hex = ctx.evaluatedPolicyDomainState?.map { String(format: "%02x", $0) }.joined()
        completion(WireFormat.success(["domainState": hex as Any? ?? NSNull()]))
    }
}

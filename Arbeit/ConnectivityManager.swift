import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

// A lightweight connectivity layer for the iOS app to communicate with a future watchOS companion.
// - Sends updates about running orders to the watch
// - Receives commands from the watch (pause/resume, ruest toggle, end, add new order)
final class ConnectivityManager: NSObject {
    static let shared = ConnectivityManager()

    // Weak reference pattern via closures to interact with the existing ViewModel without tight coupling
    // The iOS app should set these closures from a suitable place (e.g., ContentView or App entry) when available.
    var addOrder: ((String) -> Void)?
    var pauseOrResume: ((UUID) -> Void)?
    var toggleRuest: ((UUID) -> Void)?
    var endOrder: ((UUID) -> Void)?

    private override init() {
        super.init()
        activateSessionIfAvailable()
    }

    // MARK: - Session setup
    private func activateSessionIfAvailable() {
        #if canImport(WatchConnectivity)
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
        #endif
    }

    // MARK: - Sending updates
    struct LightweightOrder: Codable {
        let id: UUID
        let nummer: String
        let isRunning: Bool
        let isRuesten: Bool
        let isFertig: Bool
        let datum: Date
    }

    // Call this from iOS whenever orders change to push a lightweight snapshot of running orders.
    func sendRunningOrders(_ orders: [LightweightOrder]) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.isPaired else { return }

        do {
            let data = try JSONEncoder().encode(orders)
            if session.isReachable {
                session.sendMessageData(data, replyHandler: nil, errorHandler: nil)
            } else {
                // Fall back to background transfer
                session.transferUserInfo(["orders": data])
            }
        } catch {
            // Silently ignore encoding errors for now
        }
        #endif
    }

    // Convenience to map from your Auftrag model to LightweightOrder without importing app types here
    // Call site should perform the mapping.
}

#if canImport(WatchConnectivity)
extension ConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    #endif

    // Receive commands from the watch as messages or userInfo
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        handleCommand(message)
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        // Optionally support binary messages in future
        // For now, ignore or try to decode a JSON command dictionary
        if let dict = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] {
            handleCommand(dict)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        handleCommand(userInfo)
    }

    // MARK: - Command handling
    private func handleCommand(_ dict: [String: Any]) {
        guard let action = dict["action"] as? String else { return }
        switch action {
        case "add":
            if let nummer = dict["nummer"] as? String { addOrder?(nummer) }
        case "pauseOrResume":
            if let idString = dict["id"] as? String, let id = UUID(uuidString: idString) { pauseOrResume?(id) }
        case "toggleRuest":
            if let idString = dict["id"] as? String, let id = UUID(uuidString: idString) { toggleRuest?(id) }
        case "end":
            if let idString = dict["id"] as? String, let id = UUID(uuidString: idString) { endOrder?(id) }
        default:
            break
        }
    }
}
#endif

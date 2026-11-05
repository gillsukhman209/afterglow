import Foundation
import Network
import CryptoKit
import Security
import SwiftUI
import os

typealias Packet = [String: Any]
struct RemoteError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private enum DeviceConfig {
    static let values: [String: String] = {
        guard let url = Bundle.main.url(forResource: "TV", withExtension: "plist", subdirectory: "DeviceConfig"),
              let data = try? Data(contentsOf: url),
              let config = try? PropertyListDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return config
    }()
}

// Pin the certificate observed on the intended G1. Never accept an arbitrary
// local certificate or use the Mac's developer/root credentials.
final class TVTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let hash = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        guard hash == DeviceConfig.values["certificateSHA256"]?.lowercased() else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

enum PairingKey {
    static let item: Packet = [kSecClass as String:kSecClassGenericPassword,
                               kSecAttrService as String:"com.gill.afterglow.remote", kSecAttrAccount as String:"G1"]
    static func load() -> String? {
        var query = item
        query[kSecReturnData as String] = true
        var data: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &data) == errSecSuccess, let bytes = data as? Data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
    static func save(_ key: String) {
        let attributes: Packet = [kSecValueData as String:Data(key.utf8), kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        if SecItemUpdate(item as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(item.merging(attributes) { $1 } as CFDictionary,nil)
        }
    }
}

@MainActor final class TV: ObservableObject {
    // A new identifier invalidates drafts from a previous TV field or connection.
    @Published private(set) var keyboardSession: UUID?
    @Published var ready = false
    @Published private(set) var automatic = false
    @Published var connecting = false
    @Published var status = "Connect to your LG G1"
    let host = DeviceConfig.values["host"] ?? "LGwebOSTV.local"
    private lazy var session = URLSession(configuration: .ephemeral, delegate: TVTrust(), delegateQueue: nil)
    private var socket: URLSessionWebSocketTask?
    private var pointer: URLSessionWebSocketTask?
    private var pendingPad: [(PadInput, CGPoint)] = []
    private var sendingPad = false
    @Published var inputIssue: String?
    private var replies = [String: CheckedContinuation<Packet,Error>]()
    private var deadline: Task<Void,Never>?
    private var generation = UUID()
    private var reconnectLoop: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var pairingRejected = false
    private(set) var foreground = false
    private let log = Logger(subsystem: "com.gill.afterglow.remote", category: "Connection")

    @Published private(set) var waking = false
    @Published private(set) var wakeStatus: String?
    private var wakeTask: Task<Void, Never>?

    // This remote is paired to one G1. Its Wi-Fi interface receives a directed
    // magic packet even while the ordinary remote socket is asleep.
    func wake() {
        guard !ready, !waking else { return }
        waking = true
        wakeStatus = "Waking LG G1…"
        guard let address = UserDefaults.standard.string(forKey: "g1.lastIPv4") ?? DeviceConfig.values["wakeAddress"],
              let rawMAC = DeviceConfig.values["wakeMAC"] else {
            waking = false; wakeStatus = "Configure this TV’s wake address first."; return
        }
        let parts = rawMAC.split(separator: ":")
        let mac = parts.compactMap { UInt8($0, radix: 16) }
        guard parts.count == 6, mac.count == 6 else {
            waking = false; wakeStatus = "Check the configured wake MAC address."; return
        }
        let params = NWParameters.udp
        params.requiredInterfaceType = .wifi
        let connection = NWConnection(host: NWEndpoint.Host(address), port: 9, using: params)
        connection.start(queue: .global(qos: .utility))
        var packet = Data(repeating: 0xff, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: mac) }
        start()
        wakeTask = Task {
            defer { connection.cancel(); waking = false }
            for i in 0..<24 {
                guard !Task.isCancelled else { return }
                if ready { wakeStatus = nil; return }
                if i < 4 { connection.send(content: packet, completion: .contentProcessed { _ in }) }
                try? await Task.sleep(for: .seconds(1))
            }
            wakeStatus = "No reply. Check home Wi-Fi and Turn On via Wi-Fi on the TV."
        }
    }

    private func rememberAddress() {
        let name = host
        Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(name, nil, &hints, &list) == 0, let first = list else { return }
            defer { freeaddrinfo(first) }
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &ip, socklen_t(ip.count), nil, 0, NI_NUMERICHOST) == 0 {
                UserDefaults.standard.set(String(cString: ip), forKey: "g1.lastIPv4")
            }
        }
    }

    func resume() {
        foreground = true
        guard PairingKey.load() != nil, !pairingRejected else { return }
        start()
    }

    func suspend() {
        foreground = false
        wakeTask?.cancel(); wakeStatus = nil
        reconnectLoop?.cancel()
        reconnectLoop = nil
        automatic = false
        disconnect("Disconnected")
    }

    func start() {
        guard foreground, reconnectLoop == nil else { return }
        automatic = true
        let pairAgain = pairingRejected
        pairingRejected = false
        reconnectLoop = Task {
            var delay = 1
            var omitOldKey = pairAgain
            while !Task.isCancelled {
                let key = omitOldKey ? nil : PairingKey.load()
                let wasConnected = await connect(key: key)
                guard !Task.isCancelled else { return }
                if pairingRejected || (key == nil && !wasConnected) { break }
                omitOldKey = false
                if wasConnected { delay = 1 }
                status = "Disconnected · Retrying automatically"
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 8)
            }
            if !Task.isCancelled { reconnectLoop = nil; automatic = false }
        }
    }

    private func monitor(_ ws: URLSessionWebSocketTask, generation current: UUID) {
        heartbeat = Task {
            while !Task.isCancelled && current == generation {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, current == generation else { return }
                let watchdog = Task {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled && current == generation { disconnect("Disconnected") }
                }
                ws.sendPing { [weak self] error in
                    Task { @MainActor in
                        watchdog.cancel()
                        if error != nil && self?.generation == current {
                            self?.disconnect("Disconnected")
                        }
                    }
                }
            }
        }
    }

    private func disconnect(_ reason: String) {
        keyboardSession = nil
        generation = UUID()
        pendingPad.removeAll()
        sendingPad = false
        inputIssue = nil
        deadline?.cancel()
        heartbeat?.cancel()
        socket?.cancel(with: .goingAway, reason:nil); socket = nil
        pointer?.cancel(with:.goingAway, reason:nil); pointer = nil
        let waiting = replies; replies.removeAll()
        waiting.values.forEach { $0.resume(throwing:RemoteError(reason)) }
        ready = false; connecting = false; status = reason
    }
    private func connect(key: String?) async -> Bool {
        var wasConnected = false
        disconnect(key == nil ? "Approve Afterglow on the TV" : "Connecting to LG G1…")
        connecting = true
        let current = generation
        let ws = session.webSocketTask(with:URL(string:"wss://"+host+":3001")!)
        socket = ws; ws.resume()
        deadline = Task {
            try? await Task.sleep(nanoseconds:key == nil ? 60_000_000_000 : 6_000_000_000)
            if !Task.isCancelled && current == generation && !ready { disconnect("Pairing timed out. Check Wi-Fi and try again.") }
        }
        do {
            var registration: Packet = ["pairingType":"PROMPT","manifest":[
                "manifestVersion":1,"appVersion":"1.0","appId":"com.gill.afterglow.remote","localizedAppNames":["":"Afterglow"],
                "permissions":["LAUNCH","CONTROL_AUDIO","CONTROL_MOUSE_AND_KEYBOARD","CONTROL_INPUT_TEXT","CONTROL_INPUT_MEDIA_PLAYBACK","READ_CURRENT_CHANNEL"]]]
            if let key { registration["client-key"] = key }
            try await send(["id":"pair","type":"register","payload":registration], via:ws)
            while current == generation {
                let msg = try await ws.receive()
                guard current == generation else { break }
                let data: Data
                switch msg { case .string(let s):data = Data(s.utf8); case .data(let d):data = d; @unknown default:continue }
                guard let packet = try JSONSerialization.jsonObject(with:data) as? Packet else { continue }
                let payload = packet["payload"] as? Packet ?? [:]
                if packet["type"] as? String == "registered" {
                    if let key = payload["client-key"] as? String { PairingKey.save(key) }
                    wakeStatus = nil
                    rememberAddress()
                    wasConnected = true
                    monitor(ws, generation: current)
                    log.info("TV registration confirmed")
                    #if DEBUG
                    print("Afterglow: TV registration confirmed")
                    #endif
                    deadline?.cancel(); ready = true; connecting = false; status = "Connected to LG G1"
                    try await send(["id":"keyboard","type":"subscribe","uri":"ssap://com.webos.service.ime/registerRemoteKeyboard"], via:ws)
                } else if packet["id"] as? String == "keyboard" {
                    if packet["type"] as? String == "error" {
                        keyboardSession = nil
                        inputIssue = "TV typing is unavailable for this connection."
                    } else if let widget = payload["currentWidget"] as? Packet {
                        let type = (widget["contentType"] as? String ?? "").lowercased()
                        if widget["focus"] as? Bool == true && widget["hiddenText"] as? Bool != true && !type.contains("password") {
                            if keyboardSession == nil || payload["focusChanged"] as? Bool == true {
                                keyboardSession = UUID()
                            }
                        } else { keyboardSession = nil }
                    }
                } else if let id = packet["id"] as? String, let reply = replies.removeValue(forKey:id) {
                    if packet["type"] as? String == "error" || payload["returnValue"] as? Bool == false {
                        reply.resume(throwing:RemoteError(packet["error"] as? String ?? "TV declined the command"))
                    } else { reply.resume(returning:payload) }
                } else if packet["type"] as? String == "error" && !ready {
                    pairingRejected = true
                    throw RemoteError("Pairing declined. Tap Pair TV to approve again.")
                }
            }
        } catch { if current == generation { disconnect("Disconnected · " + error.localizedDescription) } }
        return wasConnected
    }
    private func send(_ packet: Packet, via ws: URLSessionWebSocketTask) async throws {
        let bytes = try JSONSerialization.data(withJSONObject:packet)
        try await ws.send(.string(String(decoding:bytes,as:UTF8.self)))
    }
    @discardableResult func request(_ uri:String,_ payload:Packet = [:]) async throws -> Packet {
        guard ready, let ws = socket else { throw RemoteError("Connect to the TV first.") }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            replies[id] = continuation
            Task {
                do { try await send(["type":"request","id":id,"uri":"ssap://"+uri,"payload":payload],via:ws) }
                catch { replies.removeValue(forKey:id)?.resume(throwing:error) }
                try? await Task.sleep(nanoseconds:6_000_000_000)
                replies.removeValue(forKey:id)?.resume(throwing:RemoteError("TV did not answer."))
            }
        }
    }
    func insertTVText(_ text: String, session: UUID?, replace: Bool = false) async throws {
        guard let session, session == keyboardSession else {
            throw RemoteError("Select a TV text field first. Some apps use their own keyboard.")
        }
        try await request("com.webos.service.ime/insertText", ["text":text, "replace":replace])
    }
    func insertSearchTitle(_ title: String) async throws {
        try await insertTVText(title, session: keyboardSession, replace: true)
    }
    func searchYouTube(_ query: String) async throws {
        let target = try YouTubeSearch.target(for: query)
        // The installed G1 app declares contentTarget = q=$SEARCH_KEYWORD.
        // SSAP firmware may populate that field from the top-level contentId.
        try await request("system.launcher/launch", [
            "id": Shortcut.youtube.appID,
            "contentId": target,
            "params": ["contentTarget": target]
        ])
    }
    func button(_ name:String) async throws {
        try await sendPointer("type:button\nname:" + name + "\n\n")
    }

    func pad(_ input: PadInput, delta: CGPoint) {
        guard ready else { return }
        if input != .click, let last = pendingPad.indices.last, pendingPad[last].0 == input {
            pendingPad[last].1.x += delta.x
            pendingPad[last].1.y += delta.y
        } else {
            pendingPad.append((input, delta))
        }
        guard !sendingPad else { return }
        sendingPad = true
        let current = generation
        Task {
            defer { if generation == current { sendingPad = false } }
            while generation == current && !pendingPad.isEmpty {
                let (kind, distance) = pendingPad.removeFirst()
                let frame: String
                switch kind {
                case .click: frame = "type:click\n\n"
                case .move, .scroll:
                    let axes = "dx:\(distance.x)\ndy:\(distance.y)\n"
                    frame = kind == .move ? "type:move\n" + axes + "down:0\n\n" : "type:scroll\n" + axes + "\n"
                }
                do { try await sendPointer(frame) }
                catch {
                    if generation == current { pendingPad.removeAll(); inputIssue = error.localizedDescription }
                    return
                }
            }
        }
    }

    private func sendPointer(_ frame: String) async throws {
        let current = generation
        guard ready else { throw RemoteError("TV disconnected.") }
        if pointer == nil {
            let response = try await request("com.webos.service.networkinput/getPointerInputSocket")
            guard let path = response["socketPath"] as? String, var url = URLComponents(string:path), url.scheme == "wss" else {
                throw RemoteError("The TV did not provide a secure navigation connection.")
            }
            url.host = host
            guard let endpoint = url.url else { throw RemoteError("Invalid navigation address.") }
            guard generation == current, ready else { throw RemoteError("TV disconnected.") }
            if pointer == nil { pointer = session.webSocketTask(with:endpoint); pointer?.resume() }
        }
        guard let active = pointer else { throw RemoteError("Navigation unavailable.") }
        do { try await active.send(.string(frame)) }
        catch {
            if pointer === active { pointer?.cancel(); pointer = nil }
            throw error
        }
    }
}

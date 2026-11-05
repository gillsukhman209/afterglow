import Foundation
import FoundationModels
import Speech
import AVFoundation
import Accelerate
import SwiftUI

enum Shortcut: String, CaseIterable {
    case home = "Afterglow", youtube = "YouTube", netflix = "Netflix", prime = "Prime Video", sling = "Sling"
    var appID: String {
        switch self {
        case .home: return "com.afterglow.lounge"
        case .youtube: return "youtube.leanback.v4"
        case .netflix: return "netflix"
        case .prime: return "amazon"
        case .sling: return "com.movenetworks.app.sling-tv-sling-production"
        }
    }
}
enum Action: Equatable {
    case open(Shortcut), search(Shortcut?, String), button(String), audio(String), mute(Bool), unsupported
    static func from(_ text: String) -> Action? {
        let s = text.lowercased().trimmingCharacters(in:.whitespacesAndNewlines.union(.punctuationCharacters))
        if let route = SearchRouting.action(for: s) { return route }
        switch s {
        case "go home","home":return .open(.home)
        case "back","go back":return .button("BACK")
        case "volume up","louder","turn it up":return .audio("volumeUp")
        case "volume down","quieter","turn it down":return .audio("volumeDown")
        case "mute","mute the tv":return .mute(true)
        case "unmute","unmute the tv":return .mute(false)
        case "pause","play","resume":return .button(s == "pause" ? "PAUSE":"PLAY")
        default:return nil
        }
    }
}
@available(iOS 26.0, *)
@Generable enum TVIntent { case home, youtube, netflix, prime, sling, search, louder, quieter, mute, unmute, back, play, pause, unsupported }
@available(iOS 26.0, *)
@Generable struct Interpretation {
    var intent: TVIntent
    @Guide(description:"For search only, the user's search terms. Otherwise empty.")
    var query: String
}
func understand(_ text: String) async throws -> Action {
    if let intent = Action.from(text) { return intent }
    if #available(iOS 26.0,*), SystemLanguageModel.default.availability == .available {
        let session = LanguageModelSession(instructions:"Interpret one English command to a living-room TV. Return search for content discovery on any streaming service. Extract only the requested title or topic, excluding any app name used as the destination. Keep proper names. Unsupported for requests outside the available actions.")
        let choice = try await session.respond(to:text,generating:Interpretation.self).content
        switch choice.intent {
        case .home:return .open(.home)
        case .youtube:return .open(.youtube)
        case .netflix:return .open(.netflix)
        case .prime:return .open(.prime)
        case .sling:return .open(.sling)
        case .search:let q = choice.query.trimmingCharacters(in:.whitespacesAndNewlines); return q.isEmpty ? .unsupported : .search(SearchRouting.destination(in: text), q)
        case .louder:return .audio("volumeUp")
        case .quieter:return .audio("volumeDown")
        case .mute:return .mute(true)
        case .unmute:return .mute(false)
        case .back:return .button("BACK")
        case .play:return .button("PLAY")
        case .pause:return .button("PAUSE")
        case .unsupported:return .unsupported
        }
    }
    return .unsupported
}

@MainActor final class Microphone: ObservableObject {
    @Published var listening = false
    @Published var preparing = false
    @Published var transcript = ""
    @Published var issue = ""
    private var engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var token = UUID()
    private var tap = false
    private var endpoint: Task<Void, Never>?
    private var lastSpeech: TimeInterval = 0
    private var roomLevel: Float = 0.001
    private let recognizer = SFSpeechRecognizer(locale:Locale(identifier:"en-US"))
    private var finish: ((String)->Void)?
    func begin(completion:@escaping (String)->Void) async {
        guard !listening && !preparing else { return }
        preparing = true; issue = ""; transcript = ""
        let run = UUID(); token = run
        defer { if run == token { preparing = false } }
        let permission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning:$0) }
        }
        guard permission == .authorized, await AVAudioApplication.requestRecordPermission() else {
            issue = "Enable microphone and speech access in iPhone Settings, or type a command."; return
        }
        guard run == token else { return }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            issue = "English speech recognition is unavailable on this iPhone. Type your command below."; return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record,mode:.measurement)
            try session.setActive(true)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.requiresOnDeviceRecognition = true; req.shouldReportPartialResults = true
            req.contextualStrings = ["Afterglow","YouTube","Prime Video","Amazon Prime","Sling"]
            request = req; finish = completion
            let input = engine.inputNode
            let format = input.outputFormat(forBus:0)
            guard format.sampleRate > 0 && format.channelCount > 0 else { throw RemoteError("iPhone microphone unavailable.") }
            lastSpeech = ProcessInfo.processInfo.systemUptime
            roomLevel = 0.001
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                req.append(buffer)
                guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
                var rms: Float = 0
                vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
                let level = rms
                let now = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in
                    guard let self, self.token == run, self.listening else { return }
                    if level > max(0.004, self.roomLevel * 3) { self.lastSpeech = now }
                    self.roomLevel += (level - self.roomLevel) * (level < self.roomLevel ? 0.15 : 0.003)
                }
            }
            tap = true
            try engine.start()
            listening = true
            task = recognizer.recognitionTask(with:req) { [weak self] result,error in
                Task { @MainActor in
                    guard let self, self.token == run else { return }
                    if let words = result?.bestTranscription.formattedString, words != self.transcript {
                        self.transcript = words
                        if self.listening { self.lastSpeech = ProcessInfo.processInfo.systemUptime }
                    }
                    if result?.isFinal == true { self.complete() }
                    else if let error {
                        if !self.listening && !self.transcript.isEmpty { self.complete() }
                        else { self.issue = error.localizedDescription; self.cancel() }
                    }
                }
            }
            endpoint = Task {
                let start = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled && token == run && listening {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled, token == run, listening else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    if (!transcript.isEmpty && now - lastSpeech >= 0.65) || now - start > 30 {
                        stop()
                        return
                    }
                }
            }
        } catch { issue = error.localizedDescription; cancel() }
    }
    func stop() {
        guard listening else { return }
        listening = false; preparing = true
        stopAudio(); request?.endAudio()
        let run = token
        let grace: Duration = transcript.isEmpty ? .milliseconds(700) : .milliseconds(160)
        Task { try? await Task.sleep(for: grace); if token == run { complete() } }
    }
    private func stopAudio() {
        engine.stop()
        if tap { engine.inputNode.removeTap(onBus:0); tap = false }
    }
    private func complete() {
        let words = transcript, callback = finish
        cancel()
        if words.isEmpty { issue = "I didn’t hear a command. Try again." } else { callback?(words) }
    }
    func cancel() {
        endpoint?.cancel(); endpoint = nil; transcript = ""
        token = UUID(); stopAudio(); task?.cancel(); request = nil; task = nil; finish = nil
        listening = false; preparing = false
        try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
    }
}

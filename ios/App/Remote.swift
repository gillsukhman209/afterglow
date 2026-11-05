import SwiftUI

@main struct RemoteApp: App { var body: some Scene { WindowGroup { RemoteView() } } }

struct RemoteView: View {
    @StateObject private var tv = TV()
    @StateObject private var mic = Microphone()
    @State private var text = ""
    @State private var message = ""
    @State private var chooseApp = false
    @State private var undecidedQuery = ""
    @State private var pendingTitle: String?
    @State private var pendingApp: Shortcut?
    @State private var retryTitle: (app: Shortcut, query: String, target: String)?
    @State private var searchRequest = UUID()
    @State private var busy = false
    @Environment(\.scenePhase) private var phase
    @State private var editorSession: UUID?
    @State private var typing = false
    @State private var connectionSheet = false
    @FocusState private var typingFocus: Bool
    @AppStorage("afterglow.remote.controlMode") private var arrows = true
    private let amber = Color(red: 1, green: 0.67, blue: 0.33)
    private let surface = Color(white: 0.105)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image("GlowMark").resizable().scaledToFit().frame(width: 34, height: 34).accessibilityHidden(true)
                Text("Afterglow").font(.system(.title, design: .rounded, weight: .semibold)).tracking(-1.3)
                Spacer()
                Button { connectionSheet = true } label: {
                    HStack(spacing: 7) {
                        Circle().fill(tv.ready ? Color.mint : amber).frame(width: 6, height: 6)
                        Text("LG G1").font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption2.bold())
                    }.padding(.horizontal, 12).frame(minHeight: 44).background(surface, in: Capsule())
                }.accessibilityLabel("LG G1 connection and power")
            }.padding(.horizontal, 20).padding(.vertical, 9)
            GeometryReader { viewport in
                ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !tv.ready { connectionControls }
                    HStack(spacing: 8) {
                        ForEach(Shortcut.allCases.filter { $0 != .home }, id: \.self) { app in
                            Button { send(.open(app)) } label: {
                                Image(app == .prime ? "primevideo" : app.rawValue.lowercased())
                                    .resizable().scaledToFit().frame(maxHeight: app == .sling ? 26 : 35).padding(.horizontal, 9)
                                    .frame(maxWidth: .infinity).frame(height: 55).keySurface(14)
                            }.accessibilityLabel(app.rawValue)
                        }
                    }.disabled(!tv.ready)
                    Spacer(minLength: 0).frame(maxHeight: 36)
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Navigation").font(.headline)
                            Spacer()
                            Picker("Navigation mode", selection: $arrows) {
                                Text("Arrows").tag(true)
                                Text("Touchpad").tag(false)
                            }.pickerStyle(.segmented).frame(maxWidth: 165)
                        }
                        HStack(spacing: 16) {
                            ZStack {
                                if arrows {
                                    ZStack {
                                        Circle().fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.115), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                            .overlay(Circle().strokeBorder(.white.opacity(0.13)))
                                            .shadow(color: .black.opacity(0.9), radius: 5, y: 4)
                                        VStack {
                                            arrow("up", "Up", "UP"); Spacer(); arrow("down", "Down", "DOWN")
                                        }
                                        HStack {
                                            arrow("left", "Left", "LEFT"); Spacer(); arrow("right", "Right", "RIGHT")
                                        }
                                        Button { send(.button("ENTER")) } label: {
                                            Text("OK").font(.headline).frame(width: 72, height: 72)
                                                .background(Color(white: 0.075), in: Circle())
                                                .overlay(Circle().strokeBorder(.white.opacity(0.13)))
                                        }.accessibilityLabel("OK")
                                    }.aspectRatio(1, contentMode: .fit)
                                } else {
                                    ZStack {
                                        VStack(spacing: 10) {
                                            Image(systemName: "hand.draw").font(.title)
                                            Text("Slide to point").font(.headline)
                                            Text("Tap to select").font(.footnote).foregroundStyle(.secondary)
                                        }
                                        Touchpad(send: { tv.pad($0, delta: $1) }).accessibilityLabel("TV touchpad")
                                            .accessibilityHint("Scroll with two fingers or switch to Arrows for individual buttons.")
                                    }.frame(maxWidth: .infinity, maxHeight: .infinity).keySurface(24)
                                }
                            }.frame(maxWidth: .infinity).frame(height: min(285, max(195, viewport.size.height - 280)))
                            VStack(spacing: 0) {
                                rocker("plus", "Volume up") { send(.audio("volumeUp")) }
                                Image(systemName: "speaker.wave.2").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                                rocker("minus", "Volume down") { send(.audio("volumeDown")) }
                            }.frame(width: 56).keySurface(28)
                        }.padding(.horizontal, 5).disabled(!tv.ready)
                        HStack(spacing: 7) {
                            actionKey("arrow.uturn.backward", "Back") { send(.button("BACK")) }
                            actionKey("house", "Home") { send(.open(.home)) }
                            actionKey("play.fill", "Play") { playback("play") }
                            actionKey("pause.fill", "Pause") { playback("pause") }
                            actionKey("speaker.slash", "Mute") { send(.button("MUTE")) }
                        }.disabled(!tv.ready)
                    }.padding(15).background(Color(white: 0.068), in: RoundedRectangle(cornerRadius: 26))
                        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.075)))
                    if !mic.issue.isEmpty || !message.isEmpty {
                        Text(!mic.issue.isEmpty ? mic.issue : message).font(.subheadline).foregroundStyle(.secondary)

                    }
                    if let retry = retryTitle {
                        Button("Open “" + retry.query + "” again") {
                            Task { do { try await openTitle(retry.app, target: retry.target) } catch { message = error.localizedDescription } }
                        }.buttonStyle(.bordered).disabled(!tv.ready)
                    }
                    if let title = pendingTitle, let app = pendingApp {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Select Search in " + app.rawValue + " on the TV.").font(.subheadline)
                            Button("Send title · " + title) {
                                Task { do { try await tv.insertSearchTitle(title); pendingTitle = nil; message = "Title sent." } catch { message = error.localizedDescription } }
                            }.buttonStyle(.bordered)
                        }.disabled(!tv.ready)
                    }
                }.frame(minHeight: max(0, viewport.size.height - 24), alignment: .top)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                }.scrollDismissesKeyboard(.interactively)
            }
            if let session = editorSession, session == tv.keyboardSession {
                TVFieldEditor(session: session, tv: tv) { editorSession = nil }
                    .id(session)
            } else if typing {
                HStack {
                    TextField("Type a TV command", text: $text).focused($typingFocus).submitLabel(.send).onSubmit { submit(text) }
                    Button { submit(text) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2).frame(width:44,height:44) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || !tv.ready).accessibilityLabel("Send command")
                }.padding(.leading, 16).keySurface(16).padding(.horizontal, 18)
            }
            HStack(spacing: 10) {
                Button {
                    if mic.listening { mic.stop() }
                    else {
                        text = ""; typing = false; typingFocus = false; message = ""
                        Task { await mic.begin { words in text = ""; submit(words) } }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: mic.listening ? "waveform" : "mic.fill").font(.title3)
                        Text(mic.listening ? (mic.transcript.isEmpty ? "Listening…" : mic.transcript) : busy ? "Sending…" : "Speak a command")
                            .font(.headline).lineLimit(2)
                        Spacer()
                    }.padding(.horizontal, 19).frame(maxWidth: .infinity).frame(minHeight: 58)
                        .foregroundStyle(.black).background(amber, in: RoundedRectangle(cornerRadius: 19))
                }.disabled(!tv.ready || mic.preparing || busy)
                Button {
                    if let session = tv.keyboardSession {
                        editorSession = editorSession == session ? nil : session
                    } else { typing.toggle(); typingFocus = typing }
                } label: {
                    Image(systemName: typing ? "keyboard.chevron.compact.down" : "keyboard").font(.title3)
                        .frame(width: 58, height: 58).keySurface(19)
                }.accessibilityLabel(tv.keyboardSession != nil ? "TV keyboard" : typing ? "Hide keyboard" : "Type a command").disabled(!tv.ready || mic.listening)
            }.padding(.horizontal, 18).padding(.vertical, 10)
        }.background(Color.black.ignoresSafeArea()).foregroundStyle(.white).buttonStyle(.plain).tint(amber).preferredColorScheme(.dark)
        .sheet(isPresented: $connectionSheet) {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("LG G1").font(.title.bold()); Spacer(); Button("Done") { connectionSheet = false } }
                connectionControls
            }.padding(24).presentationDetents([.medium]).presentationDragIndicator(.visible).preferredColorScheme(.dark)
        }
        .onChange(of: tv.keyboardSession) { _, session in
            if session != nil {
                mic.cancel(); typing = false; typingFocus = false; chooseApp = false; connectionSheet = false
            }
            editorSession = session
        }
        .onChange(of: tv.inputIssue) { _, issue in
            if let issue { message = issue; tv.inputIssue = nil }
        }
        .confirmationDialog("Search which app?", isPresented:$chooseApp, titleVisibility:.visible) {
            ForEach(Shortcut.allCases.filter{$0 != .home}, id:\.self) { app in
                Button(app.rawValue) { send(.search(app, undecidedQuery)) }
            }
        }
        .onChange(of: phase, initial: true) { _, value in
            if value == .active { tv.resume() }
            if value == .background { mic.cancel(); tv.suspend() }
        }
        .onChange(of: tv.ready) { _, ready in
            if !ready { mic.cancel(); chooseApp = false; pendingTitle = nil; message = "" }
        }

    }
    private func playback(_ command: String) {
        Task {
            do { try await tv.request("media.controls/" + command); message = "" }
            catch { message = "Playback control unavailable in this app." }
        }
    }

    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tv.wakeStatus ?? tv.status).font(.subheadline)
            if !tv.ready {
                HStack {
                    Button("Wake TV") { tv.wake() }.disabled(tv.waking)
                    if !tv.automatic { Button("Pair TV") { tv.start() } }
                }.buttonStyle(.bordered)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func arrow(_ direction: String, _ title: String, _ command: String) -> some View {
        Button { send(.button(command)) } label: {
            Image(systemName: "chevron." + direction).font(.body.weight(.semibold))
                .frame(width: 56, height: 47).contentShape(Rectangle())
        }.accessibilityLabel(title)
    }

    private func rocker(_ icon: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: icon).font(.title3).frame(width: 55, height: 60) }
            .accessibilityLabel(label)
    }

    private func actionKey(_ icon: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.body.weight(.medium))
                Text(label).font(.caption2.weight(.medium))
            }.frame(maxWidth: .infinity).frame(minHeight: 56).keySurface(13)
        }.accessibilityLabel(label)
    }
    private func submit(_ value:String) {
        let words=value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard tv.ready && !busy && !words.isEmpty else{return}
        text = ""; typing = false; typingFocus = false
        busy=true; mic.issue="";message="Understanding…"
        Task {
            defer{busy=false}
            do{try await execute(try await understand(words))}
            catch{message=error.localizedDescription}
        }
    }
    private func send(_ action:Action) {
        mic.issue=""
        Task { do{try await execute(action)}catch{message=error.localizedDescription} }
    }
    private func openTitle(_ app: Shortcut, target: String) async throws {
        try await tv.request("system.launcher/launch", [
            "id": app.appID, "contentId": target, "params": ["contentTarget": target]
        ])
        message = "If " + app.rawValue + " asks, choose your profile and press OK. If it lands on Home, tap below."
    }

    private func execute(_ action:Action) async throws {
        switch action {
        case .search(let app, let q):
            guard tv.ready else{throw RemoteError("Connect the TV, then search again.")}
            let request = UUID()
            searchRequest = request
            pendingTitle = nil
            retryTitle = nil
            guard let app else { undecidedQuery=q; chooseApp=true; message="Choose where to search"; return }
            if app == .youtube {
                try await tv.searchYouTube(q)
                message="Sent search to YouTube on your TV"
            } else if app == .prime || app == .netflix {
                message = "Looking up “" + q + "” on " + app.rawValue + "…"
                var reason = "No clear title match."
                var target: String?
                if app == .prime {
                    do { target = try await PrimeSearch.titleID(for: q) }
                    catch is CancellationError { return }
                    catch { reason = "Prime’s title lookup is unavailable." }
                } else {
                    target = NetflixSearch.target(for: q)
                }
                guard searchRequest == request, tv.ready else { return }
                if let target {
                    retryTitle = (app, q, target)
                    try await openTitle(app, target: target)
                } else {
                    try await tv.request("system.launcher/launch", ["id": app.appID])
                    guard searchRequest == request else { return }
                    pendingApp = app
                    pendingTitle = q
                    message = reason + " Open Search in " + app.rawValue + " on your TV."
                }
            } else {
                try await tv.request("system.launcher/launch", ["id":app.appID])
                pendingApp=app; pendingTitle=q; message="Opened "+app.rawValue
            }
        case .open(let app): searchRequest = UUID(); retryTitle = nil; pendingTitle=nil; try await tv.request("system.launcher/launch",["id":app.appID]);message="Sent to TV · "+app.rawValue
        case .audio(let method):try await tv.request("audio/"+method);message=method=="volumeUp" ? "Volume up":"Volume down"
        case .mute(let mute):try await tv.request("audio/setMute",["mute":mute]);message=mute ? "Muted":"Sound on"
        case .button(let key):try await tv.button(key);message="Sent to TV · "+key.capitalized
        case .unsupported: message="Try “open Netflix”, “turn it down”, or “search YouTube for jazz”."
        }
    }
}

private struct TVFieldEditor: View {
    let session: UUID
    @ObservedObject var tv: TV
    var close: () -> Void
    @State private var draft = ""
    @State private var sending = false
    @State private var issue = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Type on TV", text: $draft)
                    .focused($focused).submitLabel(.send).onSubmit(send)
                    .disabled(sending)
                Button("Send", action: send).disabled(draft.isEmpty || sending)
                Button(action: close) { Image(systemName: "xmark.circle") }
                    .accessibilityLabel("Close TV keyboard")
            }.padding(12).keySurface(14)
            if !issue.isEmpty { Text(issue).font(.footnote) }
        }.padding(.horizontal, 18)
        .task {
            await Task.yield()
            focused = true
        }
    }

    private func send() {
        guard !draft.isEmpty, !sending, tv.keyboardSession == session else { return }
        let value = draft
        sending = true; issue = ""
        Task {
            do {
                try await tv.insertTVText(value, session: session)
                if tv.keyboardSession == session { close() }
            } catch { issue = error.localizedDescription }
            sending = false
        }
    }
}

private extension View {
    func keySurface(_ radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(LinearGradient(colors: [Color(white: 0.15), Color(white: 0.105)], startPoint: .top, endPoint: .bottom), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.085)))
    }
}

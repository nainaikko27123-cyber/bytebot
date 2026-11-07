// Byte: a little green robot that lives on your desktop, chats with Gemini and talks out loud.
// Build with ./build.sh

import SwiftUI
import AppKit
import AVFoundation
import Security

// MARK: - ✿ TWEAK ME: all of Byte's numbers in one place

enum Tune {
    // Size
    static let scale: CGFloat = 0.6           // overall size of Byte on screen
    static let headSize: CGFloat = 1.0        // head size (1.0 = chibi default, try 1.1 for extra big head)
    static let eyeSize: CGFloat = 1.0         // eye size (try 1.15 for huge anime eyes)

    // When things happen
    static let walkAfterSeconds: Double = 15  // quiet time before he goes for a walk
    static let sleepAfterSeconds: Double = 60 // quiet time before he falls asleep

    // Walking
    static let walkSpeed: CGFloat = 45        // top walking speed (screen points per second)
    static let walkAccel: CGFloat = 60        // how quickly he speeds up when starting
    static let walkDecel: CGFloat = 45        // how gently he slows down before stopping
    static let stepLength: CGFloat = 15       // how often the tracks "rumble" as he rolls (smaller = faster rumble)
    static let bobHeight: CGFloat = 1.2       // tiny rumble bounce while rolling (was 5 with legs)
    static let squashAmount: CGFloat = 0.015  // very soft squash & stretch while rolling
    static let treadSpacing: CGFloat = 9      // gap between the tread teeth on his tracks
    static let leanDegrees: Double = 5        // how far he leans into his walk
    static let turnSpeed: CGFloat = 9         // how fast he turns around (higher = snappier)
    static let pauseMin: Double = 1.0         // shortest pause between walks (seconds)
    static let pauseMax: Double = 2.6         // longest pause between walks (seconds)

    // Face
    static let blinkMin: Double = 2.2         // shortest time between blinks (seconds)
    static let blinkMax: Double = 6.0         // longest time between blinks (seconds)
    static let doubleBlinkChance: Double = 0.25
    static let eyeLookDistance: CGFloat = 5   // how far his eyes move when looking around
    static let lookRange: CGFloat = 450       // how close your mouse must be for him to watch it
    static let blushColor = Color(red: 1.0, green: 0.52, blue: 0.64)

    // Fun stuff
    static let hopHeight: CGFloat = 14        // happy-hop height
    static let idleActionMin: Double = 5      // shortest wait between idle fidgets (seconds)
    static let idleActionMax: Double = 11     // longest wait between idle fidgets
    static let antennaSpringiness: Double = 150  // higher = stiffer antenna
    static let antennaDamping: Double = 6        // lower = wobblier antenna
    static let buddyDefaultOn = true          // the little propeller cube friend (also in the menu)
}

// MARK: - Theme (green + black)

extension Color {
    static let neon     = Color(red: 0.00, green: 1.00, blue: 0.53)  // #00FF88
    static let neonMid  = Color(red: 0.00, green: 0.75, blue: 0.40)
    static let neonDim  = Color(red: 0.00, green: 0.38, blue: 0.20)
    static let shell    = Color(red: 0.04, green: 0.07, blue: 0.05)
    static let screen   = Color(red: 0.01, green: 0.03, blue: 0.02)
    static let alert    = Color(red: 1.00, green: 0.35, blue: 0.35)
    // Byte's body colours: white shell, black head, lime eyes
    static let lime       = Color(red: 0.72, green: 1.00, blue: 0.20)
    static let limeDeep   = Color(red: 0.24, green: 0.42, blue: 0.04)
    static let shellWhite = Color(red: 0.95, green: 0.96, blue: 0.96)
    static let shellShade = Color(red: 0.76, green: 0.79, blue: 0.79)
    static let shellLine  = Color(red: 0.45, green: 0.48, blue: 0.48)
    static let ink        = Color(red: 0.06, green: 0.07, blue: 0.07)
    static let ink2       = Color(red: 0.17, green: 0.18, blue: 0.18)
}
let mono = Font.system(size: 11.5, weight: .medium, design: .monospaced)

// MARK: - API key in the macOS Keychain (never in a plain file)

enum Keychain {
    static let service = "ByteBot", account = "gemini-api-key"
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    static func save(_ value: String) {
        delete()
        var q = base; q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
    static func load() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete() { SecItemDelete(base as CFDictionary) }
}

// MARK: - Gemini (the brain)

struct Turn { let role: String; let text: String }   // role: "user" or "model"

enum BrainError: LocalizedError {
    case badKey, limit, network(String), empty
    var errorDescription: String? {
        switch self {
        case .badKey: return "That API key didn't work. Right-click me and choose Change API key."
        case .limit: return "I've hit the free Gemini limit for now. Try again in a minute."
        case .network(let m): return "I couldn't reach Gemini. \(m)"
        case .empty: return "Hmm, I drew a blank. Ask me again?"
        }
    }
}

final class Gemini {
    private var model: String?
    private let host = "https://generativelanguage.googleapis.com/v1beta/"

    let persona = """
    You are Byte, a small friendly green robot who lives on the user's Mac desktop.
    Everything you say is read aloud by a text-to-speech voice, so:
    - Keep replies short: one to three sentences unless the user asks for more.
    - Sound natural and conversational. No markdown, no bullet lists, no emoji, no code blocks, no URLs read out.
    - Be warm, a little playful, and genuinely helpful.
    The user is studying for an IT diploma and loves fun, good-looking tech projects.
    """

    private func request(_ path: String, key: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: host + path)!)
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.timeoutInterval = 45
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw BrainError.network("Check your internet connection.") }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch code {
        case 200: return json
        case 400, 401, 403:
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? ""
            if msg.lowercased().contains("key") || code != 400 { throw BrainError.badKey }
            throw BrainError.network(msg)
        case 429: throw BrainError.limit
        default:
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "Error \(code)."
            throw BrainError.network(msg)
        }
    }

    // Pick the newest general "flash" model this key can use, so Byte keeps working as Google releases new ones.
    private func pickModel(key: String) async throws -> String {
        if let model { return model }
        let json = try await request("models?pageSize=200", key: key)
        let skip = ["image", "tts", "audio", "live", "embedding", "vision", "thinking", "learnlm"]
        let names = (json["models"] as? [[String: Any]] ?? []).compactMap { m -> String? in
            guard let name = m["name"] as? String,
                  (m["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent"),
                  name.contains("flash"),
                  !skip.contains(where: { name.contains($0) }) else { return nil }
            return name
        }
        func version(_ n: String) -> Double {
            let s = n.replacingOccurrences(of: "models/gemini-", with: "")
            return Double(s.prefix { "0123456789.".contains($0) }) ?? 0
        }
        func penalty(_ n: String) -> Int {
            (n.contains("lite") ? 2 : 0) + (n.contains("preview") || n.contains("exp") ? 1 : 0)
        }
        let best = names.sorted {
            penalty($0) != penalty($1) ? penalty($0) < penalty($1) : version($0) > version($1)
        }.first ?? "models/gemini-2.5-flash"
        model = best
        return best
    }

    func reply(history: [Turn], key: String) async throws -> String {
        let m = try await pickModel(key: key)
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": persona]]],
            "contents": history.map { ["role": $0.role, "parts": [["text": $0.text]]] },
            "generationConfig": ["temperature": 0.85, "maxOutputTokens": 2048]
        ]
        let json = try await request("\(m):generateContent", key: key, body: body)
        let parts = (((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw BrainError.empty }
        return text
    }
}

// MARK: - Voice (the Mac's built-in speech, free and offline)

final class Voice: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var speaking = false
    @Published var mouth: CGFloat = 0         // 0 = closed, 1 = wide open
    @Published var muted = UserDefaults.standard.bool(forKey: "muted") {
        didSet { UserDefaults.standard.set(muted, forKey: "muted"); if muted { stop() } }
    }
    var onFinish: (() -> Void)?
    private let synth = AVSpeechSynthesizer()

    // ── Voice choice (saved between launches) ──
    @Published var voiceID: String? = UserDefaults.standard.string(forKey: "voiceID")

    /// English voices on this Mac, one per name+accent, nicest first; robot/novelty voices last.
    static var englishVoices: [AVSpeechSynthesisVoice] {
        var seen = Set<String>()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .filter { seen.insert($0.name + $0.language).inserted }
            .sorted {
                let a = $0.voiceTraits.contains(.isNoveltyVoice), b = $1.voiceTraits.contains(.isNoveltyVoice)
                if a != b { return !a }
                if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                return ($0.name, $0.language) < ($1.name, $1.language)
            }
    }
    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        let accent = Locale.current.localizedString(forRegionCode: String(v.language.suffix(2))) ?? v.language
        let star = v.quality == .premium ? "  ✦✦" : v.quality == .enhanced ? "  ✦" : ""
        return "\(v.name) (\(accent))\(star)"
    }

    private var voice: AVSpeechSynthesisVoice? {
        if let id = voiceID, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return Voice.englishVoices.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }
    var currentVoiceID: String? { voice?.identifier }

    func choose(_ id: String) {
        voiceID = id
        UserDefaults.standard.set(id, forKey: "voiceID")
        let wasMuted = muted
        if wasMuted { muted = false }
        say("Hi, I'm Byte. Do you like this voice?")
        if wasMuted { muted = true }
    }

    override init() { super.init(); synth.delegate = self }

    func say(_ text: String, softly: Bool = false) {
        guard !muted else { DispatchQueue.main.async { self.onFinish?() }; return }
        stop()
        let u = AVSpeechUtterance(string: Voice.clean(text))
        u.voice = voice
        let novelty = voice?.voiceTraits.contains(.isNoveltyVoice) ?? false
        u.rate = softly ? 0.42 : 0.52
        u.volume = softly ? 0.7 : 1.0
        u.pitchMultiplier = novelty ? 1.0 : (softly ? 1.0 : 1.12)
        synth.speak(u)
    }
    func stop() { if synth.isSpeaking { synth.stopSpeaking(at: .immediate) } }

    // Remove markdown so it isn't read out loud ("asterisk asterisk...")
    static func clean(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "the link", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[*_`#>~]"#, with: "", options: .regularExpression)
        return t
    }

    // Mouth flaps on every word
    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.mouth = CGFloat.random(in: 0.65...1.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { if self.speaking { self.mouth = 0.25 } }
        }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speaking = true }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { done() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { done() }
    private func done() {
        DispatchQueue.main.async { self.speaking = false; self.mouth = 0; self.onFinish?() }
    }
}

// MARK: - Byte's brain + chat state

enum Mood { case idle, thinking, speaking, error }

final class Bot: ObservableObject {
    @Published var bubble = "Hey! I'm Byte. Type below and I'll talk back."
    @Published var input = "" { didSet { if !input.isEmpty { poke() } } }
    @Published var mood: Mood = .idle
    @Published var needsKey = Keychain.load() == nil
    @Published var keyDraft = ""
    @Published var waving = false
    @Published var asleep = false
    @Published var walking = false          // strolling along the bottom of the screen
    var chatVisible: Bool { !asleep && !walking }
    var lastActivity = Date()
    var onWake: ((_ fromSleep: Bool) -> Void)?
    let voice = Voice()
    private let brain = Gemini()
    private var history: [Turn] = []

    var busy: Bool { mood == .thinking || voice.speaking || !input.isEmpty || needsKey }

    /// Anything the user does counts as activity and wakes Byte up.
    func poke() {
        lastActivity = Date()
        if asleep || walking {
            let fromSleep = asleep
            asleep = false; walking = false
            onWake?(fromSleep)
        }
    }

    init() {
        voice.onFinish = { [weak self] in
            if self?.mood == .speaking { self?.mood = .idle }
            self?.lastActivity = Date()   // the quiet-time countdown starts after Byte finishes talking
        }
        if needsKey { bubble = "Hi! I'm Byte. To wake up my brain, paste a free Gemini API key below." }
        else { greet() }
    }

    func greet() {
        waving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { self.waving = false }
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "morning" : hour < 18 ? "afternoon" : "evening"
        speak("Good \(part)! Byte here. What are we doing today?")
    }

    func sleepyLine() {
        let lines = ["Mmh… five more minutes…", "*yawn* Oh! Hi. I'm up, I'm up.", "Was I snoring? I was totally not snoring."]
        bubble = lines.randomElement()!
        mood = .speaking
        voice.say(bubble, softly: true)
    }

    func speak(_ text: String) {
        bubble = text
        mood = .speaking
        voice.say(text)
    }

    func pasteKey() {
        if let s = NSPasteboard.general.string(forType: .string) {
            keyDraft = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func saveKey() {
        let k = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        Keychain.save(k)
        keyDraft = ""
        needsKey = false
        greet()
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, mood != .thinking, let key = Keychain.load() else { return }
        input = ""
        voice.stop()
        history.append(Turn(role: "user", text: text))
        if history.count > 24 { history.removeFirst(history.count - 24) }
        mood = .thinking
        bubble = "…"
        let snapshot = history
        Task {
            do {
                let reply = try await brain.reply(history: snapshot, key: key)
                await MainActor.run {
                    self.history.append(Turn(role: "model", text: reply))
                    self.speak(reply)
                }
            } catch {
                await MainActor.run {
                    self.history.removeLast()
                    self.mood = .error
                    self.bubble = error.localizedDescription
                    if case BrainError.badKey = error { self.needsKey = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                        if self?.mood == .error { self?.mood = .idle }
                    }
                }
            }
        }
    }

    func clearChat() { history.removeAll(); voice.stop(); mood = .idle; bubble = "Fresh start! What's up?" }
    func changeKey() { voice.stop(); needsKey = true; bubble = "Paste your new Gemini API key below." }
}

// MARK: - Motion: every moving part of Byte, updated up to 60 times a second

func approach(_ v: CGFloat, _ target: CGFloat, _ step: CGFloat) -> CGFloat {
    v < target ? min(v + step, target) : max(v - step, target)
}

final class Motion: ObservableObject {
    @Published var tick = 0                  // bumping this redraws Byte
    @Published var showBuddy = UserDefaults.standard.object(forKey: "showBuddy") as? Bool ?? Tune.buddyDefaultOn {
        didSet { UserDefaults.standard.set(showBuddy, forKey: "showBuddy") }
    }

    var time: Double = 0

    // ── where the window sits on screen (smooth floating-point numbers, not whole pixels) ──
    var pos = CGPoint.zero
    var walking = false
    var vx: CGFloat = 0                      // current sideways speed (points/second)
    var dir: CGFloat = 1                     // which way he wants to go: 1 right, -1 left
    var facing: CGFloat = 1                  // smoothly follows dir, so turning is a quick flip, not a snap
    var targetX: CGFloat?
    var pause: Double = 0
    var phase: CGFloat = 0                   // walk-cycle position (one full step = π)

    // ── body ──
    var bob: CGFloat = 0, squash: CGFloat = 0, lean: Double = 0
    var trackDist: CGFloat = 0               // how far he has rolled (drives treads + wheels)
    var hopY: CGFloat = 0, hopV: CGFloat = 0, landSquash: CGFloat = 0
    var tilt: Double = 0, tiltTarget: Double = 0, tiltLeft: Double = 0
    var antenna: Double = 0, antennaV: Double = 0
    var stretchLeft: Double = 0              // wake-up stretch timer
    let stretchTime: Double = 1.8
    private var lastVx: CGFloat = 0

    // ── face ──
    var look = CGPoint.zero                  // -1...1, where the eyes point
    var mouse = CGPoint(x: 9999, y: 9999)    // your cursor, relative to his head (points, y down)
    var lid: CGFloat = 0                     // 0 open, 1 closed
    private var blinkIn = 3.0, blinkT: Double = -1, secondBlink = false
    var happyLeft: Double = 0
    var blush: CGFloat = 0
    var lookAroundLeft: Double = 0
    private var idleIn = 7.0

    // ── helper buddy (position relative to Byte's feet, in Byte's own units) ──
    var buddy = CGPoint(x: -104, y: -212), buddyV = CGPoint.zero

    // ── clickable areas (window coordinates, top-left origin) ──
    var robotRect = CGRect.zero
    var chatRect = CGRect.zero
    /// Just his head + body: clicks anywhere else fall through to the apps underneath.
    var bodyHitRect: CGRect {
        let r = robotRect
        return CGRect(x: r.minX + r.width * 0.14, y: r.minY + r.height * 0.27,
                      width: r.width * 0.72, height: r.height * 0.73)
    }
    /// Head centre in window coordinates (for eyes following the mouse)
    var headCenter: CGPoint { CGPoint(x: robotRect.midX, y: robotRect.minY + robotRect.height * 0.5) }

    var stretchAmount: CGFloat {
        stretchLeft > 0 ? CGFloat(sin((1 - stretchLeft / stretchTime) * .pi)) : 0
    }
    /// True while something lively is happening (used to pick a frame rate)
    var lively: Bool { walking || abs(vx) > 0.5 || hopY > 0 || happyLeft > 0 || stretchLeft > 0 || abs(antennaV) > 2 }

    // ── actions ──
    func hop(_ h: CGFloat) { if hopY <= 0 && hopV <= 0 { hopV = sqrt(2 * 900 * h) } }
    func happy() { happyLeft = 1.4; hop(Tune.hopHeight); antennaV += 120 }
    func wakeUp() { stretchLeft = stretchTime; lookAroundLeft = 0 }
    func startWalking(from origin: CGPoint) {
        pos = origin; walking = true; targetX = nil; pause = 0.5; vx = 0
    }
    func stopWalking() { walking = false; vx = 0; targetX = nil }

    private func pickTarget(minX: CGFloat, maxX: CGFloat, width: CGFloat, dockMid: CGFloat) -> CGFloat {
        let lo = minX + 8, hi = max(lo + 1, maxX - width - 8)
        // sometimes stroll over towards the Dock, like it's his favourite spot on the floor
        if Double.random(in: 0..<1) < 0.3 {
            return min(hi, max(lo, dockMid - width / 2 + CGFloat.random(in: -160...160)))
        }
        var x = CGFloat.random(in: lo...hi)
        for _ in 0..<8 where abs(x - pos.x) < 140 { x = CGFloat.random(in: lo...hi) }
        return x
    }

    /// One animation frame. dt = seconds since the last frame, so speed is the same on any Mac.
    func update(dt: Double, asleep: Bool, thinking: Bool, speaking: Bool, idle: Bool,
                screen: CGRect?, dockMid: CGFloat, windowWidth: CGFloat, windowDX: CGFloat, redraw: Bool = true) {
        time += dt
        let f = CGFloat(dt)

        // ── 1. walking along the floor ──
        if walking, let scr = screen {
            let floorY = scr.minY
            if pos.y > floorY { pos.y = max(floorY, pos.y + (floorY - pos.y) * min(1, f * 5) - 30 * f) }  // glide down

            if pause > 0 {
                pause -= dt
                vx = approach(vx, 0, Tune.walkDecel * 2 * f)
            } else {
                if targetX == nil {
                    targetX = pickTarget(minX: scr.minX, maxX: scr.maxX, width: windowWidth, dockMid: dockMid)
                }
                let dist = targetX! - pos.x
                let want: CGFloat = dist >= 0 ? 1 : -1
                if want != dir && abs(vx) < 3 { dir = want }            // only turn when (almost) stopped
                let turned = max(0, facing * dir)                         // 0 mid-turn → 1 when facing the right way
                let brake = sqrt(2 * Tune.walkDecel * abs(dist))          // ease out: slow down as he arrives
                let desired = dir == want ? dir * min(Tune.walkSpeed, brake) * turned : 0
                let rate = abs(desired) > abs(vx) ? Tune.walkAccel : Tune.walkDecel   // ease in / ease out
                vx = approach(vx, desired, rate * f)
                if abs(dist) < 1.5 && abs(vx) < 4 {                      // arrived: rest, look around
                    vx = 0; targetX = nil
                    pause = Double.random(in: Tune.pauseMin...Tune.pauseMax)
                    lookAroundLeft = min(pause, 1.6)
                    if Double.random(in: 0..<1) < 0.2 { hop(Tune.hopHeight * 0.6) }
                }
            }
            pos.x = min(max(pos.x + vx * f, scr.minX), scr.maxX - windowWidth)
        } else {
            vx = 0
        }

        // ── 2. turning, walk cycle, squash & stretch ──
        facing += (dir - facing) * min(1, f * Tune.turnSpeed)
        let speedFrac = min(1, abs(vx) / Tune.walkSpeed)
        let before = sin(phase)
        phase += abs(vx) * f / Tune.stepLength * .pi          // feet move with distance, so they never slide
        let s = sin(phase)
        if speedFrac > 0.2 && (before < 0) != (s < 0) {       // a little bump in the track: tiny antenna wobble
            antennaV += Double(s < 0 ? 1 : -1) * 16 * Double(speedFrac)
        }
        trackDist += abs(vx) * f                                // treads + wheels roll with real distance
        bob = abs(s) * Tune.bobHeight * speedFrac
        lean = Double(vx / Tune.walkSpeed) * Tune.leanDegrees

        // hop physics (up, gravity, squash on landing)
        if hopY > 0 || hopV > 0 {
            hopV -= 900 * f
            hopY += hopV * f
            if hopY <= 0 { hopY = 0; hopV = 0; landSquash = -0.12; antennaV -= 90 }
        }
        landSquash += (0 - landSquash) * min(1, f * 9)
        let hopStretch: CGFloat = hopV > 0 ? 0.06 : 0
        squash = -cos(2 * phase) * Tune.squashAmount * speedFrac + landSquash + hopStretch

        // ── 3. springy antenna (follows his movement with a little delay) ──
        let accel = Double((vx - lastVx) / max(f, 0.001)); lastVx = vx
        let localAccel = accel * Double(facing >= 0 ? 1 : -1)
        let force = -Tune.antennaSpringiness * antenna - Tune.antennaDamping * antennaV - localAccel * 0.05
        antennaV += force * dt
        antenna = min(30, max(-30, antenna + antennaV * dt))

        // ── 4. head tilt + idle fidgets ──
        tiltLeft -= dt
        if tiltLeft <= 0 { tiltTarget = 0 }
        tilt += (tiltTarget - tilt) * Double(min(1, f * 6))
        if idle && !walking && !asleep {
            idleIn -= dt
            if idleIn <= 0 {
                idleIn = Double.random(in: Tune.idleActionMin...Tune.idleActionMax)
                switch Int.random(in: 0..<3) {
                case 0: lookAroundLeft = 1.8
                case 1: tiltTarget = Bool.random() ? 9 : -9; tiltLeft = 1.4
                default: hop(Tune.hopHeight * 0.5)
                }
            }
        }

        // ── 5. eyes: where to look ──
        var target = CGPoint.zero
        let md = hypot(mouse.x, mouse.y)
        if thinking {
            target = CGPoint(x: sin(time * 3.2), y: -0.4)
        } else if lookAroundLeft > 0 {
            lookAroundLeft -= dt
            target = CGPoint(x: sin(time * 2.4), y: sin(time * 1.3) * 0.3)
        } else if md < Tune.lookRange && md > 1 && !asleep {
            let k = min(1, md / 140)
            target = CGPoint(x: mouse.x / md * k, y: mouse.y / md * k)
        } else if walking {
            target = CGPoint(x: dir * 0.8, y: 0.1)
        }
        look.x += (target.x - look.x) * min(1, f * 10)
        look.y += (target.y - look.y) * min(1, f * 10)

        // ── 6. blinking (random gaps, sometimes a double blink) ──
        stretchLeft = max(0, stretchLeft - dt)
        if asleep {
            lid = 1
        } else {
            blinkIn -= dt
            if blinkIn <= 0 && blinkT < 0 {
                blinkT = 0
                blinkIn = Double.random(in: Tune.blinkMin...Tune.blinkMax)
                secondBlink = Double.random(in: 0..<1) < Tune.doubleBlinkChance
            }
            if blinkT >= 0 {
                blinkT += dt
                let d = 0.16
                lid = CGFloat(max(0, 1 - abs(blinkT / d * 2 - 1)))
                if blinkT >= d {
                    blinkT = -1; lid = 0
                    if secondBlink { secondBlink = false; blinkIn = 0.09 }
                }
            } else { lid = 0 }
            lid = max(lid, stretchAmount * 0.65)                  // sleepy eyes while stretching
        }

        // ── 7. happy + blush ──
        happyLeft = max(0, happyLeft - dt)
        let blushTarget: CGFloat = happyLeft > 0 || stretchLeft > 0 ? 1 : 0
        blush += (blushTarget - blush) * min(1, f * 6)

        // ── 8. helper buddy floats beside him, lagging a little behind ──
        let side: CGFloat = facing >= 0 ? -1 : 1
        let bTarget = CGPoint(x: side * 104, y: -212 + CGFloat(sin(time * 2.1)) * 6 - (bob + hopY) * 0.3)
        buddy.x -= windowDX / Tune.scale                          // the window moved, buddy lags behind
        buddyV.x += ((bTarget.x - buddy.x) * 26 - buddyV.x * 7) * f
        buddyV.y += ((bTarget.y - buddy.y) * 26 - buddyV.y * 7) * f
        buddy.x = min(112, max(-112, buddy.x + buddyV.x * f))
        buddy.y = min(-150, max(-262, buddy.y + buddyV.y * f))

        if redraw { tick &+= 1 }          // only repaint when asked (saves CPU)
    }
}

// MARK: - Drawing Byte

struct RobotView: View {
    @ObservedObject var m: Motion
    @ObservedObject var bot: Bot
    @ObservedObject var voice: Voice

    static let canvas = CGSize(width: 240, height: 280)   // Byte's own drawing area (before scaling)

    var body: some View {
        let _ = m.tick
        let t = m.time
        let tint: Color = bot.mood == .error ? .alert : .lime
        let st = m.stretchAmount
        let breathe: CGFloat = bot.asleep ? CGFloat(sin(t * 1.3)) * 1.5 - 2 : CGFloat(sin(t * 2.0)) * 1.2

        ZStack(alignment: .bottom) {
            if m.showBuddy && !bot.asleep {
                Buddy(t: t, tint: tint).offset(x: m.buddy.x, y: m.buddy.y)
            }
            Ellipse().fill(Color.black.opacity(bot.asleep ? 0.15 : 0.28))
                .frame(width: 84 - m.hopY * 1.2, height: 9)
                .blur(radius: 2)
                .offset(y: 2)
            figure(t: t, tint: tint, stretch: st)
                .scaleEffect(x: (1 - m.squash * 0.8) * m.facing,
                             y: 1 + m.squash + st * 0.09, anchor: .bottom)    // squash/stretch + turning flip
                .rotationEffect(.degrees(m.lean), anchor: .bottom)             // lean into the walk
                .offset(y: -(m.bob + m.hopY + breathe))
            if bot.asleep { Snores(t: t).offset(x: 48, y: -215) }
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .bottom)
        .drawingGroup()          // draw on the GPU in one go: keeps CPU low
    }

    // The whole robot, drawn facing right
    private func figure(t: Double, tint: Color, stretch: CGFloat) -> some View {
        let glow = bot.mood == .speaking ? 0.8 + 0.2 * sin(t * 14) : 0.55 + 0.15 * sin(t * 2.5)
        let hs = Tune.headSize
        return VStack(spacing: -2) {
            // head, round ears and antenna tilt together
            ZStack(alignment: .top) {
                HStack(spacing: 100 * hs) { roundEar(hs); roundEar(hs) }     // panda-style ears
                    .offset(y: 16 * hs)
                VStack(spacing: 0) {
                    VStack(spacing: 0) {                                       // little springy antenna
                        Circle().fill(tint.opacity(glow)).frame(width: 11, height: 11)
                            .shadow(color: tint.opacity(glow), radius: bot.mood == .speaking ? 9 : 4)
                        Rectangle().fill(Color.ink).frame(width: 3, height: 13)
                    }
                    .rotationEffect(.degrees(m.antenna), anchor: .bottom)
                    head(t: t, tint: tint, hs: hs)
                }
            }
            .rotationEffect(.degrees(m.tilt), anchor: .bottom)
            .zIndex(2)

            // collar with a little glowing gem
            ZStack {
                Capsule().fill(Color.shellWhite)
                    .overlay(Capsule().stroke(Color.shellLine, lineWidth: 1.5))
                    .frame(width: 66, height: 13)
                RoundedRectangle(cornerRadius: 2).fill(tint)
                    .frame(width: 9, height: 9).rotationEffect(.degrees(45))
                    .shadow(color: tint.opacity(0.7), radius: 3)
                    .offset(y: 8)
            }
            .zIndex(1)

            torso(t: t, tint: tint, stretch: stretch)

            // crawler tracks instead of legs
            Rectangle().fill(Color.ink).frame(width: 34, height: 5)             // axle
            tracks(tint: tint)
        }
    }

    private func roundEar(_ hs: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.ink).overlay(Circle().stroke(Color.shellLine.opacity(0.5), lineWidth: 1))
                .frame(width: 46 * hs, height: 46 * hs)
            Circle().fill(Color.shellWhite).frame(width: 20 * hs, height: 20 * hs)
        }
    }

    private func head(t: Double, tint: Color, hs: CGFloat) -> some View {
        ZStack {
            // white side pads, like little headphones
            HStack {
                sidePad(hs); Spacer(); sidePad(hs)
            }.padding(.horizontal, -10 * hs)
            RoundedRectangle(cornerRadius: 54 * hs, style: .continuous)
                .fill(LinearGradient(colors: [Color.ink2, Color.ink], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 54 * hs, style: .continuous)
                    .stroke(Color.shellLine.opacity(0.55), lineWidth: 1.5))
            // glossy shine across the top of his head
            Capsule().fill(Color.white.opacity(0.10))
                .frame(width: 64 * hs, height: 12 * hs)
                .rotationEffect(.degrees(-8))
                .offset(x: -30 * hs, y: -46 * hs)
            face(t: t, tint: tint)
        }
        .frame(width: 168 * hs, height: 134 * hs)
    }

    private func sidePad(_ hs: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8 * hs, style: .continuous)
            .fill(LinearGradient(colors: [Color.shellWhite, Color.shellShade], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 8 * hs, style: .continuous).stroke(Color.shellLine, lineWidth: 1.2))
            .frame(width: 20 * hs, height: 50 * hs)
    }

    private func torso(t: Double, tint: Color, stretch: CGFloat) -> some View {
        let core = bot.mood == .thinking ? 0.4 + 0.6 * abs(sin(t * 5)) : 0.6 + 0.25 * sin(t * 1.8)
        return ZStack {
            // white chest with a black belly band
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color.shellWhite, Color.shellShade], startPoint: .top, endPoint: .bottom))
                .overlay(
                    VStack(spacing: 0) { Spacer(); Rectangle().fill(Color.ink).frame(height: 14) }
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                )
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.shellLine, lineWidth: 1.5))
            // glowing power core
            Circle().fill(tint.opacity(core))
                .frame(width: 11, height: 11)
                .shadow(color: tint.opacity(core), radius: 5)
                .overlay(Circle().stroke(Color.ink, lineWidth: 2))
                .offset(y: -5)
            HStack {
                arm(angle: leftArm(t: t, stretch: stretch))
                Spacer()
                arm(angle: rightArm(t: t, stretch: stretch)).scaleEffect(x: -1)   // mirror of the left arm
            }.padding(.horizontal, -22)
        }
        .frame(width: 80, height: 46)
    }

    private func leftArm(t: Double, stretch: CGFloat) -> Double {
        if stretch > 0 { return -20 - Double(stretch) * 70 }                   // big wake-up stretch
        if bot.waving { return sin(t * 9) * 35 - 20 }
        if m.happyLeft > 0 { return -40 + sin(t * 18) * 12 }
        return sin(t * 2) * 4 - m.lean * 2 - 18
    }
    // right arm uses the same angles as the left one; it's mirrored when drawn
    private func rightArm(t: Double, stretch: CGFloat) -> Double {
        if stretch > 0 { return -20 - Double(stretch) * 70 }
        if m.happyLeft > 0 { return -40 - sin(t * 18) * 12 }
        if bot.mood == .speaking { return -18 + sin(t * 6) * 12 }
        return sin(t * 2 + 1) * 4 + m.lean * 2 - 18
    }

    // white arm with a round black hand
    private func arm(angle: Double) -> some View {
        HStack(spacing: -3) {
            Circle().fill(Color.ink).frame(width: 12, height: 12)
            Capsule().fill(Color.shellWhite)
                .overlay(Capsule().stroke(Color.shellLine, lineWidth: 1.2))
                .frame(width: 24, height: 10)
        }
        .rotationEffect(.degrees(angle), anchor: .trailing)                // pivots at the shoulder
    }

    // Tank-style crawler: rubber track with moving tread teeth, spinning wheels, white fender on top
    private func tracks(tint: Color) -> some View {
        let w: CGFloat = 108, h: CGFloat = 28
        let gap = Tune.treadSpacing
        let rolled = m.trackDist / Tune.scale                        // distance in Byte's own units
        let shift = rolled.truncatingRemainder(dividingBy: gap)      // how far the teeth have slid
        let spin = Double(rolled / 9) * 180 / .pi                    // wheel angle (radius 9)
        return ZStack {
            // black rubber track with tread teeth running along the top and bottom
            Capsule().fill(Color.ink)
                .overlay(
                    Canvas { ctx, size in
                        let tooth = Color(red: 0.32, green: 0.34, blue: 0.34)
                        var x = -gap + shift                              // top run rolls forward
                        while x < size.width + gap {
                            ctx.fill(Path(roundedRect: CGRect(x: x, y: 1, width: 4, height: 3), cornerRadius: 1), with: .color(tooth))
                            x += gap
                        }
                        x = -gap + (gap - shift)                          // bottom run rolls backward
                        while x < size.width + gap {
                            ctx.fill(Path(roundedRect: CGRect(x: x, y: size.height - 4, width: 4, height: 3), cornerRadius: 1), with: .color(tooth))
                            x += gap
                        }
                    }
                    .clipShape(Capsule())
                )
                .overlay(Capsule().stroke(Color.shellLine.opacity(0.6), lineWidth: 1))
                .frame(width: w, height: h)
            // wheels inside the track
            HStack(spacing: 6) {
                ForEach(0..<4) { i in
                    wheel(size: i == 0 || i == 3 ? 18 : 15, spin: spin)
                }
            }
            // white fender over the top, with a lime stripe
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [Color.shellWhite, Color.shellShade], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.shellLine, lineWidth: 1.2))
                Capsule().fill(tint).frame(width: 26, height: 3)
            }
            .frame(width: w - 14, height: 9)
            .offset(y: -h / 2 - 2)
        }
        .frame(width: w, height: h + 6, alignment: .bottom)
    }

    private func wheel(size: CGFloat, spin: Double) -> some View {
        ZStack {
            Circle().fill(Color.shellShade).overlay(Circle().stroke(Color.shellLine, lineWidth: 1))
            ForEach(0..<3) { k in                                     // spokes, so you can see it turn
                Rectangle().fill(Color.ink.opacity(0.7))
                    .frame(width: size * 0.7, height: 1.6)
                    .rotationEffect(.degrees(spin + Double(k) * 60))
            }
            Circle().fill(Color.ink).frame(width: size * 0.3, height: size * 0.3)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func face(t: Double, tint: Color) -> some View {
        let es = Tune.eyeSize, hs = Tune.headSize
        let eyeW = 34 * es, eyeH = 40 * es
        // eyes are mirrored when he faces left, so flip the look direction back
        let lookX = m.look.x * Tune.eyeLookDistance * (m.facing >= 0 ? 1 : -1)
        let lookY = m.look.y * Tune.eyeLookDistance * 0.6
        ZStack {
            VStack(spacing: 6 * hs) {
                HStack(spacing: 26 * hs) {
                    ForEach(0..<2) { _ in
                        if bot.mood == .error {
                            Text("×").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundColor(tint)
                                .frame(width: eyeW, height: eyeH)
                        } else if m.happyLeft > 0 {
                            HappyEye().stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                                .frame(width: eyeW * 0.8, height: eyeH * 0.36)
                                .shadow(color: tint.opacity(0.8), radius: 4)
                                .frame(width: eyeW, height: eyeH)
                        } else {
                            eye(w: eyeW, h: eyeH, tint: tint, lookX: lookX, lookY: lookY)
                        }
                    }
                }
                .frame(height: eyeH)
                mouth(t: t, tint: tint)
            }
            .offset(y: 6 * hs)
            // cheeks: soft glow when he's happy
            HStack(spacing: 96 * hs) {
                ForEach(0..<2) { _ in
                    Ellipse().fill(Tune.blushColor)
                        .frame(width: 22, height: 11)
                        .blur(radius: 4)
                }
            }
            .offset(y: 26 * hs)
            .opacity(Double(m.blush) * 0.85)
        }
    }

    // A big shiny lime eye: dark pupil that follows your mouse, plus sparkle highlights
    private func eye(w: CGFloat, h: CGFloat, tint: Color, lookX: CGFloat, lookY: CGFloat) -> some View {
        let open = max(0.07, 1 - m.lid)
        return ZStack {
            Ellipse().fill(tint)
                .frame(width: w, height: max(3, h * open))
                .shadow(color: tint.opacity(0.55), radius: 5)
            if open > 0.45 {
                Ellipse().fill(Color.limeDeep)                                        // pupil
                    .frame(width: w * 0.48, height: h * 0.56 * open)
                    .offset(x: lookX * 0.9, y: lookY * 0.9 + h * 0.06)
                Circle().fill(Color.white).frame(width: w * 0.26, height: w * 0.26)  // big sparkle
                    .offset(x: -w * 0.16 + lookX * 0.5, y: -h * 0.18 * open)
                Circle().fill(Color.white.opacity(0.75)).frame(width: w * 0.12, height: w * 0.12)
                    .offset(x: w * 0.14 + lookX * 0.5, y: h * 0.12 * open)
            }
        }
        .offset(x: lookX * 0.5, y: lookY * 0.5)
        .frame(width: w, height: h)
    }

    @ViewBuilder
    private func mouth(t: Double, tint: Color) -> some View {
        Group {
            if bot.mood == .thinking {
                HStack(spacing: 4) {
                    ForEach(0..<3) { i in
                        Circle().fill(tint).frame(width: 5, height: 5)
                            .opacity(0.3 + 0.7 * max(0, sin(t * 6 - Double(i) * 0.8)))
                    }
                }
            } else if bot.mood == .speaking {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Color.shellShade).frame(width: 26, height: 8 + voice.mouth * 10)
                    RoundedRectangle(cornerRadius: 3).fill(tint).frame(width: 16, height: 2 + voice.mouth * 7)
                }
            } else if bot.asleep {
                Circle().stroke(Color.shellShade, lineWidth: 2.5).frame(width: 7, height: 7)
            } else if m.happyLeft > 0 {
                Smile().stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 28, height: 10)
            } else {
                // small grey mouth plate with a little smile
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.shellShade).frame(width: 24, height: 9)
                    Smile().stroke(Color.ink, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .frame(width: 12, height: 2.5).offset(y: -1)
                }
            }
        }
        .frame(height: 16)
    }
}

/// The tiny propeller cube friend: a white cube with a face slot and leafy blades
struct Buddy: View {
    let t: Double
    let tint: Color
    var body: some View {
        VStack(spacing: 0) {
            // two leaf blades spinning (squash as they turn)
            HStack(spacing: 0) {
                Ellipse().fill(tint).frame(width: 13, height: 5)
                Ellipse().fill(tint.opacity(0.85)).frame(width: 13, height: 5)
            }
            .scaleEffect(x: 0.15 + 0.85 * abs(CGFloat(cos(t * 24))), y: 1)
            Rectangle().fill(Color.ink).frame(width: 2.5, height: 5)
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [Color.shellWhite, Color.shellShade], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.shellLine, lineWidth: 1.2))
                Path { p in p.move(to: CGPoint(x: 5, y: 5)); p.addLine(to: CGPoint(x: 11, y: 5)) }   // panel seam
                    .stroke(Color.shellLine, lineWidth: 1)
                RoundedRectangle(cornerRadius: 3).fill(Color.ink)                // face slot
                    .frame(width: 16, height: 8)
                    .overlay(HStack(spacing: 5) {
                        ForEach(0..<2) { _ in
                            Capsule().fill(tint).frame(width: 3, height: fmod(t + 1.3, 3.7) < 0.12 ? 1 : 4.5)
                        }
                    })
                    .offset(y: 3)
            }
            .frame(width: 26, height: 24)
        }
        .rotationEffect(.degrees(sin(t * 1.7) * 7))
        .allowsHitTesting(false)
    }
}

/// Little "z z Z" drifting up while Byte sleeps
struct Snores: View {
    let t: Double
    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                let phase = fmod(t * 0.5 + Double(i) / 3, 1)
                Text("z")
                    .font(.system(size: 16 + CGFloat(phase) * 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.neon)
                    .opacity(sin(phase * .pi))
                    .offset(x: CGFloat(phase) * 30 + CGFloat(sin(phase * 6)) * 4, y: -CGFloat(phase) * 60)
            }
        }
        .allowsHitTesting(false)
    }
}

struct Smile: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 1.8))
        return p
    }
}

/// Happy closed eye: ^
struct HappyEye: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.9))
        return p
    }
}

struct Scanlines: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.55)))
                y += 3
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - The whole widget: speech bubble on top, Byte standing below

struct RobotFrameKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let n = nextValue(); if n != .zero { value = n } }
}
struct ChatFrameKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let n = nextValue(); if n != .zero { value = n } }
}

struct ByteView: View {
    @ObservedObject var bot: Bot
    let m: Motion            // not observed here on purpose: only Byte himself redraws each frame
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 4) {
            if bot.chatVisible {
                chat.background(GeometryReader { g in
                    Color.clear.preference(key: ChatFrameKey.self, value: g.frame(in: .global))
                })
            }
            RobotView(m: m, bot: bot, voice: bot.voice)
                .scaleEffect(Tune.scale)
                .frame(width: RobotView.canvas.width * Tune.scale, height: RobotView.canvas.height * Tune.scale)
                .background(GeometryReader { g in
                    Color.clear.preference(key: RobotFrameKey.self, value: g.frame(in: .global))
                })
                .contentShape(Rectangle())
                .onTapGesture { bot.poke(); m.happy() }          // pet him!
                .contextMenu { menuItems }
        }
        .padding(.horizontal, bot.chatVisible ? 10 : 0)
        .padding(.top, bot.chatVisible ? 10 : 0)
        .frame(width: bot.chatVisible ? 250 : nil)
        .onPreferenceChange(RobotFrameKey.self) { m.robotRect = $0 }
        .onPreferenceChange(ChatFrameKey.self) { m.chatRect = $0 }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true } }
        .onChange(of: bot.chatVisible) { _, visible in
            if visible { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true } }
        }
    }

    @ViewBuilder private var chat: some View {
        VStack(spacing: 8) {
            // speech bubble
            ScrollView {
                Text(bot.bubble)
                    .font(mono)
                    .foregroundColor(bot.mood == .error ? .alert : .neon)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(maxHeight: 110)
            .fixedSize(horizontal: false, vertical: true)
            .background(panel)

            // input line
            if bot.needsKey {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("key›").font(mono).foregroundColor(.neonMid)
                        SecureField("paste Gemini API key", text: $bot.keyDraft)
                            .textFieldStyle(.plain).font(mono).foregroundColor(.neon)
                            .focused($focused)
                            .onSubmit { bot.saveKey() }
                    }
                    HStack(spacing: 8) {
                        Button("paste") { bot.pasteKey() }
                            .buttonStyle(.plain).font(mono).foregroundColor(.neon)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().stroke(Color.neon, lineWidth: 1))
                            .help("Paste the key from your clipboard")
                        Button("save") { bot.saveKey() }
                            .buttonStyle(.plain).font(mono).foregroundColor(.black)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Color.neon))
                        if !bot.keyDraft.isEmpty {
                            Text("\(bot.keyDraft.count) chars").font(.system(size: 11, design: .monospaced)).foregroundColor(.neonMid)
                        }
                    }
                    Link("get a free key → aistudio.google.com/apikey", destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.neonMid)
                }
                .padding(12).background(panel)
            } else {
                HStack(spacing: 8) {
                    Text("›").font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundColor(.neon)
                    TextField(bot.mood == .thinking ? "thinking…" : "say something…", text: $bot.input)
                        .textFieldStyle(.plain).font(mono).foregroundColor(.neon)
                        .focused($focused)
                        .disabled(bot.mood == .thinking)
                        .onSubmit { bot.send(); focused = true }
                    if bot.voice.speaking {
                        Button { bot.voice.stop() } label: {
                            Image(systemName: "stop.fill").foregroundColor(.neon)
                        }.buttonStyle(.plain).help("Stop talking")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(panel)
            }
        }
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.black.opacity(0.88))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.neon.opacity(0.45), lineWidth: 1))
            .shadow(color: Color.neon.opacity(0.18), radius: 10)
    }

    @ViewBuilder private var menuItems: some View {
        Button(bot.voice.muted ? "Unmute voice" : "Mute voice") { bot.voice.muted.toggle() }
        Menu("Voice") {
            ForEach(Voice.englishVoices, id: \.identifier) { v in
                Button((v.identifier == bot.voice.currentVoiceID ? "✓ " : "    ") + Voice.label(v)) {
                    bot.voice.choose(v.identifier)
                }
            }
        }
        Button(m.showBuddy ? "Hide helper buddy" : "Show helper buddy") { m.showBuddy.toggle() }
        Button("Clear chat") { bot.clearChat() }
        Button("Change API key") { bot.changeKey() }
        Divider()
        Button("Hide Byte") { NSApp.hide(nil) }
        Button("Quit Byte") { NSApp.terminate(nil) }
    }
}

// MARK: - A floating, see-through window that can take typing

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Menu-bar-only apps have no Edit menu, so ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z need wiring by hand.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command || mods == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() {
            let action: Selector? = {
                switch (key, mods.contains(.shift)) {
                case ("v", false): return #selector(NSText.paste(_:))
                case ("c", false): return #selector(NSText.copy(_:))
                case ("x", false): return #selector(NSText.cut(_:))
                case ("a", false): return #selector(NSText.selectAll(_:))
                case ("z", false): return Selector(("undo:"))
                case ("z", true):  return Selector(("redo:"))
                default: return nil
                }
            }()
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panel: FloatingPanel!
    var status: NSStatusItem!
    let bot = Bot()
    let motion = Motion()
    var host: NSHostingView<ByteView>!

    func applicationDidFinishLaunching(_ n: Notification) {
        host = NSHostingView(rootView: ByteView(bot: bot, m: motion))
        host.sizingOptions = [.intrinsicContentSize]   // report its size; we resize the window ourselves
        host.frame.size = host.fittingSize
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrameAutosaveName("ByteWindow")
        if !panel.setFrameUsingName("ByteWindow"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 280, y: screen.minY))
        }
        refit()
        panel.makeKeyAndOrderFront(nil)

        bot.onWake = { [weak self] fromSleep in self?.wake(fromSleep: fromSleep) }
        startLoop()
        buildStatusMenu()
    }

    // MARK: Animation loop (60 fps while lively, slower when calm, very slow asleep)

    private var loop: Timer?
    private var last = CACurrentMediaTime()
    private var pending: Double = 0
    private var checkAccum: Double = 0
    private var lastOrigin = CGPoint.zero
    private var drawToggle = false

    private func startLoop() {
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.frame() }
        RunLoop.main.add(t, forMode: .common)          // keeps running while menus are open or he's dragged
        loop = t
    }

    private func frame() {
        let now = CACurrentMediaTime()
        pending += min(0.1, now - last); last = now

        // pick a frame rate: smooth when moving, lighter when still, sleepy when asleep (saves CPU)
        let fps: Double = bot.asleep ? 5 : (motion.lively || bot.mood == .speaking || bot.mood == .thinking) ? 60 : 24
        guard pending >= 1 / fps - 0.002 else { return }
        let dt = min(pending, 1.0 / 15); pending = 0

        let p = NSEvent.mouseLocation
        let wf = panel.frame

        // 1. clicks only land on Byte's body (and the chat box); everywhere else passes through
        let local = panel.convertPoint(fromScreen: p)
        let flipped = CGPoint(x: local.x, y: wf.height - local.y)
        let overBody = motion.bodyHitRect.contains(flipped)
        let overChat = bot.chatVisible && motion.chatRect.contains(flipped)
        let passThrough = !(overBody || overChat)
        if panel.ignoresMouseEvents != passThrough { panel.ignoresMouseEvents = passThrough }

        // 2. tell his eyes where the mouse is (relative to his head, y pointing down)
        let hc = motion.headCenter
        motion.mouse = CGPoint(x: p.x - (wf.minX + hc.x), y: (wf.maxY - hc.y) - p.y)

        // 3. ten times a second: walk / sleep / wake decisions
        checkAccum += dt
        if checkAccum >= 0.1 { checkAccum = 0; checkIdle(overBody: overBody, mouse: p) }

        // 4. move everything
        if !motion.walking { motion.pos = wf.origin }        // user may have dragged him
        let scr = (panel.screen ?? NSScreen.main)
        let dx = wf.origin.x - lastOrigin.x
        motion.update(dt: dt, asleep: bot.asleep, thinking: bot.mood == .thinking,
                      speaking: bot.mood == .speaking, idle: bot.mood == .idle && bot.chatVisible,
                      screen: scr?.visibleFrame, dockMid: scr?.frame.midX ?? 0,
                      windowWidth: wf.width, windowDX: dx,
                      redraw: !motion.walking || drawToggle)   // walking: glide at 60 fps, repaint body at 30
        drawToggle.toggle()
        lastOrigin = wf.origin
        if motion.walking && motion.pos != wf.origin { panel.setFrameOrigin(motion.pos) }
    }

    private func checkIdle(overBody: Bool, mouse p: CGPoint) {
        guard panel.isVisible else { return }
        // hovering counts only if Byte is the window actually under the pointer (not hidden behind another one)
        let hovering = overBody && NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0) == panel.windowNumber
        if hovering || bot.busy { bot.poke(); return }
        let idle = Date().timeIntervalSince(bot.lastActivity)
        if !bot.asleep && idle > Tune.sleepAfterSeconds {
            motion.stopWalking()
            bot.walking = false
            bot.asleep = true
            fade(awake: false)
        } else if !bot.asleep && !bot.walking && idle > Tune.walkAfterSeconds {
            bot.walking = true
            refit { [weak self] in
                guard let self else { return }
                self.motion.startWalking(from: self.panel.frame.origin)
            }
        }
    }

    private func wake(fromSleep: Bool) {
        motion.stopWalking()
        fade(awake: true)
        if fromSleep {
            motion.wakeUp()
            bot.sleepyLine()
        }
    }

    private func fade(awake: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = awake ? 0.25 : 1.2
            panel.animator().alphaValue = awake ? 1.0 : 0.35
        }
        panel.level = awake ? .floating : .normal
        if awake { panel.orderFrontRegardless() } else { panel.orderBack(nil) }
        refit()
    }

    /// Resize the window to fit what's showing (just Byte, or Byte + chat). Byte's feet stay put.
    private func refit(then done: (() -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            var f = panel.frame
            let cx = f.midX
            f.size = size
            f.origin.x = cx - size.width / 2                  // keep him centred where he stands
            if let s = (panel.screen ?? NSScreen.main)?.visibleFrame {
                f.origin.x = min(max(f.origin.x, s.minX), s.maxX - size.width)
                f.origin.y = min(max(f.origin.y, s.minY), s.maxY - size.height)
            }
            panel.setFrame(f, display: true)
            lastOrigin = f.origin
            motion.pos = f.origin
            done?()
        }
    }

    // MARK: Menu bar icon

    let voiceMenu = NSMenu()
    var buddyItem: NSMenuItem!

    private func buildStatusMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Byte")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Show / Hide Byte", action: #selector(toggle), keyEquivalent: "b").target = self
        menu.addItem(withTitle: "Mute / Unmute", action: #selector(mute), keyEquivalent: "m").target = self
        let voiceItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        voiceMenu.delegate = self
        voiceItem.submenu = voiceMenu
        menu.addItem(voiceItem)
        buddyItem = NSMenuItem(title: "Helper buddy", action: #selector(toggleBuddy), keyEquivalent: "")
        buddyItem.target = self
        menu.addItem(buddyItem)
        menu.addItem(withTitle: "Clear chat", action: #selector(clear), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Change API key", action: #selector(changeKey), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Byte", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        buddyItem?.state = motion.showBuddy ? .on : .off
        guard menu === voiceMenu else { return }
        menu.removeAllItems()
        var addedFunHeader = false
        for v in Voice.englishVoices {
            if v.voiceTraits.contains(.isNoveltyVoice) && !addedFunHeader {
                menu.addItem(.separator())
                let h = NSMenuItem(title: "Fun & robot voices", action: nil, keyEquivalent: ""); h.isEnabled = false
                menu.addItem(h)
                addedFunHeader = true
            }
            let item = NSMenuItem(title: Voice.label(v), action: #selector(pickVoice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = v.identifier
            item.state = v.identifier == bot.voice.currentVoiceID ? .on : .off
            menu.addItem(item)
        }
    }

    @objc func pickVoice(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { bot.voice.choose(id) }
    }
    @objc func toggle() {
        if panel.isVisible && !bot.asleep { panel.orderOut(nil) }
        else { NSApp.unhide(nil); bot.poke(); fade(awake: true); panel.makeKeyAndOrderFront(nil) }
    }
    @objc func mute() { bot.voice.muted.toggle() }
    @objc func toggleBuddy() { motion.showBuddy.toggle() }
    @objc func clear() { bot.clearChat() }
    @objc func changeKey() { bot.poke(); bot.changeKey(); panel.makeKeyAndOrderFront(nil) }
}

@main
enum ByteApp {
    static let delegate = AppDelegate()
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon, lives in the menu bar
        app.run()
    }
}

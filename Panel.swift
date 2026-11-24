// Floating always-on-top panel listing Claude Code sessions, plus a menu-bar icon for settings.
// Reads ~/.claude-panel/{sessions,requests} written by hook.py. Build: ./build.sh
import AppKit
import SwiftUI

let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-panel")
let appPath = "\(NSHomeDirectory())/Applications/Claude Panel.app"

struct Session: Decodable, Identifiable {
    let id: String
    var cwd: String?
    var account: String?
    var status: String?
    var detail: String?
    var title: String?
    var updated: Double
    var turnStart: Double?
    var agents: Int?
    var tty: String?          // terminal tab ("ttys003"); "??" for the desktop app
    var desktopId: String?    // the desktop app's local_ id
    var dtitle: String?       // the desktop app's title for the session
    var profile: String?      // "Claude" or "Claude-Work"
    var result: String?       // first line of the final message
    var turnSecs: Double?
    var finishedAt: Double?
    var cfg: String?          // CLAUDE_CONFIG_DIR of a terminal session

    var folder: String { URL(fileURLWithPath: cwd ?? "?").lastPathComponent }
    var name: String { (dtitle?.isEmpty == false) ? dtitle! : folder }
}

struct Toast: Equatable {
    let name: String
    let secs: Double
    let result: String
}

struct Usage { var replies = 0; var tokens = 0 }

struct Question: Decodable, Hashable {
    let question: String
    let options: [String]
    let multiSelect: Bool
}

struct Request: Decodable, Identifiable {
    let rid: String
    let session: String
    var kind: String?           // "permission" | "question" | "reply"
    var detail: String?         // permission
    var question: String?       // reply
    var questions: [Question]?  // question card
    var options: [String]?      // reply: answer buttons offered with the question
    var id: String { rid }
}

// Borderless panels refuse keyboard focus by default; the reply box needs it.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// Settings live in UserDefaults; "approve" is mirrored to a flag file the hook reads.
final class Settings: ObservableObject {
    let d = UserDefaults.standard
    @Published var sound: Bool { didSet { d.set(sound, forKey: "sound") } }          // needs you
    @Published var soundDone: Bool { didSet { d.set(soundDone, forKey: "soundDone") } }  // finished
    @Published var hideDone: Bool { didSet { d.set(hideDone, forKey: "hideDone") } }
    @Published var approve: Bool { didSet { d.set(approve, forKey: "approve"); flag("no-approve", !approve) } }
    @Published var reply: Bool { didSet { d.set(reply, forKey: "reply"); flag("no-reply", !reply) } }
    @Published var autoHide: Bool { didSet { d.set(autoHide, forKey: "autoHide") } }
    init() {
        d.register(defaults: ["sound": true, "hideDone": false, "approve": true, "reply": true, "autoHide": true, "soundDone": true])
        sound = d.bool(forKey: "sound")
        soundDone = d.bool(forKey: "soundDone")
        hideDone = d.bool(forKey: "hideDone")
        approve = d.bool(forKey: "approve")
        reply = d.bool(forKey: "reply")
        autoHide = d.bool(forKey: "autoHide")
        flag("no-approve", !approve)
        flag("no-reply", !reply)
    }
    func flag(_ name: String, _ on: Bool) {
        let url = base.appendingPathComponent(name)
        if on { FileManager.default.createFile(atPath: url.path, contents: nil) }
        else { try? FileManager.default.removeItem(at: url) }
    }
}

final class Store: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var requests: [String: Request] = [:]  // by session id, oldest first wins
    @Published var now = Date().timeIntervalSince1970
    @Published var toast: Toast?
    @Published var usage: [String: Usage] = [:]
    let settings: Settings
    private let scanner = UsageScanner()
    var onChange: (() -> Void)?
    private var lastStatus: [String: String]? = nil
    private var records: [String: (id: String, profile: String, title: String)?] = [:]  // nil = looked, none

    init(settings: Settings) {
        self.settings = settings
        load()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.load() }
        scanUsage()
        Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.scanUsage() }
    }

    func scanUsage() {
        let accts = Accounts.shared.list.map { ($0.dir, $0.cli) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let u = self.scanner.scan(accts)
            DispatchQueue.main.async { self.usage = u }
        }
    }

    func files<T: Decodable>(_ sub: String, _ type: T.Type) -> [T] {
        let dir = base.appendingPathComponent(sub)
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap {
            (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
    }

    func load() {
        now = Date().timeIntervalSince1970
        // heartbeat: hooks only hold Claude for an answer while the panel is running
        let alive = base.appendingPathComponent("alive")
        if !FileManager.default.createFile(atPath: alive.path, contents: nil) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        var reqs: [String: Request] = [:]
        for r in files("requests", Request.self) where reqs[r.session] == nil { reqs[r.session] = r }

        var out = files("sessions", Session.self).filter { s in
            let age = now - s.updated
            // ponytail: stale cutoff by age; check the Claude process is alive if ghosts become a problem
            if age > 3 * 3600 { return false }
            // no hook activity for 30 min and nothing pending = crashed or closed session
            if age > 1800 && reqs[s.id] == nil && s.status != "waiting" { return false }
            if s.status == "done" && (settings.hideDone || age > 1800) { return false }
            return true
        }
        // sessions the hook saw before it learned the desktop lookup: fill in title and target once
        for i in out.indices where out[i].desktopId == nil && ((out[i].tty ?? "").isEmpty || out[i].tty == "??") {
            if records[out[i].id] == nil { records[out[i].id] = .some(desktopRecord(out[i].id)) }
            if let rec = records[out[i].id] ?? nil {
                out[i].desktopId = rec.id
                out[i].profile = rec.profile
                if (out[i].dtitle ?? "").isEmpty { out[i].dtitle = rec.title }
            }
        }
        let rank = ["waiting": 0, "working": 1, "idle": 2, "done": 3]
        func r(_ s: Session) -> Int { reqs[s.id] != nil ? -1 : rank[s.status ?? ""] ?? 9 }
        out.sort { (r($0), -$0.updated) < (r($1), -$1.updated) }

        if let last = lastStatus {
            if settings.sound, out.contains(where: { $0.status == "waiting" && last[$0.id] != "waiting" }) {
                NSSound(named: "Glass")?.play()
            }
            // a session just finished: a short card from the tab, and a softer sound
            if let f = out.first(where: { $0.status == "done" && last[$0.id] == "working" }) {
                if settings.soundDone { NSSound(named: "Pop")?.play() }
                let t = Toast(name: f.name, secs: f.turnSecs ?? 0, result: f.result ?? "")
                toast = t
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
                    if self?.toast == t { self?.toast = nil }
                }
            }
        }
        lastStatus = Dictionary(uniqueKeysWithValues: out.map { ($0.id, $0.status ?? "") })
        sessions = out
        requests = reqs
        onChange?()
    }

    func answer(_ r: Request, _ choice: String) {
        let url = base.appendingPathComponent("requests/\(r.rid).answer")
        try? choice.write(to: url, atomically: true, encoding: .utf8)
        requests[r.session] = nil
    }

    // Bring the session's window forward: the desktop app by its session link, a terminal by its tab.
    /// Drop a row (its file reappears if the session becomes active again).
    func remove(_ s: Session) {
        try? FileManager.default.removeItem(at: base.appendingPathComponent("sessions/\(s.id).json"))
        load()
    }

    func jump(_ s: Session) {
        if s.desktopId != nil { openInApp(s) } else { showInTerminal(s) }
    }

    func openInApp(_ s: Session) {
        if let id = s.desktopId, !id.isEmpty {
            if let p = s.profile, p != "Claude", let a = Accounts.shared.account(dir: p) {
                // links always reach the main app, so bring that account's window forward instead
                Accounts.shared.open(a)
            } else if let url = URL(string: "claude://code/continue?session=\(id)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func showInTerminal(_ s: Session) {
        if let tty = s.tty, !tty.isEmpty, tty != "??" {
            DispatchQueue.global().async {
                osa("""
                tell application "Terminal"
                    activate
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "/dev/\(tty)" then
                                set selected of t to true
                                set index of w to 1
                            end if
                        end repeat
                    end repeat
                end tell
                """)
            }
        }
    }

    /// A new Terminal window that resumes this session with the CLI, in its folder and on its account.
    func resumeInTerminal(_ s: Session) {
        guard let a = Accounts.shared.account(for: s) ?? Accounts.shared.account(dir: "Claude") else { return }
        Accounts.shared.terminal(a, cwd: s.cwd, args: "--resume \(s.id)")
    }

    var waitingCount: Int { sessions.filter { $0.status == "waiting" || requests[$0.id] != nil }.count }
}

func clock(_ secs: Double) -> String {
    let s = max(0, Int(secs))
    return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m \(s % 60)s" : "\(s / 3600)h \(s / 60 % 60)m"
}

func ago(_ secs: Double) -> String {
    let s = max(0, Int(secs))
    return s < 60 ? "now" : s < 3600 ? "\(s / 60)m ago" : "\(s / 3600)h ago"
}

// One solid dark ground so contrast never depends on the window behind the panel.
enum Ink {
    static let ground = Color(white: 0.067)            // #111
    static let line = Color(white: 0.18)               // #2e2e2e
    static let text = Color.white
    static let secondary = Color(white: 0.71)          // #b4b4b4
    static let meta = Color(white: 0.58)               // #949494
    static let field = Color(white: 0.13)              // input and neutral button fill
    static let ask = Color(red: 1.0, green: 0.62, blue: 0.25)
    static let green = Color(red: 0.25, green: 0.75, blue: 0.48)
    static let greenTint = Color(red: 0.09, green: 0.17, blue: 0.11)
    static let red = Color(red: 1.0, green: 0.45, blue: 0.42)
    static let redTint = Color(red: 0.19, green: 0.09, blue: 0.09)
    static let workTint = Color(red: 0.12, green: 0.18, blue: 0.30)
    static let amber = Color(red: 0.95, green: 0.78, blue: 0.25)
}

struct Row: View {
    let s: Session
    let req: Request?
    let now: Double
    let answer: (Request, String) -> Void
    var jump: (Session) -> Void = { _ in }
    var store: Store? = nil
    @State private var hover = false

    var waiting: Bool { req != nil || s.status == "waiting" }
    var long: Bool { s.status == "working" && now - (s.turnStart ?? s.updated) > 900 }

    var time: String {
        if waiting { return "waiting " + clock(now - s.updated) }
        if s.status == "working" { return clock(now - (s.turnStart ?? s.updated)) }
        return ago(now - s.updated)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                let l = s.light(req, now: now)
                Light(color: l.0, mode: l.1, animated: false).padding(.horizontal, -3)
                Text(s.name)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text)
                    .lineLimit(1).frame(maxWidth: waiting ? .infinity : 165, alignment: .leading)
                    .fixedSize(horizontal: !waiting && s.name.count < 18, vertical: false)
                if let acct = Accounts.shared.account(for: s), !acct.isMain {
                    Text(acct.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.text)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Ink.workTint).clipShape(RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                }
                if !waiting {  // compact: what it's doing, or what it ended with
                    if s.status == "working" {
                        Text(s.detail ?? "").font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Ink.meta).lineLimit(1)
                    } else {
                        Text((s.result?.isEmpty == false) ? s.result! : "finished")
                            .font(.system(size: 12)).foregroundStyle(Ink.meta).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let n = s.agents, n > 0, !waiting {
                    Text("\(n) agent\(n > 1 ? "s" : "")").font(.system(size: 11)).foregroundStyle(Ink.meta).fixedSize()
                }
                Text(time).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(waiting ? Ink.ask : long ? Ink.amber : Ink.meta).fixedSize()
            }
            .contentShape(Rectangle())
            .onTapGesture { jump(s) }
            .onHover { hover = $0 }
            .pointerStyle(.link)
            .help(s.desktopId != nil ? "Open in the Claude app (right-click for more)"
                  : (s.tty ?? "??") != "??" ? "Show its Terminal tab (right-click for more)" : "")
            .contextMenu {
                if s.desktopId != nil {
                    Button(s.profile == "Claude-Work" ? "Open Claude Work" : "Open in Claude App") { store?.openInApp(s) }
                }
                if let t = s.tty, !t.isEmpty, t != "??" {
                    Button("Show in Terminal") { store?.showInTerminal(s) }
                }
                Button("Resume in Terminal") { store?.resumeInTerminal(s) }
                Divider()
                Button("Remove from Panel") { store?.remove(s) }
                Button("Copy Session ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s.id, forType: .string)
                }
            }
            if waiting {
                VStack(alignment: .leading, spacing: 6) {
                    if let t = s.title, !t.isEmpty {
                        Text(t).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1)
                    }
                    if let req {
                        RequestView(req: req, answer: answer)
                    } else {
                        Text(s.detail ?? "").font(.system(size: 13)).foregroundStyle(Ink.ask)
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, waiting ? 9 : 6)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hover ? 0.06 : 0)))
        .padding(.horizontal, -6)
    }
}

struct RequestView: View {
    let req: Request
    let answer: (Request, String) -> Void
    @State private var text = ""
    @State private var picks: [String: String] = [:]

    var body: some View {
        switch req.kind {
        case "reply": reply
        case "question": questions
        default: permission
        }
    }

    func askText(_ q: String) -> some View {
        Text(q).font(.system(size: 13)).foregroundStyle(Ink.ask)
            .lineLimit(5).fixedSize(horizontal: false, vertical: true)
    }

    var permission: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(req.detail ?? "").font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.ask)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Allow") { answer(req, "allow") }.buttonStyle(Pill(fg: Ink.green, bg: Ink.greenTint))
                Button("Deny") { answer(req, "deny") }.buttonStyle(Pill(fg: Ink.red, bg: Ink.redTint))
            }
        }
    }

    var reply: some View {
        VStack(alignment: .leading, spacing: 7) {
            askText(req.question ?? "")
            if let opts = req.options, !opts.isEmpty {
                Flow(spacing: 6) {
                    ForEach(opts, id: \.self) { o in
                        Button(o) { answer(req, o) }.buttonStyle(Pill())
                    }
                }
            }
            HStack(spacing: 6) {
                Field(placeholder: "Reply…", text: $text, submit: send)
                Button("Send", action: send).buttonStyle(Pill(fg: Ink.green, bg: Ink.greenTint))
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            inApp
        }
    }

    var inApp: some View {
        Button("Answer in app") { answer(req, "__app__") }.buttonStyle(Pill(fg: Ink.meta, bg: .clear, small: true))
    }

    func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { answer(req, t) }
    }

    var questions: some View {
        let qs = req.questions ?? []
        let single = qs.count == 1 && !(qs.first?.multiSelect ?? false)
        return VStack(alignment: .leading, spacing: 9) {
            ForEach(qs, id: \.self) { q in
                VStack(alignment: .leading, spacing: 6) {
                    askText(q.question)
                    // ponytail: multiSelect is treated as pick-one; toggles if real questions need it
                    Flow(spacing: 6) {
                        ForEach(q.options, id: \.self) { o in
                            Button(o) {
                                picks[q.question] = o
                                if single { submit(qs) }
                            }
                            .buttonStyle(picks[q.question] == o ? Pill(fg: Ink.green, bg: Ink.greenTint) : Pill())
                        }
                    }
                    Field(placeholder: "Other…", text: Binding(
                        get: { q.options.contains(picks[q.question] ?? "") ? "" : picks[q.question] ?? "" },
                        set: { picks[q.question] = $0 }),
                        submit: { if single { submit(qs) } })
                }
            }
            if !single {
                Button("Send") { submit(qs) }.buttonStyle(Pill(fg: Ink.green, bg: Ink.greenTint))
                    .disabled(qs.contains { (picks[$0.question] ?? "").isEmpty })
            }
            inApp
        }
    }

    func submit(_ qs: [Question]) {
        let answers = Dictionary(uniqueKeysWithValues: qs.map { ($0.question, picks[$0.question] ?? "") })
        if let data = try? JSONSerialization.data(withJSONObject: answers),
           let json = String(data: data, encoding: .utf8) { answer(req, json) }
    }
}

struct Field: View {
    let placeholder: String
    @Binding var text: String
    let submit: () -> Void
    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Ink.meta))
            .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Ink.text)
            .padding(.horizontal, 8).frame(height: 28)
            .background(Ink.field).clipShape(RoundedRectangle(cornerRadius: 6))
            .onSubmit(submit)
    }
}

// Lays children left to right and wraps onto new lines.
struct Flow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(proposal.width ?? .infinity, subviews).size
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, p) in rows(b.width, subviews).points.enumerated() {
            subviews[i].place(at: CGPoint(x: b.minX + p.x, y: b.minY + p.y), proposal: .unspecified)
        }
    }
    private func rows(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        var pts: [CGPoint] = []
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += line + spacing; line = 0 }
            pts.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            line = max(line, s.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + line), pts)
    }
}

struct Pill: ButtonStyle {
    var fg: Color = Ink.text
    var bg: Color = Ink.field
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 12 : 13, weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, small ? 8 : 12).frame(height: small ? 24 : 28)
            .background(bg.opacity(configuration.isPressed ? 0.6 : 1))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line, lineWidth: bg == .clear ? 1 : 0))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

// The original frosted look (HUD material), with a light dark tint so text holds up over light windows.
struct Glass<S: Shape>: ViewModifier {
    let shape: S
    func body(content: Content) -> some View {
        content
            .background(ZStack { VisualEffect(); Color.black.opacity(0.15) })
            .clipShape(shape)
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

final class Dock: ObservableObject {
    @Published var collapsed = true
}

// The slim tab at the screen edge: one light per session, waiting ones first.
struct Tab: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(spacing: 3) {
            Spark(spinning: store.sessions.contains { $0.status == "working" })
                .padding(.bottom, 3)
            ForEach(store.sessions.prefix(12)) { s in
                let l = s.light(store.requests[s.id], now: store.now)
                Light(color: l.0, mode: l.1, size: l.1 == .pulse ? 8 : 7)
            }
        }
        .padding(.vertical, 9).frame(width: 24)
        // solid, not blurred: the tab animates all day, and a blur behind it would be redone every frame
        .background(Color(white: 0.11).opacity(0.94))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 11, bottomLeadingRadius: 11))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 11, bottomLeadingRadius: 11)
            .stroke(Color.white.opacity(0.12), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}

struct RootView: View {
    @ObservedObject var store: Store
    @ObservedObject var settings: Settings
    @ObservedObject var dock: Dock
    let hide: () -> Void
    var body: some View {
        if settings.autoHide && dock.collapsed {
            HStack(alignment: .top, spacing: 8) {
                if let t = store.toast {
                    ToastCard(toast: t).transition(.move(edge: .trailing).combined(with: .opacity))
                }
                Tab(store: store)
            }
            .animation(.spring(duration: 0.35), value: store.toast)
        } else {
            PanelView(store: store, hide: hide)
        }
    }
}

struct PanelView: View {
    @ObservedObject var store: Store
    let hide: () -> Void
    @State private var listHeight: CGFloat = 0
    // Never taller than half the screen; scrolls after that.
    let maxList = (NSScreen.main?.visibleFrame.height ?? 900) * 0.5

    var summary: String {
        let w = store.sessions.filter { $0.status == "working" && store.requests[$0.id] == nil }.count
        let q = store.waitingCount
        return [w > 0 ? "\(w) working" : nil, q > 0 ? "\(q) waiting" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.sessions.isEmpty {
                Text("No sessions running").font(.system(size: 13)).foregroundStyle(Ink.meta).padding(.vertical, 8)
            }
            ForEach(Array(store.sessions.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Rectangle().fill(Ink.line).frame(height: 1) }
                Row(s: s, req: store.requests[s.id], now: store.now, answer: store.answer, jump: store.jump, store: store)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Claude").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.text)
                Text(summary).font(.system(size: 12)).foregroundStyle(Ink.secondary)
                Spacer()
                Button(action: hide) {
                    Image(systemName: "minus").font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Ink.secondary).help("Hide (show again from the menu bar)")
            }
            // fixed height = the list's own height, capped; the window then shrinks and grows with it
            ScrollView(.vertical) {
                list.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(max(listHeight, 20), maxList))
            Rectangle().fill(Ink.line).frame(height: 1)
            Footer(store: store)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 340)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 14)))
        .environment(\.colorScheme, .dark)
    }
}

/// The desktop app's own record for a session: its local_ id and which copy (Claude or Claude-Work).
func desktopRecord(_ cliId: String) -> (id: String, profile: String, title: String)? {
    let fm = FileManager.default
    for profile in ["Claude", "Claude-Work"] {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/\(profile)/claude-code-sessions")
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
        for case let url as URL in en where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  data.range(of: Data(cliId.utf8)) != nil,
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = o["sessionId"] as? String else { continue }
            return (id, profile, o["title"] as? String ?? "")
        }
    }
    return nil
}

// MARK: - Accounts: every saved Claude login, which ones are open, and adding new ones

/// One Claude login. `dir` is its desktop data folder in Application Support ("Claude" is the
/// normal app), `cli` its terminal settings folder, `launcher` the app that opens it.
struct Account: Codable, Identifiable, Hashable {
    var name: String
    var dir: String
    var cli: String
    var launcher: String
    var id: String { dir }
    var isMain: Bool { dir == "Claude" }
}

final class Accounts: ObservableObject {
    static let shared = Accounts()
    @Published var list: [Account] = []
    @Published var running: Set<String> = []   // dirs of the copies that are open now
    private var pids: [String: pid_t] = [:]
    private let file = base.appendingPathComponent("accounts.json")
    private let support = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    private let home = NSHomeDirectory()

    init() {
        if let d = try? Data(contentsOf: file), let l = try? JSONDecoder().decode([Account].self, from: d) {
            list = l
        } else {
            // the normal app; extra logins (Claude-<name> folders) are found by discover()
            list = [Account(name: "Personal", dir: "Claude", cli: "\(home)/.claude", launcher: "/Applications/Claude.app")]
        }
        discover()
        save()
        scan()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.scan() }
    }

    func save() {
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: file) }
    }

    /// Data folders made outside the panel (a Claude-<name> folder that has signed in) join the list.
    func discover() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []
        for n in names where n.hasPrefix("Claude-") && !list.contains(where: { $0.dir == n })
            && FileManager.default.fileExists(atPath: support.appendingPathComponent("\(n)/Cookies").path) {
            let label = String(n.dropFirst("Claude-".count))
            list.append(Account(name: label, dir: n, cli: "\(home)/.claude-\(label.lowercased())",
                                launcher: "\(home)/Applications/Claude \(label).app"))
        }
    }

    /// Which copies are open: the main Claude process, with or without --user-data-dir.
    func scan() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: [String: pid_t] = [:]
            for line in run("/usr/bin/pgrep", ["-a", "-lf", "^/Applications/Claude.app/Contents/MacOS/Claude( |$)"])
                .split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard let pid = pid_t(parts.first ?? "") else { continue }
                let args = parts.count > 1 ? String(parts[1]) : ""
                if let r = args.range(of: "--user-data-dir=") {
                    found[URL(fileURLWithPath: String(args[r.upperBound...])).lastPathComponent] = pid
                } else {
                    found["Claude"] = pid
                }
            }
            DispatchQueue.main.async {
                self?.pids = found
                if self?.running != Set(found.keys) { self?.running = Set(found.keys) }
            }
        }
    }

    func account(dir: String) -> Account? { list.first { $0.dir == dir } }

    /// The account a session belongs to: its desktop copy, else its terminal settings folder.
    func account(for s: Session) -> Account? {
        if let p = s.profile, let a = account(dir: p) { return a }
        if let c = s.cfg, !c.isEmpty { return list.first { $0.cli == c } }
        return account(dir: s.account == "work" ? "Claude-Work" : "Claude")
    }

    /// Bring the copy forward, or start it.
    func open(_ a: Account) {
        if let pid = pids[a.dir], let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        } else if a.isMain {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Claude.app"))
        } else {
            let path = support.appendingPathComponent(a.dir).path
            DispatchQueue.global().async {
                run("/usr/bin/open", ["-n", "-a", "/Applications/Claude.app", "--args", "--user-data-dir=\(path)"])
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.scan() }
    }

    /// The shell command that runs Claude in a terminal on this account.
    func claudeCommand(_ a: Account) -> String {
        a.isMain ? "claude" : "CLAUDE_CONFIG_DIR='\(a.cli)' claude"
    }

    func terminal(_ a: Account, cwd: String? = nil, args: String = "") {
        var cmd = claudeCommand(a) + (args.isEmpty ? "" : " " + args)
        if let cwd { cmd = "cd '\(cwd.replacingOccurrences(of: "'", with: ""))' && " + cmd }
        let script = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.global().async {
            osa("tell application \"Terminal\"\nactivate\ndo script \"\(script)\"\nend tell")
        }
    }

    /// Ask for a name, then set up a new login: its desktop data folder, a launcher app in
    /// ~/Applications, and a terminal settings folder sharing your instructions, skills and settings.
    func addInteractively() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add a Claude account"
        alert.informativeText = "Name it (for example Client or School). A new Claude window opens where you sign in. Use \"Continue with email\" and type the code into that window."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Account name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add and Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        let slug = String(name.filter { $0.isLetter || $0.isNumber || $0 == "-" })
        guard !slug.isEmpty, account(dir: "Claude-\(slug)") == nil, slug.lowercased() != "work" || account(dir: "Claude-Work") == nil
        else { return }
        add(name: name, slug: slug)
    }

    func add(name: String, slug: String) {
        let fm = FileManager.default
        let dir = "Claude-\(slug)"
        let cli = "\(home)/.claude-\(slug.lowercased())"
        let launcher = "\(home)/Applications/Claude \(name).app"
        try? fm.createDirectory(at: support.appendingPathComponent(dir), withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: cli, withIntermediateDirectories: true)
        for f in ["CLAUDE.md", "RTK.md", "settings.json", "skills", "plugins"] {
            try? fm.createSymbolicLink(atPath: "\(cli)/\(f)", withDestinationPath: "\(home)/.claude/\(f)")
        }
        let data = support.appendingPathComponent(dir).path
        let script = "do shell script \"open -n -a /Applications/Claude.app --args --user-data-dir=\\\"\(data)\\\"\""
        run("/usr/bin/osacompile", ["-o", launcher, "-e", script])
        let a = Account(name: name, dir: dir, cli: cli, launcher: launcher)
        list.append(a)
        save()
        open(a)
    }

    func remove(_ a: Account) {   // only from the list; its login and data stay on disk
        list.removeAll { $0 == a }
        save()
    }
}

/// The accounts row: one chip per saved login, lit while that copy is open, plus "+".
struct AccountsRow: View {
    @ObservedObject var accounts = Accounts.shared
    var body: some View {
        Flow(spacing: 6) {
            ForEach(accounts.list) { a in
                let on = accounts.running.contains(a.dir)
                Button { accounts.open(a) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(on ? Ink.green : Color(white: 0.4)).frame(width: 6, height: 6)
                        Text(a.name)
                    }
                }
                .buttonStyle(Pill(small: true))
                .help(on ? "\(a.name) is open: bring it forward (right-click for more)"
                         : "\(a.name) is closed: open it (right-click for more)")
                .contextMenu {
                    Button(on ? "Bring Forward" : "Open") { accounts.open(a) }
                    Button("New Terminal on \(a.name)") { accounts.terminal(a) }
                    if !a.isMain {
                        Divider()
                        Button("Remove from List") { accounts.remove(a) }
                    }
                }
            }
            Button { accounts.addInteractively() } label: { Image(systemName: "plus") }
                .buttonStyle(Pill(small: true)).help("Add another Claude account")
        }
    }
}

// MARK: - Usage today, counted from Claude's own session logs

final class UsageScanner {
    private var offsets: [String: UInt64] = [:]
    private var seen = Set<String>()
    private var totals: [String: Usage] = [:]
    private var day = ""
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Reads only what was appended since the last scan. One reply is logged as several lines
    /// sharing a message id, so replies are counted once per id.
    func scan(_ accounts: [(String, String)]) -> [String: Usage] {
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        if today != day { day = today; offsets = [:]; seen = []; totals = [:] }
        let fm = FileManager.default
        let start = Calendar.current.startOfDay(for: Date())
        for (acct, cli) in accounts {
            let root = URL(fileURLWithPath: cli).appendingPathComponent("projects")
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let mod = v?.contentModificationDate, mod >= start, let size = v?.fileSize else { continue }
                var from = offsets[url.path] ?? 0
                if UInt64(size) < from { from = 0 }
                guard UInt64(size) > from, let h = try? FileHandle(forReadingFrom: url) else { continue }
                try? h.seek(toOffset: from)
                let data = h.readDataToEndOfFile()
                try? h.close()
                // only whole lines; a half-written last line is read next time
                guard let lastNL = data.lastIndex(of: 0x0A) else { continue }
                offsets[url.path] = from + UInt64(lastNL - data.startIndex + 1)
                for line in data[data.startIndex...lastNL].split(separator: 0x0A) {
                    guard line.count > 20,
                          let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          o["type"] as? String == "assistant",
                          let ts = o["timestamp"] as? String, let d = iso.date(from: ts), d >= start,
                          let m = o["message"] as? [String: Any], let id = m["id"] as? String,
                          let u = m["usage"] as? [String: Any], !seen.contains(id) else { continue }
                    seen.insert(id)
                    let n = ["input_tokens", "output_tokens", "cache_creation_input_tokens"]
                        .reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
                    totals[acct, default: Usage()].replies += 1
                    totals[acct, default: Usage()].tokens += n
                }
            }
        }
        return totals
    }
}

func tokens(_ n: Int) -> String {
    n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)"
}

// MARK: - Living lights

enum LightMode { case breathe, pulse, flash, still }

/// One session's light: working breathes, waiting pulses, just-finished flashes, done is still.
/// Each runs its own small timeline that stops when the light is still.
struct Light: View {
    let color: Color
    let mode: LightMode
    var size: CGFloat = 8
    var animated = true   // off inside the glass panel: every frame there re-blurs what is behind it
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: mode == .still || !animated)) { ctx in
            let t = animated ? ctx.date.timeIntervalSinceReferenceDate : 0.6
            let period = mode == .pulse ? 1.1 : mode == .flash ? 0.35 : 2.4
            let w = (sin(t * 2 * .pi / period) + 1) / 2
            Circle()
                .fill(mode == .flash ? Color.white : color)
                .frame(width: size, height: size)
                .scaleEffect(mode == .pulse ? 0.85 + 0.35 * w : 1)
                .opacity(mode == .breathe ? 0.45 + 0.55 * w : 1)
                .shadow(color: mode == .still ? .clear : color.opacity(0.9), radius: mode == .still ? 0 : 1 + 4 * w)
        }
        .frame(width: size + 6, height: size + 6)
    }
}

extension Session {
    func light(_ req: Request?, now: Double) -> (Color, LightMode) {
        if req != nil || status == "waiting" { return (Ink.ask, .pulse) }
        if status == "working" {
            let long = now - (turnStart ?? updated) > 900  // 15 min: worth a look
            return (long ? Ink.amber : Ink.green, .breathe)
        }
        if let f = finishedAt, now - f < 2.5 { return (Ink.green, .flash) }
        return (Color(white: 0.4), .still)
    }
}

/// The Claude spark on the tab: turns while anything is working.
struct Spark: View {
    let spinning: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !spinning)) { ctx in
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(spinning ? Ink.ask : Color(white: 0.6))
                .rotationEffect(.degrees(spinning ? ctx.date.timeIntervalSinceReferenceDate * 90 : 0))
        }
    }
}

/// The card that slides out of the tab when a session finishes.
struct ToastCard: View {
    let toast: Toast
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.green).font(.system(size: 12))
                Text(toast.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                Spacer(minLength: 6)
                Text(clock(toast.secs)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Ink.meta)
            }
            if !toast.result.isEmpty {
                Text(toast.result).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(width: 260, alignment: .leading)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 12)))
        .environment(\.colorScheme, .dark)
    }
}

/// Bottom of the panel: open either account, and today's usage per account.
struct Footer: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            AccountsRow()
            Text(usageLine).font(.system(size: 11)).foregroundStyle(Ink.meta).lineLimit(1)
                .help("Replies and tokens (input + output, cache reads left out) from Claude's session logs today")
        }
    }
    var usageLine: String {
        let parts = Accounts.shared.list.compactMap { a -> String? in
            guard let u = store.usage[a.dir], u.replies > 0 else { return nil }
            return "\(a.name) \(u.replies) replies · \(tokens(u.tokens))"
        }
        return "Today  " + (parts.isEmpty ? "no replies yet" : parts.joined(separator: "   "))
    }
}

/// Runs a tool and returns its output. Reads before waiting: a child whose output fills the
/// pipe buffer (64 KB) blocks until someone reads, so waiting first would hang forever.
@discardableResult
func run(_ tool: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

@discardableResult
func osa(_ script: String) -> String { run("/usr/bin/osascript", ["-e", script]) }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panel: NSPanel!
    var item: NSStatusItem!
    let settings = Settings()
    lazy var store = Store(settings: settings)
    let dock = Dock()
    var hosting: NSHostingView<RootView>!
    var lastInside = Date()
    var animating = false
    let collapseDelay = 1.5   // seconds after the pointer leaves

    func applicationDidFinishLaunching(_ n: Notification) {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 80),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        hosting = NSHostingView(rootView: RootView(store: store, settings: settings, dock: dock) { [weak self] in
            guard let self else { return }
            self.settings.autoHide ? self.collapse() : self.setPanel(false)
        })
        hosting.sizingOptions = [.intrinsicContentSize]  // report size only; place() sizes and moves the window
        panel.contentView = hosting
        if !panel.setFrameUsingName("ClaudePanel"), let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - 360, y: f.maxY - 20))
        }
        panel.setFrameAutosaveName("ClaudePanel")
        setPanel(UserDefaults.standard.object(forKey: "showPanel") as? Bool ?? true)
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        _ = Accounts.shared
        refreshLoginItems()

        // New icons land on the far left, often behind the notch: start it near the clock instead.
        // (macOS keeps this spot; Cmd-drag the icon to move it.)
        UserDefaults.standard.register(defaults: ["NSStatusItem Preferred Position ClaudePanel": 330])
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "ClaudePanel"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        store.onChange = { [weak self] in self?.updateIcon() }
        updateIcon()
    }

    // Size the window to its content; with auto-hide it sits flush against the right screen edge.
    func place() {
        guard !animating, let screen = panel.screen ?? NSScreen.main else { return }
        // a window shadow is recomputed on every frame of the tab's animation; only the open panel has one
        let shadow = !(settings.autoHide && dock.collapsed)
        if panel.hasShadow != shadow { panel.hasShadow = shadow }
        let size = hosting.intrinsicContentSize
        let top = panel.frame.maxY
        let x = settings.autoHide ? screen.visibleFrame.maxX - size.width : panel.frame.minX
        let f = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        if f != panel.frame { panel.setFrame(f, display: true) }
    }

    func tick() {
        guard panel.isVisible else { return }
        if settings.autoHide {
            let inside = panel.frame.insetBy(dx: -3, dy: -3).contains(NSEvent.mouseLocation)
            let typing = panel.isKeyWindow && panel.firstResponder is NSText
            if inside || typing { lastInside = Date() }
            if animating { return }
            if dock.collapsed && inside {
                expand()
            } else if !dock.collapsed && Date().timeIntervalSince(lastInside) > collapseDelay {
                collapse()
            }
        }
        place()
    }

    // Slide the open panel into the right edge, then show the tab of lights.
    func collapse() {
        if panel.isKeyWindow { panel.resignKey() }
        animating = true
        let f = panel.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(f.offsetBy(dx: f.width, dy: 0), display: true)
            panel.animator().alphaValue = 0.3
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.dock.collapsed = true
            self.hosting.layoutSubtreeIfNeeded()
            self.animating = false
            self.place()
            self.panel.alphaValue = 1
        })
    }

    // Swap in the full panel just off the edge, then slide it out.
    func expand() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        animating = true
        dock.collapsed = false
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.intrinsicContentSize
        let top = panel.frame.maxY
        let edge = screen.visibleFrame.maxX
        panel.setFrame(NSRect(x: edge, y: top - size.height, width: size.width, height: size.height), display: true)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(NSRect(x: edge - size.width, y: top - size.height,
                                             width: size.width, height: size.height), display: true)
        }, completionHandler: { [weak self] in
            self?.animating = false
            self?.lastInside = Date()
        })
    }

    func setPanel(_ show: Bool) {
        show ? panel.orderFrontRegardless() : panel.orderOut(nil)
        UserDefaults.standard.set(show, forKey: "showPanel")
    }

    func updateIcon() {
        // Plain template symbols only: a tinted icon or title rendered invisible on the macOS 26 menu bar.
        let n = min(store.waitingCount, 50)
        let name = n > 0 ? "\(n).circle.fill" : "sparkles"
        if item?.button?.image?.accessibilityDescription != name {
            item?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: name)
        }
    }

    // Rebuilt every time the menu opens so checkmarks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ on: Bool?, _ action: Selector, key: String = "") {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            if let on { i.state = on ? .on : .off }
            menu.addItem(i)
        }
        refreshLoginItems()  // read in the background; the menu shows the last known state
        let w = store.sessions.filter { $0.status == "working" }.count
        let info = NSMenuItem(title: "\(w) working · \(store.waitingCount) waiting", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        add("Show Panel", panel.isVisible, #selector(togglePanel))
        // accounts: open (checked = open now), a terminal on each, start at login, add another
        menu.addItem(.separator())
        let head = NSMenuItem(title: "Accounts", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        let terms = NSMenu(), logins = NSMenu()
        for a in Accounts.shared.list {
            let i = NSMenuItem(title: a.name, action: #selector(openAccount(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = a.dir
            i.state = Accounts.shared.running.contains(a.dir) ? .on : .off
            menu.addItem(i)
            let t = NSMenuItem(title: a.name, action: #selector(termAccount(_:)), keyEquivalent: "")
            t.target = self; t.representedObject = a.dir
            terms.addItem(t)
            let appName = URL(fileURLWithPath: a.launcher).deletingPathExtension().lastPathComponent
            let l = NSMenuItem(title: a.name, action: #selector(loginAccount(_:)), keyEquivalent: "")
            l.target = self; l.representedObject = a.dir
            l.state = loginItems.contains(appName) ? .on : .off
            logins.addItem(l)
        }
        let tm = NSMenuItem(title: "New Terminal On", action: nil, keyEquivalent: ""); tm.submenu = terms
        let lm = NSMenuItem(title: "Start at Login", action: nil, keyEquivalent: ""); lm.submenu = logins
        menu.addItem(tm)
        menu.addItem(lm)
        add("Add Account…", nil, #selector(addAccount))
        menu.addItem(.separator())
        add("Sound When Claude Needs You", settings.sound, #selector(toggleSound))
        add("Sound When a Session Finishes", settings.soundDone, #selector(toggleSoundDone))
        add("Approve From Panel", settings.approve, #selector(toggleApprove))
        add("Answer Questions From Panel", settings.reply, #selector(toggleReply))
        add("Hide Finished Sessions", settings.hideDone, #selector(toggleDone))
        add("Auto-Hide to Screen Edge", settings.autoHide, #selector(toggleAutoHide))
        add("Open Panel at Login", loginItems.contains("Claude Panel"), #selector(toggleLogin))
        menu.addItem(.separator())
        add("Quit Claude Panel", nil, #selector(quit), key: "q")
    }

    @objc func togglePanel() { setPanel(!panel.isVisible) }
    @objc func toggleSound() { settings.sound.toggle() }
    @objc func toggleSoundDone() { settings.soundDone.toggle() }
    func acct(_ sender: NSMenuItem) -> Account? { Accounts.shared.account(dir: sender.representedObject as? String ?? "") }
    @objc func openAccount(_ sender: NSMenuItem) { if let a = acct(sender) { Accounts.shared.open(a) } }
    @objc func termAccount(_ sender: NSMenuItem) { if let a = acct(sender) { Accounts.shared.terminal(a) } }
    @objc func loginAccount(_ sender: NSMenuItem) {
        guard let a = acct(sender) else { return }
        setLogin(URL(fileURLWithPath: a.launcher).deletingPathExtension().lastPathComponent, a.launcher)
    }
    @objc func addAccount() { Accounts.shared.addInteractively() }
    var loginItems = Set<String>()

    func refreshLoginItems() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let names = Set(osa("tell application \"System Events\" to get the name of every login item")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            DispatchQueue.main.async { self?.loginItems = names }
        }
    }

    func setLogin(_ name: String, _ path: String) {
        let on = loginItems.contains(name)
        if on { loginItems.remove(name) } else { loginItems.insert(name) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if on {
                osa("tell application \"System Events\" to delete login item \"\(name)\"")
            } else {
                osa("tell application \"System Events\" to make login item at end with properties {path:\"\(path)\", hidden:false}")
            }
            self?.refreshLoginItems()
        }
    }
    @objc func toggleApprove() { settings.approve.toggle() }
    @objc func toggleReply() { settings.reply.toggle() }
    @objc func toggleAutoHide() { settings.autoHide.toggle(); dock.collapsed = settings.autoHide }
    @objc func toggleDone() { settings.hideDone.toggle(); store.load() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleLogin() { setLogin("Claude Panel", appPath) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

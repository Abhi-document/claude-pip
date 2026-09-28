// ClaudePiP: floating always-on-top window for the current Claude Code session.
//   ClaudePiP        opens the window
//   ClaudePiP hook   Claude Code hook (PermissionRequest / Stop / UserPromptSubmit), bridges to the window
// Both sides talk through files in ~/.claude/pip/. Build with ../build.sh
import AppKit

let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/pip")
func url(_ n: String) -> URL { dir.appendingPathComponent(n) }

func readJSON(_ n: String) -> [String: Any] {
    guard let d = try? Data(contentsOf: url(n)) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
}

// Append-only debug log (~/.claude/pip/log.txt): why the window closed, what Stop killed.
func debugLog(_ msg: String) {
    guard let h = FileHandle(forWritingAtPath: url("log.txt").path) ?? {
        FileManager.default.createFile(atPath: url("log.txt").path, contents: nil)
        return FileHandle(forWritingAtPath: url("log.txt").path)
    }() else { return }
    h.seekToEndOfFile()
    h.write(Data("\(Date()) \(msg)\n".utf8))
    try? h.close()
}

// Esc stops Claude (like in Claude Code) instead of closing the panel, AppKit's default.
final class Panel: NSPanel {
    var onEscape: () -> Void = {}
    override func cancelOperation(_ sender: Any?) { onEscape() }
}

func writeJSON(_ n: String, _ o: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
    try? d.write(to: url(n), options: .atomic)
}

func brief(_ input: Any?) -> String {
    let i = input as? [String: Any] ?? [:]
    let s = i["command"] ?? i["file_path"] ?? i["url"] ?? i["pattern"] ?? i["description"]
    if let s { return "\(s)" }
    guard let d = try? JSONSerialization.data(withJSONObject: i) else { return "" }
    return String(decoding: d, as: UTF8.self)
}

// Last ~30 messages from the tail of the session transcript (JSONL).
func tail(_ path: String) -> String {
    guard let h = FileHandle(forReadingAtPath: path) else { return "" }
    defer { try? h.close() }
    let size = h.seekToEndOfFile()
    h.seek(toFileOffset: size > 131_072 ? size - 131_072 : 0)
    var out: [String] = []
    for line in String(decoding: h.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n") {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = o["type"] as? String, type == "user" || type == "assistant",
              o["isMeta"] as? Bool != true,
              let msg = o["message"] as? [String: Any] else { continue }
        let who = type == "user" ? "› " : ""
        if let s = msg["content"] as? String { out.append(who + s); continue }
        for b in msg["content"] as? [[String: Any]] ?? [] {
            switch b["type"] as? String {
            case "text": out.append(who + (b["text"] as? String ?? ""))
            case "tool_use": out.append("⚙ \(b["name"] as? String ?? ""): \(brief(b["input"]).prefix(200))")
            default: break
            }
        }
    }
    return out.suffix(30).joined(separator: "\n\n")
}

@MainActor final class App: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    let status = NSTextField(labelWithString: "Open — waiting for Claude Code to finish a turn…")
    let scroll = NSTextView.scrollableTextView()
    var log: NSTextView { scroll.documentView as! NSTextView }
    let reqLabel = NSTextField(wrappingLabelWithString: "")
    let reqBox = NSStackView()
    let inputScroll = NSTextView.scrollableTextView()
    var input: NSTextView { inputScroll.documentView as! NSTextView }
    var inputHeight: NSLayoutConstraint!
    var reqID = "", answered = "", lastLog = "", note = ""
    var noteUntil = Date.distantPast

    func applicationDidFinishLaunching(_ n: Notification) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        panel.title = "Claude Code"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onEscape = { [unowned self] in stopClaude() }

        status.font = .boldSystemFont(ofSize: 12)
        status.cell?.wraps = true
        status.maximumNumberOfLines = 2
        log.isEditable = false
        log.font = .systemFont(ofSize: 12)
        log.textContainerInset = NSSize(width: 4, height: 6)

        reqLabel.maximumNumberOfLines = 8
        reqLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let approve = NSButton(title: "Approve", target: self, action: #selector(approve))
        approve.bezelColor = .systemGreen
        let decline = NSButton(title: "Decline", target: self, action: #selector(decline))
        reqBox.orientation = .vertical
        reqBox.alignment = .leading
        reqBox.addArrangedSubview(reqLabel)
        reqBox.addArrangedSubview(NSStackView(views: [approve, decline]))
        reqBox.isHidden = true

        // Grows with its content like Claude Code's input: Enter sends, Shift+Enter adds a line.
        input.isRichText = false
        input.font = .systemFont(ofSize: 13)
        input.textContainerInset = NSSize(width: 2, height: 4)
        input.delegate = self
        input.setValue(NSAttributedString(string: "Instruction for Claude (Enter to send, ⇧Enter for new line)",
                                          attributes: [.foregroundColor: NSColor.placeholderTextColor, .font: input.font!]),
                       forKey: "placeholderAttributedString")
        inputScroll.borderType = .bezelBorder
        inputHeight = inputScroll.heightAnchor.constraint(equalToConstant: 28)
        inputHeight.isActive = true
        let stop = NSButton(title: "Stop", target: self, action: #selector(stopClaude))
        stop.bezelColor = .systemRed
        stop.toolTip = "Stop the current task (like Esc). Then send a new instruction, or close the window to return to the terminal"
        let row = NSStackView(views: [inputScroll, NSButton(title: "Send", target: self, action: #selector(send)), stop])
        row.alignment = .bottom

        let stack = NSStackView(views: [status, scroll, reqBox, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        panel.contentView = stack
        for v in [status, scroll, reqBox, row] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        reqLabel.widthAnchor.constraint(equalTo: reqBox.widthAnchor).isActive = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        inputScroll.setContentHuggingPriority(.init(1), for: .horizontal)

        if let f = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.maxX - 400, y: f.minY + 20))
        }
        panel.orderFrontRegardless()
        debugLog("window opened, pid \(getpid())")
        tick()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { self.tick() } }
    }

    func tick() {
        FileManager.default.createFile(atPath: url("alive").path, contents: nil)  // heartbeat for the hooks
        let s = readJSON("session.json")
        if let st = s["status"] as? String {
            let proj = (s["cwd"] as? String ?? "").split(separator: "/").last ?? ""
            status.stringValue = "● \(st)   ·   \(proj)"
            status.textColor = st == "needs approval" ? .systemOrange : st.hasPrefix("waiting") ? .systemGreen : .labelColor
        }
        if Date() < noteUntil {  // what the last Stop click did
            status.stringValue = note
            status.textColor = .systemRed
        } else if FileManager.default.fileExists(atPath: url("stop").path) {  // until Claude has ended its turn
            status.stringValue = "■ Stopping… Claude won't start anything new"
            status.textColor = .systemRed
        }
        if let t = s["transcript"] as? String {
            let l = tail(t)
            if l != lastLog { lastLog = l; log.string = l; log.scrollToEndOfDocument(nil) }
        }
        let r = readJSON("request.json")
        let id = r["id"] as? String ?? ""
        if id != reqID, !id.isEmpty {
            reqLabel.stringValue = "Allow \(r["tool"] as? String ?? "tool")?\n\(brief(r["input"]).prefix(600))"
            NSSound(named: "Glass")?.play()
        }
        reqID = id
        reqBox.isHidden = id.isEmpty || id == answered
    }

    func respond(_ behavior: String) {
        guard !reqID.isEmpty else { return }
        var o: [String: Any] = ["id": reqID, "behavior": behavior]
        if behavior == "deny", !input.string.isEmpty { o["message"] = input.string; input.string = ""; fitInput() }
        writeJSON("response.json", o)
        answered = reqID
        reqBox.isHidden = true
    }

    @objc func approve() { respond("allow") }
    @objc func decline() { respond("deny") }

    @objc func send() {
        let t = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let old = (try? String(contentsOf: url("inbox.txt"), encoding: .utf8)) ?? ""
        try? (old + t + "\n").write(to: url("inbox.txt"), atomically: true, encoding: .utf8)
        input.string = ""
        fitInput()
        status.stringValue = "✉︎ Sent — Claude picks it up when its current turn ends"
    }

    @objc func stopClaude() {
        let s = readJSON("session.json"), st = s["status"] as? String ?? ""
        guard ["working", "needs approval", "stopping"].contains(st) else {
            return flash("Nothing to stop: Claude isn't working right now")
        }
        FileManager.default.createFile(atPath: url("stop").path, contents: nil)  // hooks deny every next tool call
        // Kill the command Claude is running right now: each Bash tool call is its own process group
        // (a shell spawned by Claude from a shell-snapshot), so this ends the whole command and nothing else.
        var killed = 0
        if let pid = s["pid"] as? Int {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "for g in $(pgrep -P \(pid) -f shell-snapshots/snapshot-); do echo \"$(date) stop: killing group $g: $(ps -o command= -p $g | cut -c1-150)\" >> '\(url("log.txt").path)'; kill -TERM -$g && echo k; done"]
            p.standardOutput = out
            if (try? p.run()) != nil {
                killed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").count
                p.waitUntilExit()
            }
        }
        debugLog("stop clicked (status \(st)), killed \(killed) command(s)")
        // A reply being written can't be cut off from outside Claude Code (only Esc in its own panel can);
        // it ends after that reply because every further tool call is denied.
        flash(killed > 0 ? "■ Stopped the running command. Claude is ending its turn"
                         : "■ Claude is finishing its current reply, then stops (it won't start anything new)")
    }

    func flash(_ note: String) {
        self.note = note
        noteUntil = Date().addingTimeInterval(5)
        tick()
    }

    func textDidChange(_ n: Notification) { fitInput() }

    func fitInput() {
        guard let lm = input.layoutManager, let tc = input.textContainer else { return }
        lm.ensureLayout(for: tc)
        inputHeight.constant = min(max(lm.usedRect(for: tc).height + 12, 28), 160)  // scrolls past ~8 lines
    }

    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { stopClaude(); return true }  // Esc while typing
        guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { tv.insertNewlineIgnoringFieldEditor(nil) } else { send() }
        return true
    }

    func windowWillClose(_ n: Notification) { debugLog("window closed"); NSApp.terminate(nil) }
    func applicationWillTerminate(_ n: Notification) {
        debugLog("app terminating")
        try? FileManager.default.removeItem(at: url("alive"))
    }
}

// MARK: hook mode. No-op unless the window is open (it touches ~/.claude/pip/alive every 0.5s).

func alive() -> Bool {
    let m = (try? FileManager.default.attributesOfItem(atPath: url("alive").path))?[.modificationDate] as? Date
    return m.map { Date().timeIntervalSince($0) < 3 } ?? false
}

func takeInbox() -> String? {
    guard rename(url("inbox.txt").path, url("inbox.taken").path) == 0,
          let s = try? String(contentsOf: url("inbox.taken"), encoding: .utf8) else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

func reply(_ o: [String: Any]) -> Never {
    FileHandle.standardOutput.write((try? JSONSerialization.data(withJSONObject: o)) ?? Data())
    exit(0)
}

// PID of the Claude Code process that ran this hook (skipping an `sh -c` wrapper if there is one).
func claudePID() -> Int {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "ppid=,comm=", "-p", "\(getppid())"]
    p.standardOutput = out
    guard (try? p.run()) != nil else { return Int(getppid()) }
    let f = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    p.waitUntilExit()
    return f.count == 2 && f[1].hasSuffix("sh") ? Int(f[0]) ?? Int(getppid()) : Int(getppid())
}

func runHook() -> Never {
    let h = (try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())) as? [String: Any] ?? [:]
    guard alive() else { exit(0) }
    let sid = h["session_id"] as? String ?? ""
    // ponytail: one session at a time, last hook to fire owns the window. Key files by session_id to support several.
    func status(_ s: String) {
        writeJSON("session.json", ["id": sid, "transcript": h["transcript_path"] ?? "", "cwd": h["cwd"] ?? "",
                                   "status": s, "pid": claudePID()])
    }
    func mine() -> Bool { readJSON("session.json")["id"] as? String == sid }
    func rm(_ n: String) { try? FileManager.default.removeItem(at: url(n)) }
    // Stop is sticky: every tool call is denied until Claude ends its turn, then the Stop hook clears it
    // and waits for the next instruction from the window (like Esc, not like quitting).
    func stopping() -> Bool { FileManager.default.fileExists(atPath: url("stop").path) }
    let stopped = "The user pressed Stop in the PiP window. Do not run any more tools. End your turn now with one short line saying where you stopped."

    switch h["hook_event_name"] as? String {
    case "UserPromptSubmit":
        rm("stop")  // a stale click must not kill a fresh prompt
        status("working")
    case "PreToolUse":
        if stopping() {
            status("stopping")
            reply(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny",
                                          "permissionDecisionReason": stopped]])
        }
    case "PermissionRequest" where h["tool_name"] as? String != "AskUserQuestion":
        let rid = "\(Date().timeIntervalSince1970)"
        status("needs approval")
        writeJSON("request.json", ["id": rid, "tool": h["tool_name"] ?? "", "input": h["tool_input"] ?? [:]])
        while alive(), readJSON("request.json")["id"] as? String == rid {
            if stopping() {
                rm("request.json"); status("stopping")
                reply(["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                       "decision": ["behavior": "deny", "message": stopped]]])
            }
            let r = readJSON("response.json")
            if r["id"] as? String == rid, let b = r["behavior"] as? String {
                rm("request.json"); rm("response.json"); status("working")
                var d: [String: Any] = ["behavior": b]
                if b == "deny" { d["message"] = r["message"] as? String ?? "User declined this from the PiP window." }
                reply(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": d]])
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        if readJSON("request.json")["id"] as? String == rid { rm("request.json") }  // window closed: normal prompt
    case "Stop":
        status("waiting for instruction")
        while alive(), mine() {
            rm("stop")  // already stopped; a click while waiting must not block the next instruction
            if let msg = takeInbox() {
                status("working")
                reply(["hookSpecificOutput": ["hookEventName": "Stop",
                       "additionalContext": "New instruction from the user (sent via PiP window): " + msg]])
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if mine() { status("idle (control returned to terminal)") }
    default:
        break
    }
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "hook" { runHook() }

// Leave the process group of the command that launched us, or Claude Code kills the window
// along with that command when a turn is stopped.
setsid()
signal(SIGHUP, SIG_IGN)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

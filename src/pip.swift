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
    override var canBecomeKey: Bool { true }  // lets the borderless notch panel take typing

    // There's no menu bar (accessory app), so the standard editing shortcuts are wired up here.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = (mods == [.command, .shift] ? "⇧" : mods == .command ? "" : "✗") + (e.charactersIgnoringModifiers ?? "")
        let action: Selector? = ["v": #selector(NSText.paste(_:)), "c": #selector(NSText.copy(_:)),
                                 "x": #selector(NSText.cut(_:)), "a": #selector(NSText.selectAll(_:)),
                                 "z": Selector(("undo:")), "⇧z": Selector(("redo:"))][key.lowercased()]
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: e)
    }
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

// Last ~30 messages from the tail of the session transcript (JSONL), plus Claude's latest reply.
func tail(_ path: String) -> (log: String, reply: String) {
    guard let h = FileHandle(forReadingAtPath: path) else { return ("", "") }
    defer { try? h.close() }
    let size = h.seekToEndOfFile()
    h.seek(toFileOffset: size > 131_072 ? size - 131_072 : 0)
    var out: [String] = [], reply = ""
    for line in String(decoding: h.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n") {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = o["type"] as? String, type == "user" || type == "assistant",
              o["isMeta"] as? Bool != true,
              let msg = o["message"] as? [String: Any] else { continue }
        let who = type == "user" ? "› " : ""
        if let s = msg["content"] as? String { out.append(who + s); continue }
        for b in msg["content"] as? [[String: Any]] ?? [] {
            switch b["type"] as? String {
            case "text":
                out.append(who + (b["text"] as? String ?? ""))
                if type == "assistant" { reply = b["text"] as? String ?? "" }
            case "tool_use": out.append("⚙ \(b["name"] as? String ?? ""): \(brief(b["input"]).prefix(200))")
            default: break
            }
        }
    }
    return (out.suffix(30).joined(separator: "\n\n"), reply)
}

// MARK: notch mode: a cute agent living in the MacBook notch. Hover to open it: status, approvals, chat box.

final class Flipped: NSView { override var isFlipped: Bool { true } }

final class Tap: NSView {
    var onClick: (NSPoint) -> Void = { _ in }
    var hand = false
    override func mouseDown(with e: NSEvent) { onClick(convert(e.locationInWindow, from: nil)) }
    override func resetCursorRects() { if hand { addCursorRect(bounds, cursor: .pointingHand) } }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}

@MainActor final class Notch: NSObject {
    unowned let app: App
    let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let bg = NSView(), content = Flipped(), tap = Tap()
    // head (the agent's body) > face (mood animations) > gaze (follows the mouse) > eyes (blink)
    let head = CALayer(), face = CALayer(), gaze = CALayer(), eyes = [CALayer(), CALayer()], dot = CALayer()
    let title = NSTextField(labelWithString: ""), info = NSTextField(wrappingLabelWithString: "")
    let chat = NSTextField()
    let pageTap = Tap(), pageLabel = NSTextField(labelWithString: "")
    var reply = "", pages: [String] = [], page = 0, shown = "", typer: Timer?
    let approve: NSButton, decline: NSButton, stop: NSButton, back: NSButton
    var hovering = false, ghost = false, expanded = false, popUntil = Date.distantPast, reactUntil = Date.distantPast
    var lastStatus = "", mood = "", reaction = ""
    var status = "", note: String?, request: String?, last = ""

    // The built-in display (the one with a notch), else the main one.
    var screen: NSScreen { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0] }
    var strip: CGFloat { max(screen.safeAreaInsets.top, NSStatusBar.system.thickness) }
    var notchWidth: CGFloat {
        guard let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea else { return 110 }
        return screen.frame.width - l.width - r.width
    }

    init(app: App) {
        self.app = app
        approve = NSButton(title: "Approve", target: app, action: #selector(App.approve))
        decline = NSButton(title: "Decline", target: app, action: #selector(App.decline))
        stop = NSButton(title: "Stop", target: app, action: #selector(App.stopClaude))
        back = NSButton(title: "Window", target: app, action: #selector(App.toggleNotch))
        super.init()
        approve.bezelColor = .systemGreen
        stop.bezelColor = .systemRed
        back.toolTip = "Switch back to the floating window"
        chat.placeholderString = "Message Claude… (Enter to send)"
        chat.target = self
        chat.action = #selector(sendChat)
        chat.focusRingType = .none
        // Click the right half of the reply for the next page, the left half for the previous one.
        pageTap.hand = true
        pageTap.onClick = { [unowned self] p in p.x < pageTap.bounds.midX ? prevPage() : nextPage() }
        pageLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        pageLabel.font = .systemFont(ofSize: 9)

        panel.level = .statusBar  // above the menu bar, where the notch is
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.acceptsMouseMovedEvents = true
        panel.onEscape = { [unowned self] in chat.stringValue = ""; panel.makeFirstResponder(nil) }
        panel.contentView = bg
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.cgColor
        bg.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]  // round the bottom only
        content.frame = bg.bounds
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        bg.addSubview(content)

        head.cornerRadius = 22
        for e in eyes { e.cornerRadius = 3.5; gaze.addSublayer(e) }
        face.addSublayer(gaze)
        head.addSublayer(face)
        dot.cornerRadius = 4
        content.layer?.addSublayer(head)
        content.layer?.addSublayer(dot)
        tap.onClick = { [unowned self] _ in react() }
        tap.toolTip = "Poke me!"

        title.font = .boldSystemFont(ofSize: 13)
        title.textColor = .white
        info.font = .systemFont(ofSize: 13)
        info.textColor = NSColor.white.withAlphaComponent(0.9)
        info.maximumNumberOfLines = 4
        info.lineBreakMode = .byWordWrapping
        info.cell?.truncatesLastVisibleLine = true
        for v in [title, info, approve, decline, stop, back, chat, tap, pageLabel, pageTap] as [NSView] {
            content.addSubview(v)
        }

        // Mouse tracking (no permissions needed for mouse moves): hover opens the notch, eyes follow the cursor.
        NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in MainActor.assumeIsolated { self.mouseMoved() } }
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { e in self.mouseMoved(); return e }
        Timer.scheduledTimer(withTimeInterval: 3.3, repeats: true) { _ in MainActor.assumeIsolated { self.blink() } }
    }

    func show() {
        expanded = false
        place(animated: false)
        panel.ignoresMouseEvents = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }

    func place(animated: Bool) {
        let w = expanded ? max(notchWidth + 120, 440) : notchWidth + 90
        let h = expanded ? strip + 184 : strip
        let f = screen.frame
        let frame = NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
        let x0: CGFloat = 104, cw = w - x0 - 16

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.25 : 0)
        bg.layer?.cornerRadius = expanded ? 20 : 10
        // Small eyes in the notch's left "ear" when closed; a bigger head on the left when open.
        let (ew, eh, gap): (CGFloat, CGFloat, CGFloat) = expanded ? (12, 22, 22) : (7, 12, 13)
        head.frame = expanded ? CGRect(x: 18, y: strip + 12, width: 72, height: 72) : CGRect(x: 14, y: 0, width: 30, height: strip)
        head.backgroundColor = NSColor(white: expanded ? 0.16 : 0, alpha: expanded ? 1 : 0).cgColor
        face.frame = head.bounds
        gaze.frame = CGRect(x: (head.bounds.width - ew * 2 - gap) / 2, y: (head.bounds.height - eh) / 2,
                            width: ew * 2 + gap, height: eh)
        for (i, e) in eyes.enumerated() {
            e.frame = CGRect(x: CGFloat(i) * (ew + gap), y: 0, width: ew, height: eh)
            e.cornerRadius = ew / 2
        }
        dot.frame = CGRect(x: w - 30, y: strip / 2 - 4, width: 8, height: 8)
        CATransaction.commit()

        tap.frame = NSRect(origin: head.frame.origin, size: head.frame.size)
        title.frame = NSRect(x: x0, y: strip + 10, width: cw, height: 18)
        info.frame = NSRect(x: x0, y: strip + 32, width: cw, height: 76)
        pageTap.frame = info.frame
        approve.frame = NSRect(x: x0 - 4, y: strip + 110, width: 92, height: 28)
        decline.frame = NSRect(x: x0 + 90, y: strip + 110, width: 92, height: 28)
        stop.frame = NSRect(x: x0 - 4, y: strip + 110, width: 92, height: 28)
        pageLabel.frame = NSRect(x: x0, y: strip + 117, width: 160, height: 14)
        back.frame = NSRect(x: w - 96, y: strip + 110, width: 84, height: 28)
        chat.frame = NSRect(x: 18, y: strip + 148, width: w - 36, height: 26)
        pageTap.window?.invalidateCursorRects(for: pageTap)
        if !expanded { [title, info, approve, decline, stop, back, chat, pageLabel, pageTap].forEach { $0.isHidden = true } }
        panel.hasShadow = expanded
        if animated {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().setFrame(frame, display: true) }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    // Called every tick with the session state.
    func update(status st: String, note: String?, request: String?, last: String, reply: String) {
        if st != lastStatus, st.hasPrefix("waiting"), !lastStatus.isEmpty { popUntil = Date().addingTimeInterval(8) }  // done!
        if reply != self.reply { self.reply = reply; pages = paginate(reply); page = 0 }
        lastStatus = st
        status = st; self.note = note; self.request = request; self.last = last
        refresh()
    }

    func refresh() {
        let m = request != nil ? "approval" : ["working", "stopping"].contains(status) ? "working"
            : status.hasPrefix("waiting") ? "waiting" : "idle"
        setMood(m)
        title.stringValue = Date() < reactUntil ? reaction : note ?? [
            "approval": "Claude needs your OK 👀", "working": "Working on it…",
            "waiting": "Done! What's next? ✨", "idle": "Napping… 💤"][m]!
        // Done: Claude's reply, a page at a time. Otherwise: the request, or what Claude is doing.
        let talking = m == "waiting" && !pages.isEmpty
        show(request ?? (talking ? pages[page] : last), typed: talking)
        let typing = panel.isKeyWindow && chat.currentEditor() != nil
        let open = hovering || typing || request != nil || Date() < popUntil
        if open != expanded {
            expanded = open
            place(animated: true)
            panel.ignoresMouseEvents = !open  // closed: clicks pass through to the menu bar under it
            fade()
        }
        guard expanded else { return }
        [title, info, back, chat].forEach { $0.isHidden = false }
        approve.isHidden = request == nil
        decline.isHidden = request == nil
        stop.isHidden = request != nil || m != "working"
        let paged = talking && pages.count > 1
        [pageLabel, pageTap].forEach { $0.isHidden = !paged }
        pageLabel.stringValue = pages.indices.map { $0 == page ? "●" : "○" }.joined(separator: " ")
    }

    // Plain text in ~4-line pages, split between words, preferably at the end of a sentence.
    func paginate(_ text: String) -> [String] {
        let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: #"(?m)^#+\s*"#, with: "", options: .regularExpression)
        var pages: [String] = [], cur = ""
        for word in plain.split(whereSeparator: \.isWhitespace) {
            if cur.count + word.count + 1 > 170, !cur.isEmpty { pages.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : " ") + word
            if cur.count > 110, let c = word.last, ".!?:".contains(c) { pages.append(cur); cur = "" }  // end on a sentence
        }
        if !cur.isEmpty { pages.append(cur) }
        return pages
    }

    // Replies type out like the agent is talking; everything else appears at once.
    func show(_ text: String, typed: Bool) {
        guard text != shown else { return }
        shown = text
        typer?.invalidate()
        guard typed else { info.attributedStringValue = styled(text); return }
        let chars = Array(text)
        var n = 0
        typer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { t in
            MainActor.assumeIsolated {
                n = min(n + 3, chars.count)
                self.info.attributedStringValue = self.styled(String(chars[..<n]))
                if n == chars.count { t.invalidate() }
            }
        }
    }

    func styled(_ s: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2.5
        p.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: s, attributes: [.font: info.font!, .foregroundColor: info.textColor!, .paragraphStyle: p])
    }

    @objc func prevPage() { page = max(page - 1, 0); refresh() }
    @objc func nextPage() { page = min(page + 1, pages.count - 1); refresh() }

    func mouseMoved() {
        guard panel.isVisible else { return }
        let p = NSEvent.mouseLocation
        // Closed, only the notch itself (and just below it) opens it, not the menu bar beside it.
        let f = screen.frame
        let hot = expanded ? panel.frame.insetBy(dx: -10, dy: -10)
            : NSRect(x: f.midX - notchWidth / 2, y: f.maxY - strip - 12, width: notchWidth, height: strip + 12)
        let h = hot.contains(p)
        if h != hovering { hovering = h; refresh() }
        let g = !expanded && panel.frame.contains(p)
        if g != ghost { ghost = g; fade() }
        // Eyes follow the cursor (unless busy looking around or bouncing).
        guard mood == "waiting" || mood == "idle" else { return }
        let c = panel.convertPoint(toScreen: content.convert(NSPoint(x: head.frame.midX, y: head.frame.midY), to: nil))
        let dx = p.x - c.x, dy = p.y - c.y, d = max(hypot(dx, dy), 1), k = min(d / 150, 1) * (expanded ? 5 : 2.5)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        gaze.transform = CATransform3DMakeTranslation(dx / d * k, -dy / d * k, 0)  // content is flipped
        CATransaction.commit()
    }

    @objc func sendChat() {
        let t = chat.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        app.queue(t)
        chat.stringValue = ""
        panel.makeFirstResponder(nil)
        say("Got it! On my way 🚀")
    }

    // Solid, except 80% transparent while the cursor is over the closed pill (to see the menu bar under it).
    func fade() {
        let a: CGFloat = ghost && !expanded ? 0.2 : 1
        guard panel.alphaValue != a else { return }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = a }
    }

    func say(_ s: String) { reaction = s; reactUntil = Date().addingTimeInterval(2.5); refresh() }

    // Poke the agent: it hops, squints happily and sends a heart.
    func react() {
        say(["Hehe, that tickles! 😆", "Boop! 👉👈", "I'm on it, boss! 💪", "Need anything? 💬",
             "Beep boop 🤖", "You're doing great! 🌟"].randomElement()!)
        let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hop.values = [0, -9, 0, -4, 0]
        hop.keyTimes = [0, 0.3, 0.55, 0.75, 1]
        hop.duration = 0.6
        head.add(hop, forKey: "hop")
        let squint = CAKeyframeAnimation(keyPath: "transform.scale.y")
        squint.values = [1, 0.25, 0.25, 1]
        squint.keyTimes = [0, 0.15, 0.8, 1]
        squint.duration = 0.8
        eyes.forEach { $0.add(squint, forKey: "squint") }

        let heart = CALayer()
        heart.contents = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            ("💖" as NSString).draw(in: r, withAttributes: [.font: NSFont.systemFont(ofSize: 14)]); return true
        }
        heart.frame = CGRect(x: head.frame.maxX - 16, y: head.frame.minY, width: 18, height: 18)
        content.layer?.addSublayer(heart)
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.1)
        CATransaction.setCompletionBlock { heart.removeFromSuperlayer() }
        heart.position.y -= expanded ? 34 : 0
        heart.position.x += 6
        heart.opacity = 0
        CATransaction.commit()
    }

    func setMood(_ m: String) {
        guard m != mood else { return }
        mood = m
        let color: NSColor = ["approval": .systemOrange, "waiting": .systemGreen, "working": .white][m] ?? .gray
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for e in eyes {
            e.backgroundColor = color.cgColor
            e.transform = CATransform3DMakeScale(1, m == "idle" ? 0.3 : 1, 1)  // sleepy when idle
        }
        dot.backgroundColor = color.cgColor
        gaze.transform = CATransform3DIdentity
        CATransaction.commit()
        face.removeAllAnimations()
        let a: CABasicAnimation
        switch m {
        case "working":  // looks around while it thinks
            a = CABasicAnimation(keyPath: "transform.translation.x")
            a.fromValue = -3; a.toValue = 3; a.duration = 0.9
        case "approval":  // bounces for attention
            a = CABasicAnimation(keyPath: "transform.translation.y")
            a.fromValue = 0; a.toValue = 3; a.duration = 0.22
        default:
            return
        }
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        face.add(a, forKey: "mood")
    }

    func blink() {
        guard mood != "idle" else { return }
        let b = CAKeyframeAnimation(keyPath: "transform.scale.y")
        b.values = [1, 0.1, 1]
        b.duration = 0.18
        eyes.forEach { $0.add(b, forKey: "blink") }
    }
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
    var reqID = "", answered = "", lastLog = "", lastReply = "", note = ""
    var noteUntil = Date.distantPast
    lazy var notch = Notch(app: self)
    var activity: NSObjectProtocol?
    var notchMode = false

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

        let toggle = NSButton(title: "Notch", target: self, action: #selector(toggleNotch))
        toggle.toolTip = "Hide this window and live in the MacBook notch instead"
        let top = NSStackView(views: [status, toggle])
        top.alignment = .top
        status.setContentHuggingPriority(.init(1), for: .horizontal)
        status.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [top, scroll, reqBox, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        panel.contentView = stack
        for v in [top, scroll, reqBox, row] as [NSView] {
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
        // The hooks treat a stale heartbeat as "window closed": keep it beating while the mouse is held down
        // (common run loop modes) and when macOS would otherwise App Nap this background app.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Heartbeat for Claude Code hooks")
        RunLoop.main.add(Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { self.tick() } },
                         forMode: .common)
        if CommandLine.arguments.contains("--notch") { toggleNotch() }
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
            let (l, r) = tail(t)
            lastReply = r
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
        if notchMode {
            notch.update(status: s["status"] as? String ?? "", note: Date() < noteUntil ? note : nil,
                         request: reqBox.isHidden ? nil : reqLabel.stringValue,
                         last: lastLog.components(separatedBy: "\n\n").last ?? "", reply: lastReply)
        }
    }

    @objc func toggleNotch() {
        notchMode.toggle()
        if notchMode { panel.orderOut(nil); notch.show(); tick() } else { notch.hide(); panel.orderFrontRegardless() }
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
        queue(t)
        input.string = ""
        fitInput()
        status.stringValue = "✉︎ Sent — Claude picks it up when its current turn ends"
    }

    func queue(_ t: String) {  // the Stop hook hands it to Claude
        let old = (try? String(contentsOf: url("inbox.txt"), encoding: .utf8)) ?? ""
        try? (old + t + "\n").write(to: url("inbox.txt"), atomically: true, encoding: .utf8)
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
    return m.map { Date().timeIntervalSince($0) < 10 } ?? false  // closing deletes the file, so this only matters on a crash
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
    case "PostToolUse":
        rm("request.json")  // answered in the terminal / VS Code panel instead: clear it from the window
    case "UserPromptSubmit":
        rm("request.json")
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
        rm("request.json")
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

// `ClaudePiP open [notch]`: start the window as its own background process and return at once,
// so /pip needs no `&` (Claude Code's permission check rejects background operators).
if CommandLine.arguments.dropFirst().first == "open" {
    let notch = CommandLine.arguments.contains("notch")
    if alive() { print("The PiP window is already open."); exit(0) }
    let p = Process()
    p.executableURL = Bundle.main.executableURL
    p.arguments = notch ? ["--notch"] : []
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { print("Couldn't open the PiP window: \(error)"); exit(1) }
    print(notch ? "The notch agent is open: hover over the notch to chat, approve or decline."
                : "The PiP window is open: approve/decline and send instructions from it. Close it to return control here.")
    exit(0)
}

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

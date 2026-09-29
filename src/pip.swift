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

// Parent of a process (0 if unknown).
func parentPID(_ pid: pid_t) -> pid_t {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    return sysctl(&mib, 4, &info, &size, nil, 0) == 0 ? info.kp_eproc.e_ppid : 0
}

// The app the Claude process runs in (VS Code, Terminal, iTerm…): its first ancestor with a Dock icon.
func hostApp(of pid: pid_t) -> NSRunningApplication? {
    var p = pid
    for _ in 0..<16 where p > 1 {
        if let a = NSRunningApplication(processIdentifier: p), a.activationPolicy == .regular { return a }
        p = parentPID(p)
    }
    return nil
}

// MARK: notch mode: a cute agent living in the MacBook notch. Hover to open it: status, approvals, chat box.

final class Flipped: NSView { override var isFlipped: Bool { true } }

final class Tap: NSView {
    var onClick: (NSPoint, Int) -> Void = { _, _ in }  // point, click count
    var hand = false
    override func mouseDown(with e: NSEvent) { onClick(convert(e.locationInWindow, from: nil), e.clickCount) }
    override func resetCursorRects() { if hand { addCursorRect(bounds, cursor: .pointingHand) } }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}

// A cartoon human eye: white eyeball, colored iris with pupil and sparkle, eyelids, a brow and a blush.
// Animation notes: brows travel with the lids and a beat apart from each other; blinks close fast, hold,
// and open slower; gaze moves in quick saccades with holds (not smooth sweeps).
@MainActor final class Eye {
    let side: CGFloat                             // -1 left eye, +1 right eye
    let ball = CALayer()                          // the white of the eye; clips everything inside
    let iris = CALayer(), pupil = CALayer(), glint = CALayer()
    let lid = CALayer()                           // top lid: its bottom edge slides down to blink or close
    let lower = CAShapeLayer()                    // bottom lid: curves up for smiling eyes
    let lash = CAShapeLayer()                     // lash line, shown when closed
    let brow = CAShapeLayer(), blush = CALayer()  // outside the eyeball (open notch only)

    init(side: CGFloat) {
        self.side = side
        ball.masksToBounds = true
        ball.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        pupil.backgroundColor = NSColor.black.cgColor
        glint.backgroundColor = NSColor.white.cgColor
        iris.addSublayer(pupil)
        iris.addSublayer(glint)
        lid.anchorPoint = CGPoint(x: 0.5, y: 1)
        lash.fillColor = nil
        lash.lineCap = .round
        lash.strokeColor = NSColor(white: 0.8, alpha: 1).cgColor
        for l in [iris, lid, lower, lash] as [CALayer] { ball.addSublayer(l) }
        brow.fillColor = nil
        brow.lineCap = .round
        brow.strokeColor = NSColor(white: 0.9, alpha: 1).cgColor
        blush.backgroundColor = NSColor.systemPink.withAlphaComponent(0.55).cgColor
        blush.opacity = 0
    }

    func layout(width w: CGFloat, height h: CGFloat, skin: CGColor, at c: CGPoint, extras: Bool) {
        ball.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        ball.cornerRadius = w / 2
        ball.position = c
        let d = w * 0.66
        iris.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        iris.cornerRadius = d / 2
        iris.position = CGPoint(x: w / 2, y: h / 2)
        pupil.bounds = CGRect(x: 0, y: 0, width: d * 0.46, height: d * 0.46)
        pupil.cornerRadius = d * 0.23
        pupil.position = CGPoint(x: d / 2, y: d / 2)
        glint.bounds = CGRect(x: 0, y: 0, width: d * 0.26, height: d * 0.26)
        glint.cornerRadius = d * 0.13
        glint.position = CGPoint(x: d * 0.34, y: d * 0.32)
        lid.bounds = CGRect(x: 0, y: 0, width: w * 1.8, height: h * 1.4)
        lid.backgroundColor = skin
        lower.frame = ball.bounds
        lower.fillColor = skin
        lash.frame = ball.bounds
        lash.lineWidth = max(1.5, w * 0.16)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: w * 0.08, y: h * 0.45))
        p.addQuadCurve(to: CGPoint(x: w * 0.92, y: h * 0.45), control: CGPoint(x: w / 2, y: h * 0.78))
        lash.path = p
        brow.bounds = CGRect(x: 0, y: 0, width: w * 1.05, height: h * 0.34)
        brow.position = CGPoint(x: c.x, y: c.y - h * 0.8)
        brow.lineWidth = max(1.5, w * 0.12)
        blush.bounds = CGRect(x: 0, y: 0, width: w * 0.8, height: h * 0.26)
        blush.cornerRadius = h * 0.13
        blush.position = CGPoint(x: c.x + side * w * 0.12, y: c.y + h * 0.66)
        brow.isHidden = !extras
        blush.isHidden = !extras
    }

    // open: 0 = lid up, 1 = closed · tilt: lid angle (worried) · wide: surprised · smile: happy lower lid
    // pupil: dilation (big = delighted, small = startled) · brow: raise, inner-end lift, arch · blushing
    func set(open: CGFloat, tilt: CGFloat = 0, wide: Bool = false, smile: Bool = false, pupil dilation: CGFloat = 1,
             color: NSColor, brow b: (raise: CGFloat, inner: CGFloat, arch: CGFloat) = (0, 0, 0.4), blushing: Bool = false) {
        let w = ball.bounds.width, h = ball.bounds.height
        lid.position = CGPoint(x: w / 2, y: h * open)
        lid.transform = CATransform3DMakeRotation(tilt, 0, 0, 1)
        ball.transform = wide ? CATransform3DMakeScale(1.12, 1.12, 1) : CATransform3DIdentity
        iris.transform = wide ? CATransform3DMakeScale(0.78, 0.78, 1) : CATransform3DIdentity
        iris.backgroundColor = color.cgColor
        pupil.transform = CATransform3DMakeScale(dilation, dilation, 1)
        lash.opacity = open >= 1 ? 1 : 0
        let top = smile ? h * 0.9 : h * 1.3, bend = smile ? h * 0.36 : h * 1.3
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -w * 0.3, y: h * 1.5))
        p.addLine(to: CGPoint(x: -w * 0.3, y: top))
        p.addQuadCurve(to: CGPoint(x: w * 1.3, y: top), control: CGPoint(x: w / 2, y: bend))
        p.addLine(to: CGPoint(x: w * 1.3, y: h * 1.5))
        p.closeSubpath()
        lower.path = p
        let bw = brow.bounds.width, bh = brow.bounds.height, q = CGMutablePath()
        q.move(to: CGPoint(x: 0, y: bh * 0.8))
        q.addQuadCurve(to: CGPoint(x: bw, y: bh * 0.8), control: CGPoint(x: bw / 2, y: bh * 0.8 - bh * 1.3 * b.arch))
        brow.path = q
        brow.transform = CATransform3DRotate(CATransform3DMakeTranslation(0, -b.raise * h * 0.1, 0), side * b.inner, 0, 0, 1)
        blush.opacity = blushing ? 1 : 0
    }

    // Where the iris looks: x, y in -1...1.
    func look(_ x: CGFloat, _ y: CGFloat) {
        let w = ball.bounds.width, h = ball.bounds.height, d = iris.bounds.width
        iris.position = CGPoint(x: w / 2 + x * (w - d) / 2 * 0.9, y: h / 2 + y * (h - d) / 2 * 0.9)
    }

    // Fast close, short hold, slower open; the brow dips with the lid.
    func blink(duration: CFTimeInterval = 0.2) {
        let b = CAKeyframeAnimation(keyPath: "position.y")
        b.values = [lid.position.y, ball.bounds.height * 1.02, ball.bounds.height * 1.02, lid.position.y]
        b.keyTimes = [0, 0.3, 0.42, 1]
        b.duration = duration
        lid.add(b, forKey: "blink")
        let dip = CAKeyframeAnimation(keyPath: "transform.translation.y")
        dip.values = [0, ball.bounds.height * 0.06, 0]
        dip.duration = duration
        dip.isAdditive = true
        brow.add(dip, forKey: "blink")
    }
}

@MainActor final class Notch: NSObject {
    unowned let app: App
    let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let bg = NSView(), content = Flipped(), tap = Tap()
    // head (the agent's body) > face (mood motion) > gaze (holds the eyes) > eyes (lids, irises)
    let head = CALayer(), face = CALayer(), gaze = CALayer(), eyes = [Eye(side: -1), Eye(side: 1)], dot = CALayer()
    var pinned = false  // --pin: stay open (demos, screenshots)
    var zzz: Timer?, awakeUntil = Date.distantPast
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
        pageTap.onClick = { [unowned self] p, _ in p.x < pageTap.bounds.midX ? prevPage() : nextPage() }
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
        for e in eyes { [e.blush, e.ball, e.brow].forEach(gaze.addSublayer) }
        face.addSublayer(gaze)
        head.addSublayer(face)
        dot.cornerRadius = 4
        content.layer?.addSublayer(head)
        content.layer?.addSublayer(dot)
        tap.onClick = { [unowned self] _, clicks in mood == "idle" && clicks >= 2 ? wake() : react() }
        tap.toolTip = "Poke me! (double-click to wake me up)"

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
        scheduleBlink()
        scheduleGaze()
        breathe()
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
        let (ew, eh, gap): (CGFloat, CGFloat, CGFloat) = expanded ? (22, 26, 7) : (10, 13, 4)
        head.frame = expanded ? CGRect(x: 18, y: strip + 12, width: 72, height: 72) : CGRect(x: 14, y: 0, width: 30, height: strip)
        head.backgroundColor = NSColor(white: expanded ? 0.16 : 0, alpha: expanded ? 1 : 0).cgColor
        face.frame = head.bounds
        gaze.bounds = CGRect(x: 0, y: 0, width: ew * 2 + gap, height: eh)  // gaze carries the mouse-follow transform
        gaze.position = CGPoint(x: head.bounds.midX, y: head.bounds.midY - (expanded ? 6 : 0))
        let skin = NSColor(white: expanded ? 0.16 : 0, alpha: 1).cgColor  // eyelids match the face around them
        for (i, e) in eyes.enumerated() {
            e.layout(width: ew, height: eh, skin: skin, at: CGPoint(x: CGFloat(i) * (ew + gap) + ew / 2, y: eh / 2),
                     extras: expanded)
        }
        express()
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
        let m = request != nil ? "approval" : status == "working" ? "working" : status == "stopping" ? "stopping"
            : status.hasPrefix("waiting") ? "waiting" : Date() < awakeUntil ? "awake" : "idle"
        setMood(m)
        title.stringValue = Date() < reactUntil ? reaction : note ?? [
            "approval": "Claude needs your OK 👀", "working": "Working on it…",
            "waiting": "Done! What's next? ✨", "stopping": "Stopping… 😟",
            "awake": "I'm up! ☀️ Type anything in Claude to reconnect me",
            "idle": "Napping… 💤 double-click me to wake up"][m]!
        // Done: Claude's reply, a page at a time. Otherwise: the request, or what Claude is doing.
        let talking = m == "waiting" && !pages.isEmpty
        show(request ?? (talking ? pages[page] : last), typed: talking)
        let typing = panel.isKeyWindow && chat.currentEditor() != nil
        let open = pinned || hovering || typing || request != nil || Date() < popUntil
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
        // Irises follow the cursor when the agent is looking at you (it glances away now and then).
        guard followCursor, Date() > glanceUntil else { return }
        let c = panel.convertPoint(toScreen: content.convert(NSPoint(x: head.frame.midX, y: head.frame.midY), to: nil))
        let dx = p.x - c.x, dy = p.y - c.y, d = max(hypot(dx, dy), 1), k = min(d / 200, 1)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        eyes.forEach { $0.look(dx / d * k, -dy / d * k) }  // content is flipped
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
        eyes.forEach {  // delighted for a moment: smiling eyes, big pupils, raised brows, blush
            $0.set(open: 0, smile: true, pupil: 1.35, color: .systemPink, brow: (2.5, 0.1, 0.9), blushing: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in express() }

        let heart = CALayer()
        heart.contents = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            ("💖" as NSString).draw(in: r, withAttributes: [.font: NSFont.systemFont(ofSize: 14)]); return true
        }
        heart.frame = CGRect(x: head.frame.maxX - 16, y: head.frame.minY, width: 18, height: 18)
        floatAway(heart, dx: 6, dy: expanded ? -34 : -8, duration: 1.1)
    }

    // Add a layer and let it drift and fade out. Explicit animations: a layer added in the same
    // transaction wouldn't animate implicitly (it would jump straight to invisible).
    func floatAway(_ l: CALayer, dx: CGFloat, dy: CGFloat, duration: CFTimeInterval) {
        content.layer?.addSublayer(l)
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: l.position)
        move.toValue = NSValue(point: CGPoint(x: l.position.x + dx, y: l.position.y + dy))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [move, fade]
        g.duration = duration
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.opacity = 0
        l.add(g, forKey: "float")
        CATransaction.commit()
    }

    // Each mood is a look in the eyes (lids, iris color, blink pace) and a motion. The eyes do the talking.
    func setMood(_ m: String) {
        guard m != mood else { return }
        mood = m
        let color: NSColor = ["approval": .systemOrange, "waiting": .systemGreen, "working": .white,
                              "stopping": .systemRed, "awake": .white][m] ?? .gray
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        express()
        dot.backgroundColor = color.cgColor
        CATransaction.commit()
        face.removeAllAnimations()
        zzz?.invalidate()
        let a = CAKeyframeAnimation()
        switch m {
        case "approval":  // surprise: anticipation squint, pop wide with overshoot, settle; then bounce
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [1, 0.85, 1.28, 1.12]
            pop.keyTimes = [0, 0.3, 0.7, 1]
            pop.duration = 0.35
            eyes.forEach { $0.ball.add(pop, forKey: "pop") }
            a.keyPath = "transform.translation.y"; a.values = [0, 3, 0]; a.duration = 0.44
        case "stopping":  // worried little shake and a sweat drop
            a.keyPath = "transform.translation.x"; a.values = [0, -2, 2, -2, 2, 0]; a.duration = 0.5
            let drop = CALayer()
            drop.contents = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
                ("💧" as NSString).draw(in: r, withAttributes: [.font: NSFont.systemFont(ofSize: 11)]); return true
            }
            drop.frame = CGRect(x: head.frame.maxX - 12, y: head.frame.minY + 2, width: 14, height: 14)
            floatAway(drop, dx: 2, dy: expanded ? 22 : 6, duration: 1.4)
        case "waiting":  // happy hop, once
            a.keyPath = "transform.translation.y"; a.values = [0, -6, 0, -2, 0]; a.duration = 0.6
            face.add(a, forKey: "mood")
            return
        case "idle":  // dozes off: a few heavy, drowsy half-blinks, then sleeps; little z's float up
            eyes.forEach { e in
                let h = e.ball.bounds.height, doze = CAKeyframeAnimation(keyPath: "position.y")
                doze.values = [0.1, 0.65, 0.25, 0.8, 0.45, 1.02].map { $0 * h }
                doze.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
                doze.duration = 2.4
                e.lid.add(doze, forKey: "doze")
            }
            zzz = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { _ in MainActor.assumeIsolated { self.snore() } }
            return
        default:
            return
        }
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        face.add(a, forKey: "mood")
    }

    // The look for the current mood: lids, iris color, pupils, brows (the second brow a beat later).
    func express() {
        let iris: NSColor = ["approval": .systemOrange, "waiting": .systemGreen, "stopping": .systemRed,
                             "idle": .gray][mood] ?? .systemBlue
        for (i, e) in eyes.enumerated() {
            let apply = {
                switch self.mood {
                case "idle":      // asleep: relaxed, low brows
                    e.set(open: 1, color: iris, brow: (-1, 0, 0.3))
                case "approval":  // surprised: wide, pinpoint pupils, brows high and arched
                    e.set(open: -0.05, wide: true, pupil: 0.65, color: iris, brow: (2.2, 0.05, 1))
                case "waiting":   // happy: smiling eyes, big pupils, soft raised brows, a little blush
                    e.set(open: 0.05, smile: true, pupil: 1.2, color: iris, brow: (2, 0.05, 0.8), blushing: true)
                case "stopping":  // worried: droopy lids, inner brow ends up
                    e.set(open: 0.3, tilt: i == 0 ? -0.3 : 0.3, pupil: 0.85, color: iris, brow: (2, 0.4, 0.2))
                case "working":   // focused: lids a little low, brows down and drawn in
                    e.set(open: 0.18, color: iris, brow: (-1.2, -0.22, 0.25))
                default:          // awake and curious
                    e.set(open: 0.02, pupil: 1.1, color: iris, brow: (3, 0.1, 0.7))
                }
            }
            if i == 0 { apply() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { apply() } }
        }
    }

    // Gaze in saccades: quick jumps with holds. Working: scanning down and across, like reading.
    // Needs you / done: looking at you (the cursor), with a glance away now and then. Stopping: nervous darts.
    var followCursor: Bool { ["approval", "waiting"].contains(mood) }
    func scheduleGaze() {
        let (lo, hi): (Double, Double) = ["working": (0.25, 1.1), "stopping": (0.15, 0.45), "awake": (0.3, 0.8)][mood] ?? (3.5, 7)
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: lo...hi)) { [self] in
            switch mood {
            case "working": saccade(.random(in: -0.9...0.9), .random(in: -0.1...0.8))
            case "stopping": saccade(.random(in: -0.9...0.9), .random(in: -0.3...0.3))
            case "awake": saccade(.random(in: -1...1), .random(in: -0.8...0.5))
            case "approval", "waiting":  // glance away briefly, then back at you
                glanceUntil = Date().addingTimeInterval(.random(in: 0.5...1.1))
                saccade(.random(in: -0.9...0.9), .random(in: -0.6...0.2))
            default: break
            }
            scheduleGaze()
        }
    }

    var gazeAt = CGPoint.zero, glanceUntil = Date.distantPast
    func saccade(_ x: CGFloat, _ y: CGFloat) {
        let far = hypot(x - gazeAt.x, y - gazeAt.y) > 1
        gazeAt = CGPoint(x: x, y: y)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.05)  // saccades are fast
        eyes.forEach { $0.look(x, y) }
        CATransaction.commit()
        if far, Double.random(in: 0...1) < 0.3 { eyes.forEach { $0.blink() } }  // big eye jumps often come with a blink
    }

    // Always a little alive: a slow, subtle breath.
    func breathe() {
        let b = CABasicAnimation(keyPath: "transform.scale")
        b.fromValue = 1
        b.toValue = 1.025
        b.duration = 1.8
        b.autoreverses = true
        b.repeatCount = .infinity
        b.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gaze.add(b, forKey: "breathe")
    }

    func snore() {
        let z = CATextLayer()
        z.string = "z"
        z.fontSize = expanded ? 14 : 9
        z.foregroundColor = NSColor.white.withAlphaComponent(0.7).cgColor
        z.contentsScale = panel.backingScaleFactor
        z.frame = CGRect(x: head.frame.maxX - (expanded ? 10 : 4), y: head.frame.minY + (expanded ? 4 : 8), width: 14, height: 16)
        floatAway(z, dx: 8, dy: expanded ? -22 : -10, duration: 1.5)
    }

    // Double-click while napping: wake up and bring the Claude app forward. An idle Claude session
    // can't be restarted from outside; one message typed there reconnects the agent.
    func wake() {
        awakeUntil = Date().addingTimeInterval(12)
        refresh()
        let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hop.values = [0, -10, 0]
        hop.duration = 0.4
        head.add(hop, forKey: "wake")
        guard let pid = readJSON("session.json")["pid"] as? Int, let host = hostApp(of: pid_t(pid)) else { return }
        host.activate()
    }

    // Natural, random blinking whose pace follows the mood; sometimes a double blink.
    func scheduleBlink() {
        let (lo, hi, double): (Double, Double, Double) = [
            "approval": (1.2, 3, 0.5), "stopping": (0.8, 2, 0.35), "waiting": (3, 6, 0.1), "awake": (1, 2.5, 0.3),
        ][mood] ?? (2.5, 5.5, 0.15)
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: lo...hi)) { [self] in
            if mood != "idle" {  // asleep: no blinking
                eyes.forEach { $0.blink() }
                if Double.random(in: 0...1) < double {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [self] in eyes.forEach { $0.blink() } }
                }
            }
            scheduleBlink()
        }
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
        if CommandLine.arguments.contains("--pin") { notch.pinned = true; tick() }
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

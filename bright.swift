// bright: extra brightness for the built-in XDR screen, from the terminal.
//
// Minimal rewrite of the gamma technique from BrightIntosh by Niklas Rousset
// (https://github.com/niklasr22/BrightIntosh, GPL-3.0), so this file is GPL-3.0 too.
// A one-pixel window asks macOS for the panel's HDR range, then the display's gamma
// table is scaled up so everything on screen uses part of that range. Off and normal
// quits restore the table. macOS also resets it if the process is killed.
//
// Build: swiftc -O bright.swift -o bright

import Cocoa
import MetalKit

// MARK: - State on disk

let stateDir = NSHomeDirectory() + "/Library/Application Support/bright"
let lockPath = stateDir + "/lock"
let pidPath = stateDir + "/pid"
let levelPath = stateDir + "/level"

func readLevel() -> Int {
    let text = try? String(contentsOfFile: levelPath, encoding: .utf8)
    let value = text.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 100
    return min(max(value, 0), 100)
}

func writeLevel(_ level: Int) {
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    try? String(min(max(level, 0), 100)).write(toFile: levelPath, atomically: true, encoding: .utf8)
}

/// The daemon holds an flock for as long as it lives, so a stale pid file can never lie.
func daemonPid() -> pid_t? {
    let fd = open(lockPath, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { return nil }
    let text = try? String(contentsOfFile: pidPath, encoding: .utf8)
    return text.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

// MARK: - Brightness

func displayId(_ screen: NSScreen) -> CGDirectDisplayID? {
    screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
}

func builtInScreen() -> NSScreen? {
    NSScreen.screens.first { displayId($0).map { CGDisplayIsBuiltin($0) != 0 } ?? false }
}

/// BrightIntosh's reference values for 600-nit SDR MacBook Pros (M3 and M4 families),
/// and its fallback for the older 500-nit ones.
func referenceValues() -> (edr: Double, bonus: Double) {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var raw = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("hw.model", &raw, &size, nil, 0)
    return String(cString: raw).hasPrefix("MacBookPro18,") || String(cString: raw).hasPrefix("Mac14,")
        ? (3.2, 0.59)
        : (2.66, 0.50)
}

/// BrightIntosh's formula: the more headroom the panel has left, the smaller the boost.
func factor(level: Int, maxEDR: Double) -> Float {
    guard maxEDR > 1.05 else { return 1 }  // HDR not active yet, so a boost would only clip
    let (referenceEDR, bonus) = referenceValues()
    let clamped = min(max(maxEDR, referenceEDR), 16)
    let full = 1 + bonus * (1 - (clamped - referenceEDR) / (16 - referenceEDR))
    return Float(1 + (full - 1) * Double(level) / 100)
}

// MARK: - Gamma

struct Gamma {
    static let size: UInt32 = 256
    var red = [CGGammaValue](repeating: 0, count: Int(size))
    var green = [CGGammaValue](repeating: 0, count: Int(size))
    var blue = [CGGammaValue](repeating: 0, count: Int(size))

    static func current(_ id: CGDirectDisplayID) -> Gamma? {
        var table = Gamma()
        var count: UInt32 = 0
        let result = CGGetDisplayTransferByTable(id, size, &table.red, &table.green, &table.blue, &count)
        return result == .success ? table : nil
    }

    func apply(_ id: CGDirectDisplayID, factor: Float) {
        let r = red.map { $0 * factor }, g = green.map { $0 * factor }, b = blue.map { $0 * factor }
        CGSetDisplayTransferByTable(id, Gamma.size, r, g, b)
    }
}

// MARK: - HDR trigger

/// One pixel brighter than white in a corner of the screen. It asks macOS for the HDR range.
final class Trigger: MTKView, MTKViewDelegate {
    private let queue: MTLCommandQueue

    init(frame: CGRect, device: MTLDevice, queue: MTLCommandQueue) {
        self.queue = queue
        super.init(frame: frame, device: device)
        autoResizeDrawable = false
        drawableSize = CGSize(width: 1, height: 1)
        delegate = self
        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        clearColor = MTLClearColorMake(1.6, 1.6, 1.6, 1)
        preferredFramesPerSecond = 5
        guard let layer = layer as? CAMetalLayer else { return }
        layer.wantsExtendedDynamicRangeContent = true
        layer.isOpaque = false
        layer.pixelFormat = .rgba16Float
    }

    required init(coder: NSCoder) { fatalError("unused") }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

// MARK: - Daemon

final class Daemon: NSObject, NSApplicationDelegate {
    private let fadeDuration = 0.2
    private let settleDelay = 1.5  // brightening waits for the panel's headroom to stop moving
    private let epsilon: Float = 0.002

    private var window: NSWindow?
    private var displayID: CGDirectDisplayID?
    private var frame = NSRect.zero
    private var base: Gamma?
    private var level = readLevel()
    private var applied: Float = 1
    private var target: Float = 1
    private var pending: (factor: Float, since: Date)?
    private var fadeImmediately = true
    private var fadeTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        syncScreen()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.syncScreen()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.syncScreen()
        }

        // `bright set N` writes the level file and pokes us with SIGUSR1.
        onSignal(SIGUSR1) { [weak self] in
            self?.level = readLevel()
            self?.fadeImmediately = true
            self?.tick()
        }
        // `bright off` arrives as SIGTERM.
        onSignal(SIGTERM) {
            CGDisplayRestoreColorSyncSettings()
            exit(0)
        }
    }

    private func onSignal(_ number: Int32, _ handler: @escaping () -> Void) {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        signalSources.append(source)
    }

    /// Screen parameters also change on a plain brightness change, so only rebuild when
    /// the display itself changed. Rebuilding would drop HDR and make the screen jump.
    private func syncScreen() {
        let screen = builtInScreen()
        let id = screen.flatMap(displayId)
        if let screen, id == displayID, screen.frame == frame {
            window?.setFrameOrigin(triggerOrigin(screen))
            window?.orderFrontRegardless()
            tick()
            return
        }

        fadeTimer?.invalidate()
        fadeTimer = nil
        window?.orderOut(nil)
        window = nil
        if displayID != nil { CGDisplayRestoreColorSyncSettings() }
        displayID = nil
        base = nil
        applied = 1
        target = 1
        pending = nil
        fadeImmediately = true

        guard let screen, let id,
              let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let table = Gamma.current(id)
        else { return }

        let rect = NSRect(origin: triggerOrigin(screen), size: NSSize(width: 1, height: 1))
        let win = NSWindow(contentRect: rect, styleMask: [], backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        win.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        win.canHide = false
        win.isOpaque = false
        win.hasShadow = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        win.animationBehavior = .none
        win.contentView = Trigger(frame: NSRect(x: 0, y: 0, width: 1, height: 1), device: device, queue: queue)
        win.setFrame(rect, display: true)
        win.orderFrontRegardless()

        window = win
        displayID = id
        frame = screen.frame
        base = table
        tick()
    }

    private func triggerOrigin(_ screen: NSScreen) -> NSPoint {
        NSPoint(x: screen.frame.origin.x, y: screen.frame.origin.y + screen.frame.height - 1)
    }

    private func tick() {
        guard let screen = builtInScreen(), let id = displayID, let base else { return }
        let want = factor(level: level, maxEDR: Double(screen.maximumExtendedDynamicRangeColorComponentValue))
        let current = max(applied, target)

        if want > current + epsilon, !fadeImmediately {
            // Brightening: wait until the target has held still.
            if let waiting = pending, abs(waiting.factor - want) <= epsilon {
                if Date().timeIntervalSince(waiting.since) >= settleDelay { fade(to: want, id: id, base: base) }
            } else {
                pending = (want, Date())
            }
        } else {
            pending = nil
            if abs(want - target) > epsilon { fade(to: want, id: id, base: base) }
            if want > 1 { fadeImmediately = false }
        }

        // macOS can reset the table on its own, for example after sleep.
        if fadeTimer == nil, let now = Gamma.current(id), let last = now.red.last, let baseLast = base.red.last,
           abs(last - baseLast * applied) > 0.01 {
            base.apply(id, factor: applied)
        }
    }

    private func fade(to newTarget: Float, id: CGDirectDisplayID, base: Gamma) {
        pending = nil
        target = newTarget
        fadeTimer?.invalidate()
        let from = applied
        let start = Date()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return }
            let progress = min(1, Date().timeIntervalSince(start) / self.fadeDuration)
            let eased = Float(progress * progress * (3 - 2 * progress))
            self.applied = from + (newTarget - from) * eased
            base.apply(id, factor: self.applied)
            if progress >= 1 {
                timer.invalidate()
                self.fadeTimer = nil
            }
        }
    }
}

func runDaemon() -> Never {
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    let lock = open(lockPath, O_CREAT | O_RDWR, 0o644)
    guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }  // already running
    try? String(getpid()).write(toFile: pidPath, atomically: true, encoding: .utf8)

    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)  // no Dock icon, no menu bar
    let daemon = Daemon()
    app.delegate = daemon
    app.run()
    exit(0)
}

// MARK: - Commands

func waitUntil(_ condition: () -> Bool) -> Bool {
    for _ in 0..<40 {
        if condition() { return true }
        usleep(50_000)
    }
    return condition()
}

// launchd owns the daemon, so it is never a child of the terminal and survives it closing.
// This plist is outside ~/Library/LaunchAgents, so on its own it does not start at login.
let jobLabel = "com.peterkun.bright"
let jobDomain = "gui/\(getuid())"
let jobPlist = stateDir + "/\(jobLabel).plist"
let loginAgentsDir = NSHomeDirectory() + "/Library/LaunchAgents"
let loginPlist = loginAgentsDir + "/\(jobLabel).plist"

func writeJob(to plist: String) -> Bool {
    guard let path = Bundle.main.executablePath else { return false }
    let job: [String: Any] = [
        "Label": jobLabel,
        "ProgramArguments": [URL(fileURLWithPath: path).resolvingSymlinksInPath().path, "__daemon"],
        "RunAtLoad": true,
        "ProcessType": "Interactive",
        "LimitLoadToSessionType": "Aqua",
    ]
    guard let data = try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0) else { return false }
    return (try? data.write(to: URL(fileURLWithPath: plist))) != nil
}

// Start at login: the setting is simply whether the login plist exists.
func startsAtLogin() -> Bool {
    FileManager.default.fileExists(atPath: loginPlist)
}

func setStartsAtLogin(_ enabled: Bool) -> Bool {
    if enabled {
        try? FileManager.default.createDirectory(atPath: loginAgentsDir, withIntermediateDirectories: true)
        return writeJob(to: loginPlist)
    }
    if !startsAtLogin() { return true }
    return (try? FileManager.default.removeItem(atPath: loginPlist)) != nil
}

/// Changes the setting, then checks the file on disk before reporting what happened.
func changeStartsAtLogin(_ enabled: Bool) -> (ok: Bool, message: String) {
    let before = startsAtLogin()
    let written = setStartsAtLogin(enabled)
    guard written, startsAtLogin() == enabled else { return (false, "could not change it") }
    if before == enabled { return (true, "already \(enabled ? "on" : "off")") }
    return (true, enabled ? "added: starts at next login" : "removed: won't start at next login")
}

@discardableResult
func launchctl(_ arguments: String...) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

func turnOn() -> Bool {
    if daemonPid() != nil { return true }
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    guard writeJob(to: jobPlist) else { return false }
    if startsAtLogin() { _ = writeJob(to: loginPlist) }  // keep the path right if the binary moved
    launchctl("bootout", "\(jobDomain)/\(jobLabel)")  // a job left loaded after a crash blocks bootstrap
    return waitUntil { daemonPid() != nil || launchctl("bootstrap", jobDomain, jobPlist) == 0 && daemonPid() != nil }
        || waitUntil { daemonPid() != nil }
}

func turnOff() {
    launchctl("bootout", "\(jobDomain)/\(jobLabel)")
    if let pid = daemonPid() { kill(pid, SIGTERM) }  // a daemon from before the launchd version
    _ = waitUntil { daemonPid() == nil }
}

func setLevel(_ level: Int) {
    writeLevel(level)
    if let pid = daemonPid() { kill(pid, SIGUSR1) }
}

func printStatus() {
    let running = daemonPid() != nil
    let level = readLevel()
    print("bright: \(running ? "on" : "off"), level \(level)%")
    print("start at login: \(startsAtLogin() ? "on" : "off")")
    guard let screen = builtInScreen() else {
        print("built-in screen: not active (lid closed?)")
        return
    }
    let maxEDR = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
    let potential = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
    print(String(format: "HDR headroom now: %.2fx (panel potential %.2fx)", maxEDR, potential))
    if running, let id = displayId(screen), let table = Gamma.current(id), let last = table.red.last {
        print(String(format: "gamma boost now: %.2fx", last))
    }
    if potential <= 1 { print("This screen has no HDR range, so bright can't do anything here.") }
}

let usage = """
bright: extra brightness for the built-in XDR screen

  bright             small interactive panel
  bright on [0-100]  turn on, optionally at a level
  bright off         turn off (screen goes straight back to normal)
  bright toggle      flip on/off
  bright set 0-100   change the level
  bright status      show state and HDR headroom
  bright login       show whether it starts at login
  bright login on    start at login
  bright login off   don't start at login
"""

// MARK: - Terminal panel

func runPanel() {
    var original = termios()
    tcgetattr(STDIN_FILENO, &original)
    var raw = original
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    print("\u{1B}[?25l", terminator: "")  // hide cursor
    defer {
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
        print("\u{1B}[?25h\u{1B}[2B\r", terminator: "\n")
    }

    let width = 20
    var notice = ""
    func render() {
        let on = daemonPid() != nil
        let level = readLevel()
        let filled = level * width / 100
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
        let state = on ? "\u{1B}[1;33mON \u{1B}[0m" : "\u{1B}[2mOFF\u{1B}[0m"
        let login = startsAtLogin() ? "\u{1B}[1;33mON \u{1B}[0m" : "\u{1B}[2mOFF\u{1B}[0m"
        print("\r\u{1B}[2K  bright  \(state)  \(bar)  \(level)%\r\n\r\u{1B}[2K  start at login  \(login)  \(notice)\r\n\r\u{1B}[2K\u{1B}[2m  space on/off   left/right level   l login   q quit\u{1B}[0m\u{1B}[2A\r", terminator: "")
        fflush(stdout)
    }

    render()
    var byte: UInt8 = 0
    while read(STDIN_FILENO, &byte, 1) == 1 {
        notice = ""
        switch byte {
        case UInt8(ascii: "q"), 3:
            return
        case 27 where !inputPending():  // a lone Esc, not an arrow key
            return
        case UInt8(ascii: " "), 13:
            if daemonPid() != nil { turnOff() } else { _ = turnOn() }
        case UInt8(ascii: "l"):
            notice = changeStartsAtLogin(!startsAtLogin()).message
        case 27:  // arrow keys arrive as ESC [ C / ESC [ D
            var sequence = [UInt8](repeating: 0, count: 2)
            _ = read(STDIN_FILENO, &sequence, 2)
            if sequence[1] == UInt8(ascii: "C") { setLevel(readLevel() + 10) }
            if sequence[1] == UInt8(ascii: "D") { setLevel(readLevel() - 10) }
        default:
            break
        }
        render()
    }
}

func inputPending() -> Bool {
    var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    return poll(&fds, 1, 30) > 0
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())
_ = NSApplication.shared  // NSScreen needs a connection to the window server

func parseLevel(_ text: String?) -> Int? {
    guard let text, let value = Int(text.replacingOccurrences(of: "%", with: "")), (0...100).contains(value) else { return nil }
    return value
}

switch arguments.first {
case "__daemon":
    runDaemon()
case nil:
    if isatty(STDIN_FILENO) == 1 { runPanel() } else { print(usage) }
case "on":
    if arguments.count > 1 {
        guard let level = parseLevel(arguments[1]) else { print(usage); exit(2) }
        setLevel(level)
    }
    guard turnOn() else { print("bright: could not start"); exit(1) }
    printStatus()
case "off":
    turnOff()
    printStatus()
case "toggle":
    if daemonPid() != nil { turnOff() } else { _ = turnOn() }
    printStatus()
case "set":
    guard let level = parseLevel(arguments.dropFirst().first) else { print(usage); exit(2) }
    setLevel(level)
    printStatus()
case "status":
    printStatus()
case "login":
    switch arguments.dropFirst().first {
    case nil:
        print("start at login: \(startsAtLogin() ? "on" : "off")")
    case let value? where value == "on" || value == "off":
        let result = changeStartsAtLogin(value == "on")
        print("start at login: \(startsAtLogin() ? "on" : "off") (\(result.message))")
        if !result.ok { exit(1) }
    default:
        print(usage)
        exit(2)
    }
default:
    print(usage)
    exit(arguments.first == "help" || arguments.first == "--help" || arguments.first == "-h" ? 0 : 2)
}

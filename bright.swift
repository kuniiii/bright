// bright: extra brightness for the built-in XDR screen, from the terminal.
//
// Minimal rewrite of the "multiplying overlay" technique from BrightIntosh by
// Niklas Rousset (https://github.com/niklasr22/BrightIntosh, GPL-3.0), so this
// file is GPL-3.0 too. A fullscreen, click-through window draws one HDR pixel
// stretched over the screen with a "multiply" filter. That switches the panel
// into its HDR range and multiplies everything below it. Gamma is never touched,
// so quitting or crashing puts the screen straight back to normal.
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

/// How much to multiply the screen by. Never above what the panel can show right now,
/// so highlights are not clipped. Stays just over 1 while HDR is engaging, because
/// a pixel above 1.0 is what asks macOS for the HDR range in the first place.
func factor(level: Int, maxEDR: Double) -> Double {
    if level == 0 { return 1.0 }
    let (referenceEDR, bonus) = referenceValues()
    let share = min(maxEDR / referenceEDR, Double(level) / 100)
    return max(1.12, min(1 + bonus * share, maxEDR))
}

// MARK: - Overlay daemon

final class Overlay: MTKView, MTKViewDelegate {
    private let queue: MTLCommandQueue

    init(frame: CGRect, device: MTLDevice, queue: MTLCommandQueue) {
        self.queue = queue
        super.init(frame: frame, device: device)
        autoResizeDrawable = false
        drawableSize = CGSize(width: 1, height: 1)
        delegate = self
        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        preferredFramesPerSecond = 5
        guard let layer = layer as? CAMetalLayer else { return }
        layer.wantsExtendedDynamicRangeContent = true
        layer.isOpaque = false
        layer.pixelFormat = .rgba16Float
        layer.backgroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)  // white * screen = no change
        layer.compositingFilter = "multiply"
    }

    required init(coder: NSCoder) { fatalError("unused") }

    func set(factor: Double) {
        clearColor = MTLClearColorMake(factor, factor, factor, 1)
    }

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

final class Daemon: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var overlay: Overlay?
    private var level = readLevel()
    private var signalSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        rebuild()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }

        // `bright set N` writes the level file and pokes us with SIGUSR1.
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            self?.level = readLevel()
            self?.tick()
        }
        source.resume()
        signalSource = source
    }

    private func rebuild() {
        window?.orderOut(nil)
        window = nil
        overlay = nil
        guard let screen = builtInScreen(),
              let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }

        let win = NSWindow(contentRect: screen.frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        win.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        win.isOpaque = false
        win.hasShadow = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        win.animationBehavior = .none

        let view = Overlay(frame: NSRect(origin: .zero, size: screen.frame.size), device: device, queue: queue)
        view.autoresizingMask = [.width, .height]
        win.contentView = view
        win.setFrame(screen.frame, display: true)
        win.orderFrontRegardless()
        window = win
        overlay = view
        tick()
    }

    private func tick() {
        guard let screen = builtInScreen() else { return }
        overlay?.set(factor: factor(level: level, maxEDR: Double(screen.maximumExtendedDynamicRangeColorComponentValue)))
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
// The plist is outside ~/Library/LaunchAgents, so it does not start at login.
let jobLabel = "com.peterkun.bright"
let jobDomain = "gui/\(getuid())"
let jobPlist = stateDir + "/\(jobLabel).plist"

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
    guard let path = Bundle.main.executablePath else { return false }
    let job: [String: Any] = [
        "Label": jobLabel,
        "ProgramArguments": [URL(fileURLWithPath: path).resolvingSymlinksInPath().path, "__daemon"],
        "RunAtLoad": true,
        "ProcessType": "Interactive",
    ]
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    guard let data = try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0),
          (try? data.write(to: URL(fileURLWithPath: jobPlist))) != nil
    else { return false }
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
    guard let screen = builtInScreen() else {
        print("built-in screen: not active (lid closed?)")
        return
    }
    let maxEDR = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
    let potential = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
    print(String(format: "HDR headroom now: %.2fx (panel potential %.2fx)", maxEDR, potential))
    if running { print(String(format: "multiplying the screen by: %.2fx", factor(level: level, maxEDR: maxEDR))) }
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
    func render() {
        let on = daemonPid() != nil
        let level = readLevel()
        let filled = level * width / 100
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
        let state = on ? "\u{1B}[1;33mON \u{1B}[0m" : "\u{1B}[2mOFF\u{1B}[0m"
        print("\r\u{1B}[2K  bright  \(state)  \(bar)  \(level)%\r\n\r\u{1B}[2K\u{1B}[2m  space on/off   left/right level   q quit\u{1B}[0m\u{1B}[1A\r", terminator: "")
        fflush(stdout)
    }

    render()
    var byte: UInt8 = 0
    while read(STDIN_FILENO, &byte, 1) == 1 {
        switch byte {
        case UInt8(ascii: "q"), 3:
            return
        case 27 where !inputPending():  // a lone Esc, not an arrow key
            return
        case UInt8(ascii: " "), 13:
            if daemonPid() != nil { turnOff() } else { _ = turnOn() }
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
default:
    print(usage)
    exit(arguments.first == "help" || arguments.first == "--help" || arguments.first == "-h" ? 0 : 2)
}

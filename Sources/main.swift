import Cocoa
import CoreGraphics
import Carbon
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import VideoToolbox

enum LensSize: String, CaseIterable {
    case standard = "Standard (800x400)"
    case large = "Large (1200x100)"
    case huge = "Huge (1600x600)"
    case ultraWide = "Ultra-Wide (3200x800)"
    case full5K = "Full 5K Width (4800x1000)"
    
    var dimensions: CGSize {
        switch self {
        case .standard:
            return CGSize(width: 800, height: 400)
        case .large:
            return CGSize(width: 1200, height: 100)
        case .huge:
            return CGSize(width: 1600, height: 600)
        case .ultraWide:
            return CGSize(width: 3200, height: 800)
        case .full5K:
            return CGSize(width: 4800, height: 1000)
        }
    }
}

final class LensWindow: NSPanel {
    var lensSize: LensSize = .huge {
        didSet { updateDimensions() }
    }
    
    var isPinned: Bool = false {
        didSet {
            self.ignoresMouseEvents = !isPinned
            self.alphaValue = isPinned ? 0.90 : 1.0
        }
    }
    
    private let contentImageView = NSImageView()

    init(size: LensSize) {
        self.lensSize = size
        super.init(
            contentRect: NSRect(origin: .zero, size: size.dimensions),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        self.level = .statusBar // Float over menu bar and all system UI
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        
        setupImageView()
        updateDimensions()
    }

    private func setupImageView() {
        guard let contentView = self.contentView else { return }
        contentImageView.frame = contentView.bounds
        contentImageView.autoresizingMask = [.width, .height]
        contentImageView.imageScaling = .scaleAxesIndependently
        contentView.addSubview(contentImageView)
    }

    func updateDimensions() {
        let newSize = lensSize.dimensions
        self.setContentSize(newSize)
        
        guard let contentView = self.contentView else { return }
        contentView.wantsLayer = true
        let layer = contentView.layer ?? CALayer()
        
        layer.borderWidth = 3.0
        layer.borderColor = NSColor.systemBlue.cgColor
        layer.cornerRadius = 16.0
        layer.masksToBounds = true
        contentView.layer = layer
    }

    func updateMagnifiedImage(_ image: CGImage) {
        contentImageView.image = NSImage(cgImage: image, size: self.frame.size)
    }

    func moveTo(mousePoint: NSPoint) {
        guard !isPinned else { return }
        // Direct origin placement without safe area clamping
        let origin = NSPoint(
            x: mousePoint.x - (frame.width / 2.0),
            y: mousePoint.y - (frame.height / 2.0)
        )
        self.setFrameOrigin(origin)
    }
}

// CGWindowListCreateImage is deprecated in favor of ScreenCaptureKit, and on
// current macOS it silently returns a solid black image instead of failing
// when something's wrong — so we capture each display continuously via
// SCStream and crop the region under the cursor out of the latest frame,
// rather than calling a one-shot capture function every tick.
final class ScreenCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    var zoomFactor: CGFloat = 1.75

    private let frameLock = NSLock()
    private var latestFrames: [CGDirectDisplayID: CGImage] = [:]
    private var displayIDsByStream: [ObjectIdentifier: CGDirectDisplayID] = [:]
    private var activeStreams: [SCStream] = []

    func start(excludingWindowID: CGWindowID) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let excludedWindows = content.windows.filter { $0.windowID == excludingWindowID }

                for display in content.displays {
                    let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

                    let config = SCStreamConfiguration()
                    let scale = Self.scaleFactor(forDisplayID: display.displayID)
                    config.width = max(1, Int(CGFloat(display.width) * scale))
                    config.height = max(1, Int(CGFloat(display.height) * scale))
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                    config.showsCursor = false
                    config.pixelFormat = kCVPixelFormatType_32BGRA

                    let stream = SCStream(filter: filter, configuration: config, delegate: self)
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.zoomintocursor.capture"))
                    try await stream.startCapture()

                    displayIDsByStream[ObjectIdentifier(stream)] = display.displayID
                    activeStreams.append(stream)
                }
            } catch {
                // Screen Recording permission missing, or capture unavailable.
                // The permission hint panel already surfaces this separately
                // via CGPreflightScreenCaptureAccess, so there's nothing more
                // to report here — the lens just has no frames to show.
            }
        }
    }

    private static func scaleFactor(forDisplayID displayID: CGDirectDisplayID) -> CGFloat {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first {
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }?.backingScaleFactor ?? 2.0
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let displayID = displayIDsByStream[ObjectIdentifier(stream)] else { return }

        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        guard let cgImage else { return }

        frameLock.lock()
        latestFrames[displayID] = cgImage
        frameLock.unlock()
    }

    func captureScreenUnderCursor(mouseLocation: NSPoint, lensSize: CGSize) -> CGImage? {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main,
              let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            return nil
        }

        frameLock.lock()
        let fullFrame = latestFrames[displayID]
        frameLock.unlock()
        guard let fullFrame else { return nil }

        let screenFrame = screen.frame
        let scale = screen.backingScaleFactor

        let captureWidth = lensSize.width / zoomFactor
        let captureHeight = lensSize.height / zoomFactor

        let pointRect = CGRect(
            x: (mouseLocation.x - screenFrame.origin.x) - (captureWidth / 2.0),
            y: (screenFrame.height - (mouseLocation.y - screenFrame.origin.y)) - (captureHeight / 2.0),
            width: captureWidth,
            height: captureHeight
        )

        let pixelRect = CGRect(
            x: pointRect.origin.x * scale,
            y: pointRect.origin.y * scale,
            width: pointRect.width * scale,
            height: pointRect.height * scale
        ).integral

        return fullFrame.cropping(to: pixelRect)
    }
}

final class ChecklistRow: NSView {
    private let checkLabel = NSTextField(labelWithString: "○")
    private let textLabel: NSTextField

    init(keyLabel: String, text: String) {
        textLabel = NSTextField(labelWithString: text)
        super.init(frame: .zero)

        checkLabel.font = .systemFont(ofSize: 15, weight: .medium)
        checkLabel.textColor = .tertiaryLabelColor
        checkLabel.translatesAutoresizingMaskIntoConstraints = false

        let keyTag = NSTextField(labelWithString: keyLabel)
        keyTag.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        keyTag.textColor = .white
        keyTag.backgroundColor = .systemBlue
        keyTag.drawsBackground = true
        keyTag.alignment = .center
        keyTag.wantsLayer = true
        keyTag.layer?.cornerRadius = 4
        keyTag.layer?.masksToBounds = true
        keyTag.translatesAutoresizingMaskIntoConstraints = false

        textLabel.font = .systemFont(ofSize: 13)
        textLabel.textColor = .secondaryLabelColor
        textLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(checkLabel)
        addSubview(keyTag)
        addSubview(textLabel)

        NSLayoutConstraint.activate([
            checkLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            checkLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkLabel.widthAnchor.constraint(equalToConstant: 18),

            keyTag.leadingAnchor.constraint(equalTo: checkLabel.trailingAnchor, constant: 8),
            keyTag.centerYAnchor.constraint(equalTo: centerYAnchor),
            keyTag.widthAnchor.constraint(equalToConstant: 44),
            keyTag.heightAnchor.constraint(equalToConstant: 20),

            textLabel.leadingAnchor.constraint(equalTo: keyTag.trailingAnchor, constant: 10),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            heightAnchor.constraint(equalToConstant: 26)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setChecked(_ checked: Bool) {
        checkLabel.stringValue = checked ? "✓" : "○"
        checkLabel.textColor = checked ? .systemGreen : .tertiaryLabelColor
        textLabel.textColor = checked ? .labelColor : .secondaryLabelColor
    }
}

final class OnboardingPanel: NSPanel {
    private let statusLabel = NSTextField(labelWithString: "Try these shortcuts to get started:")
    private let cycleRow = ChecklistRow(keyLabel: "⌥L", text: "Cycle the lens size")
    private let pinRow = ChecklistRow(keyLabel: "⌥S", text: "Lock the lens in place")
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    private var cycledSize = false
    private var toggledPin = false

    var onFinish: (() -> Void)?

    init() {
        let size = CGSize(width: 360, height: 180)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        title = "Welcome to Zoom Into Cursor"
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        setupContent()
        positionTopCenter(size: size)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func close() {
        onFinish?()
        super.close()
    }

    private func setupContent() {
        guard let contentView = self.contentView else { return }

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        doneButton.target = self
        doneButton.action = #selector(finishTapped)
        doneButton.bezelStyle = .rounded
        doneButton.isHidden = true
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [statusLabel, cycleRow, pinRow, doneButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor)
        ])
    }

    private func positionTopCenter(size: CGSize) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let origin = NSPoint(
            x: frame.midX - size.width / 2.0,
            y: frame.maxY - size.height - 60
        )
        setFrameOrigin(origin)
    }

    func markCycled() {
        guard !cycledSize else { return }
        cycledSize = true
        cycleRow.setChecked(true)
        checkCompletion()
    }

    func markPinToggled() {
        guard !toggledPin else { return }
        toggledPin = true
        pinRow.setChecked(true)
        checkCompletion()
    }

    private func checkCompletion() {
        guard cycledSize && toggledPin else { return }
        statusLabel.stringValue = "You're all set! 🎉"
        doneButton.isHidden = false
    }

    @objc private func finishTapped() {
        close()
    }
}

final class PermissionHintPanel: NSPanel {
    private let messageLabel = NSTextField(wrappingLabelWithString:
        "Zoom Into Cursor needs Screen Recording access to magnify your screen."
    )
    private let openSettingsButton = NSButton(title: "Open Screen Recording Settings", target: nil, action: nil)

    var onFinish: (() -> Void)?

    init() {
        let size = CGSize(width: 300, height: 150)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        title = "Permission Needed"
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        setupContent()
        positionBottomRight(size: size)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func close() {
        onFinish?()
        super.close()
    }

    private func setupContent() {
        guard let contentView = self.contentView else { return }

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        openSettingsButton.target = self
        openSettingsButton.action = #selector(openSettingsTapped)
        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [messageLabel, openSettingsButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor)
        ])
    }

    private func positionBottomRight(size: CGSize) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let origin = NSPoint(
            x: frame.maxX - size.width - 24,
            y: frame.minY + 24
        )
        setFrameOrigin(origin)
    }

    @objc private func openSettingsTapped() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var lensWindow: LensWindow!
    private var captureEngine = ScreenCaptureEngine()

    private var displayLinkTimer: Timer?
    private var mouseMonitor: Any?
    private var permissionCheckTimer: Timer?

    private var onboardingPanel: OnboardingPanel?
    private let onboardingCompletedKey = "com.zoomintocursor.onboardingCompleted"

    private var permissionHintPanel: PermissionHintPanel?
    private var didDismissPermissionHint = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        CGRequestScreenCaptureAccess()

        setupStatusMenu()
        setupLens()
        startTracking()
        registerCarbonHotKeys()

        if !UserDefaults.standard.bool(forKey: onboardingCompletedKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.presentOnboarding()
            }
        }
    }

    private func presentOnboarding() {
        onboardingPanel?.close()

        let panel = OnboardingPanel()
        let completedKey = onboardingCompletedKey
        panel.onFinish = { [weak self] in
            UserDefaults.standard.set(true, forKey: completedKey)
            self?.onboardingPanel = nil
        }
        onboardingPanel = panel
        panel.orderFrontRegardless()
    }

    private func setupStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🔍 Zoom Into Cursor"
        
        let menu = NSMenu()

        let welcomeItem = NSMenuItem(title: "Show Welcome Guide", action: #selector(showWelcomeGuide), keyEquivalent: "")
        welcomeItem.target = self
        menu.addItem(welcomeItem)

        let permissionItem = NSMenuItem(title: "Check Screen Recording Permission", action: #selector(checkScreenRecordingPermission), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        menu.addItem(NSMenuItem.separator())

        let sizeMenu = NSMenu()
        for sizeOption in LensSize.allCases {
            let item = NSMenuItem(title: sizeOption.rawValue, action: #selector(selectSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sizeOption
            sizeMenu.addItem(item)
        }
        let sizeMenuItem = NSMenuItem(title: "Lens Dimensions", action: nil, keyEquivalent: "")
        sizeMenuItem.submenu = sizeMenu
        menu.addItem(sizeMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "Cycle Size (Option + L)", action: #selector(cycleSize), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Lock/Unlock Position (Option + S)", action: #selector(togglePin), keyEquivalent: ""))
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit Zoom Into Cursor", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }

    private func setupLens() {
        lensWindow = LensWindow(size: .huge)
        lensWindow.orderFrontRegardless()
        captureEngine.start(excludingWindowID: CGWindowID(lensWindow.windowNumber))
    }

    private func startTracking() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.updateLensPositionAndCapture()
        }

        displayLinkTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updateLensPositionAndCapture()
        }

        // CGWindowListCreateImage silently returns a solid black image (not nil) when
        // Screen Recording access hasn't been granted, so capture success alone can't
        // tell us anything — check the real permission state directly instead. The hint
        // lives in its own stationary panel rather than inside the lens, since the lens
        // follows the cursor and is hard to read while it's moving.
        updatePermissionHint()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.updatePermissionHint()
        }
    }

    private func updatePermissionHint() {
        let granted = CGPreflightScreenCaptureAccess()

        if granted {
            permissionHintPanel?.close()
            permissionHintPanel = nil
            return
        }

        guard permissionHintPanel == nil, !didDismissPermissionHint else { return }

        let panel = PermissionHintPanel()
        panel.onFinish = { [weak self] in
            self?.didDismissPermissionHint = true
            self?.permissionHintPanel = nil
        }
        permissionHintPanel = panel
        panel.orderFrontRegardless()
    }

    @objc private func checkScreenRecordingPermission() {
        didDismissPermissionHint = false
        updatePermissionHint()
    }

    private func updateLensPositionAndCapture() {
        let mouseLocation = NSEvent.mouseLocation
        lensWindow.moveTo(mousePoint: mouseLocation)

        if let cgImage = captureEngine.captureScreenUnderCursor(
            mouseLocation: mouseLocation,
            lensSize: lensWindow.frame.size
        ) {
            lensWindow.updateMagnifiedImage(cgImage)
        }
    }

    // MARK: - Native Carbon Hotkeys (Works System-Wide)

    private func registerCarbonHotKeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
            guard let event = event, let userData = userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            
            if hotKeyID.id == 1 {
                DispatchQueue.main.async { delegate.cycleSize() }
            } else if hotKeyID.id == 2 {
                DispatchQueue.main.async { delegate.togglePin() }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        // Option + L (Keycode 37)
        let hotKeyIDL = EventHotKeyID(signature: OSType(100), id: 1)
        var hotKeyRefL: EventHotKeyRef?
        RegisterEventHotKey(37, UInt32(optionKey), hotKeyIDL, GetApplicationEventTarget(), 0, &hotKeyRefL)

        // Option + S (Keycode 1)
        let hotKeyIDS = EventHotKeyID(signature: OSType(101), id: 2)
        var hotKeyRefS: EventHotKeyRef?
        RegisterEventHotKey(1, UInt32(optionKey), hotKeyIDS, GetApplicationEventTarget(), 0, &hotKeyRefS)
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        guard let sizeOption = sender.representedObject as? LensSize else { return }
        lensWindow.lensSize = sizeOption
    }

    @objc private func cycleSize() {
        let allSizes = LensSize.allCases
        if let currentIndex = allSizes.firstIndex(of: lensWindow.lensSize) {
            let nextIndex = (currentIndex + 1) % allSizes.count
            lensWindow.lensSize = allSizes[nextIndex]
        }
        onboardingPanel?.markCycled()
    }

    @objc private func togglePin() {
        lensWindow.isPinned.toggle()
        onboardingPanel?.markPinToggled()
    }

    @objc private func showWelcomeGuide() {
        presentOnboarding()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

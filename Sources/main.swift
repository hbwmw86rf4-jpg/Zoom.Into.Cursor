import Cocoa
import CoreGraphics
import Carbon

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

final class ScreenCaptureEngine {
    var zoomFactor: CGFloat = 1.75

    func captureScreenUnderCursor(mouseLocation: NSPoint, lensSize: CGSize, lensWindowID: CGWindowID) -> CGImage? {
        guard let mainScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else {
            return nil
        }
        
        let screenFrame = mainScreen.frame
        let cgMouseY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        
        let captureWidth = lensSize.width / zoomFactor
        let captureHeight = lensSize.height / zoomFactor
        
        let captureRect = CGRect(
            x: (mouseLocation.x - screenFrame.origin.x) - (captureWidth / 2.0),
            y: cgMouseY - (captureHeight / 2.0),
            width: captureWidth,
            height: captureHeight
        )

        return CGWindowListCreateImage(
            captureRect,
            .optionOnScreenBelowWindow,
            lensWindowID,
            .bestResolution
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var lensWindow: LensWindow!
    private var captureEngine = ScreenCaptureEngine()
    
    private var displayLinkTimer: Timer?
    private var mouseMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        CGRequestScreenCaptureAccess()
        
        setupStatusMenu()
        setupLens()
        startTracking()
        registerCarbonHotKeys()
    }

    private func setupStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🔍 Zoom Into Cursor"
        
        let menu = NSMenu()
        
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
    }

    private func startTracking() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.updateLensPositionAndCapture()
        }
        
        displayLinkTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updateLensPositionAndCapture()
        }
    }

    private func updateLensPositionAndCapture() {
        let mouseLocation = NSEvent.mouseLocation
        lensWindow.moveTo(mousePoint: mouseLocation)
        
        let windowID = CGWindowID(lensWindow.windowNumber)
        if let cgImage = captureEngine.captureScreenUnderCursor(
            mouseLocation: mouseLocation,
            lensSize: lensWindow.frame.size,
            lensWindowID: windowID
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
    }

    @objc private func togglePin() {
        lensWindow.isPinned.toggle()
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

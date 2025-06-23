import SwiftUI
import Combine
import IOKit.ps
import ServiceManagement

// MARK: - Main App Entry Point
@main
struct BatteryIndicatorApp: App {
    // The delegate is used to manage our custom window and app lifecycle events.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The Settings scene provides the menu bar icon and its content.
        // The main app window is handled by the AppDelegate.
        Settings {
            MenuBarView()
                .environmentObject(appDelegate.appController)
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    // The main controller for our app's logic.
    fileprivate var appController = AppController()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // This is crucial for menu bar apps. It hides the app's icon from the Dock.
        // To make this work, you MUST also add a new key to the Info.plist file:
        // "Application is agent (UIElement)" and set its value to "YES".
        NSApp.setActivationPolicy(.accessory)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Clean up resources when the app is about to quit.
        appController.cleanup()
    }
}


// MARK: - App Controller (Main Logic)
class AppController: ObservableObject {
    @AppStorage("isIndicatorVisible") var isIndicatorVisible: Bool = true {
        didSet {
            updateIndicatorVisibility()
        }
    }
    @Published var launchAtLogin: Bool = false {
        didSet {
            LoginItemHelper.set(enabled: launchAtLogin)
        }
    }
    
    // We pass the battery service down to the views using the environment.
    @ObservedObject var batteryService: BatteryService
    private var indicatorWindow: NSWindow?
    
    init() {
        let service = BatteryService()
        self.batteryService = service
        self.launchAtLogin = LoginItemHelper.isEnabled
        
        setupIndicatorWindow()
        updateIndicatorVisibility()
        
        // Observe changes from the battery service
        service.$level
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                self?.updateIndicator(level: level)
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    /// Creates the custom, borderless window for the battery bar.
    private func setupIndicatorWindow() {
        guard let mainScreen = NSScreen.main else { return }
        let screenFrame = mainScreen.frame
        let indicatorHeight: CGFloat = 4 // The thickness of the battery bar

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: screenFrame.maxY - indicatorHeight, width: screenFrame.width, height: indicatorHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // --- Window Configuration ---
        window.level = .mainMenu + 1
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.isReleasedWhenClosed = false

        // Create the SwiftUI view for the bar itself, passing the service.
        let indicatorView = BatteryBarView()
            .environmentObject(batteryService)

        window.contentView = NSHostingView(rootView: indicatorView)
        self.indicatorWindow = window
    }

    /// Shows or hides the indicator window based on user preference.
    func updateIndicatorVisibility() {
        if isIndicatorVisible {
            indicatorWindow?.orderFront(nil)
        } else {
            indicatorWindow?.orderOut(nil)
        }
    }
    
    /// Updates the indicator's width. Color is now handled by the view.
    private func updateIndicator(level: Double) {
        guard let window = indicatorWindow,
              let screen = NSScreen.main else { return }
              
        let screenWidth = screen.frame.width
        let newWidth = screenWidth * CGFloat(level)
        
        var newFrame = window.frame
        newFrame.size.width = newWidth
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            window.animator().setFrame(newFrame, display: true)
        }
    }

    /// Called when the app quits to stop the timer.
    func cleanup() {
        batteryService.stopMonitoring()
    }
}


// MARK: - Battery Service (Model)
class BatteryService: ObservableObject {
    @Published var level: Double = 1.0
    @Published var color: Color = .green
    // <-- CHANGE: New property to track if a battery exists.
    @Published var hasBattery: Bool = true
    
    private var timer: Timer?

    init() {
        startMonitoring()
    }

    func startMonitoring() {
        updateBatteryStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.updateBatteryStatus()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    private func updateBatteryStatus() {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        
        // <-- CHANGE: Check if a power source (battery) exists.
        guard let source = sources.first else {
            // No battery found (e.g., on a desktop Mac).
            DispatchQueue.main.async {
                self.hasBattery = false
                self.level = 1.0 // Set to full width for the rainbow bar.
                self.stopMonitoring() // Stop timer, no need to check again.
            }
            return
        }

        // If we get here, a battery was found.
        guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: AnyObject] else {
            return
        }
        
        let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maxCapacity = description[kIOPSMaxCapacityKey] as? Int ?? 0
        
        let newLevel = (maxCapacity > 0) ? Double(currentCapacity) / Double(maxCapacity) : 0
        
        DispatchQueue.main.async {
            self.hasBattery = true
            self.level = newLevel
            self.color = self.getColorForLevel(newLevel)
        }
    }

    private func getColorForLevel(_ level: Double) -> Color {
        let percentage = Int(level * 100)
        switch percentage {
        case 70...100:
            return .green
        case 30...69:
            return .yellow
        case 0...29:
            return .red
        default:
            return .gray
        }
    }
    
    deinit {
        stopMonitoring()
    }
}


// MARK: - SwiftUI Views

/// The content of the Menu Bar dropdown.
struct MenuBarView: View {
    @EnvironmentObject var appController: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show Battery Bar", isOn: $appController.isIndicatorVisible)
            Toggle("Launch at Login", isOn: $appController.launchAtLogin)
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
    }
}

/// The actual colored bar view.
// <-- CHANGE: This view is now more intelligent.
struct BatteryBarView: View {
    @EnvironmentObject var batteryService: BatteryService
    @State private var hueRotation = 0.0
    
    // Timer to drive the rainbow animation.
    private let animationTimer = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()

    var body: some View {
        // Conditionally show battery color or animated rainbow.
        if batteryService.hasBattery {
            Rectangle()
                .fill(batteryService.color)
        } else {
            // Animated rainbow for Macs without a battery.
            Rectangle()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: rainbowColors),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .hueRotation(.degrees(hueRotation))
                .onReceive(animationTimer) { _ in
                    // Animate the hue rotation to create a shimmering effect.
                    hueRotation = (hueRotation + 1).truncatingRemainder(dividingBy: 360)
                }
        }
    }
    
    private var rainbowColors: [Color] {
        return [.red, .orange, .yellow, .green, .blue, .indigo, .purple, .red]
    }
}


// MARK: - Launch at Login Helper
struct LoginItemHelper {
    
    static var isEnabled: Bool {
        return SMAppService().status == .enabled
    }

    static func set(enabled: Bool) {
        do {
            let service = SMAppService()
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            print("Successfully set launch at login to \(enabled)")
        } catch {
            print("Failed to set launch at login: \(error.localizedDescription)")
        }
    }
}

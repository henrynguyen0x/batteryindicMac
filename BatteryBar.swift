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
    fileprivate var appController: AppController!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // When the app launches, initialize the main controller.
        // This kicks off battery monitoring and sets up the indicator window.
        appController = AppController()
        
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
    // Published properties will automatically update SwiftUI views when they change.
    @AppStorage("isIndicatorVisible") var isIndicatorVisible: Bool = true {
        didSet {
            updateIndicatorVisibility()
        }
    }
    @Published var launchAtLogin: Bool = false {
        didSet {
            // Update the system setting when this property changes.
            LoginItemHelper.set(enabled: launchAtLogin)
        }
    }
    
    private var batteryService: BatteryService
    private var indicatorWindow: NSWindow?
    
    init() {
        self.batteryService = BatteryService()
        self.launchAtLogin = LoginItemHelper.isEnabled
        
        setupIndicatorWindow()
        updateIndicatorVisibility()
        
        // Observe changes from the battery service
        batteryService.$level.combineLatest(batteryService.$color)
            .receive(on: RunLoop.main)
            .sink { [weak self] (level, color) in
                self?.updateIndicator(level: level, color: color)
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
        window.level = .mainMenu + 1 // Places the window just above the desktop but below the menu bar icons.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true // Allows clicks to pass through the window.
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle] // Makes it appear on all spaces.
        window.isReleasedWhenClosed = false // Keep the window instance in memory.

        // Create the SwiftUI view for the bar itself
        let indicatorView = BatteryBarView()
            .environmentObject(batteryService) // Pass the service to the view

        // Host the SwiftUI view within the NSWindow
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
    
    /// Updates the indicator's width and color.
    private func updateIndicator(level: Double, color: Color) {
        guard let window = indicatorWindow,
              let screen = NSScreen.main else { return }
              
        let screenWidth = screen.frame.width
        let newWidth = screenWidth * CGFloat(level)
        
        var newFrame = window.frame
        newFrame.size.width = newWidth
        
        // This smoothly animates the bar's width change.
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
    
    private var timer: Timer?

    init() {
        startMonitoring()
    }

    func startMonitoring() {
        // Check battery immediately on start, then set a timer to check periodically.
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
        
        guard let source = sources.first else {
            DispatchQueue.main.async {
                self.level = 1.0 // Assume full power for desktops
                self.color = .gray
            }
            return
        }

        guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: AnyObject] else {
            return
        }
        
        let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maxCapacity = description[kIOPSMaxCapacityKey] as? Int ?? 0
        
        let newLevel = (maxCapacity > 0) ? Double(currentCapacity) / Double(maxCapacity) : 0
        
        DispatchQueue.main.async {
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
struct BatteryBarView: View {
    @EnvironmentObject var batteryService: BatteryService

    var body: some View {
        Rectangle()
            .fill(batteryService.color)
    }
}


// MARK: - Launch at Login Helper
// <-- FIX: Corrected implementation using SMAppService()
struct LoginItemHelper {
    
    /// Checks if the app is currently enabled to launch at login.
    static var isEnabled: Bool {
        // Create an instance for the main app bundle and check its status.
        return SMAppService().status == .enabled
    }

    /// Enables or disables the launch at login setting.
    static func set(enabled: Bool) {
        do {
            // Create an instance of the service for the main app.
            let service = SMAppService()
            
            if enabled {
                // Register the app to launch at login.
                try service.register()
            } else {
                // Unregister the app.
                try service.unregister()
            }
            print("Successfully set launch at login to \(enabled)")
        } catch {
            print("Failed to set launch at login: \(error.localizedDescription)")
        }
    }
}

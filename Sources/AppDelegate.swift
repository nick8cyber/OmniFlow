import AppKit
import ApplicationServices
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NetworkMonitor.shared.start()

        NotificationCenter.default.addObserver(forName: .showSetup, object: nil, queue: .main) { [weak self] _ in
            self?.handleShowSetup()
        }
        NotificationCenter.default.addObserver(forName: .showSettings, object: nil, queue: .main) { [weak self] _ in
            self?.showSettingsWindow()
        }

        if !appState.hasCompletedSetup {
            showSetupWindow()
        } else {
            appState.startHotkeyMonitoring()
            appState.startAccessibilityPolling()
            Task { @MainActor in
                UpdateManager.shared.startPeriodicChecks()
            }
            if !AXIsProcessTrusted() {
                appState.showAccessibilityAlert()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard appState.hasCompletedSetup else { return true }
        if !flag {
            showSettingsWindow()
        }
        return true
    }

    // MARK: Setup window

    func showSetupWindow() {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = AppName.displayName
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 520, height: 680)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SetupView(onComplete: { [weak self] in
            self?.completeSetup()
        }).environmentObject(appState))
        setupWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func completeSetup() {
        appState.hasCompletedSetup = true
        setupWindow?.close()
        setupWindow = nil
        NSApp.setActivationPolicy(.accessory)
        appState.startHotkeyMonitoring()
        appState.startAccessibilityPolling()
        Task { @MainActor in
            UpdateManager.shared.startPeriodicChecks()
        }
        if !AXIsProcessTrusted() {
            appState.showAccessibilityAlert()
        }
    }

    private func handleShowSetup() {
        if let setupWindow, setupWindow.isVisible {
            // One wizard at a time: a second instance would leak through the
            // willClose observer and break the bail-out restore below.
            setupWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let wasCompleted = appState.hasCompletedSetup
        appState.hasCompletedSetup = false
        appState.stopAccessibilityPolling()
        appState.stopHotkeyMonitoring()
        showSetupWindow()
        guard wasCompleted else { return }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: setupWindow,
                                               queue: .main) { [weak self] _ in
            guard let self else { return }
            if !self.appState.hasCompletedSetup {
                self.appState.hasCompletedSetup = true
                self.appState.startHotkeyMonitoring()
                self.appState.startAccessibilityPolling()
                NSApp.setActivationPolicy(.accessory)
            }
            self.setupWindow = nil
        }
    }

    // MARK: Settings window

    private func showSettingsWindow() {
        NSApp.setActivationPolicy(.regular)
        if let settingsWindow {
            if settingsWindow.isVisible {
                settingsWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        presentSettingsWindow()
    }

    private func presentSettingsWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = AppName.displayName
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView().environmentObject(appState))
        settingsWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window,
                                               queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.setupWindow == nil {
                NSApp.setActivationPolicy(.accessory)
            }
            self.settingsWindow = nil
        }
    }
}

import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let controller = UsageController()
    private let notifier = Notifier()
    private var cancellables = Set<AnyCancellable>()
    private var projectsWatcher: DirectoryWatcher?
    private let visibility = PopoverVisibility()

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifier.requestAuthorization()
        setUpStatusItem()
        setUpPopover()
        observeController()
        observeSystemEvents()
        watchClaudeProjects()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        redraw()

        // The menu bar image is not a template, so it must be redrawn by hand
        // when the system flips between light and dark.
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(redraw),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func redraw() {
        let image = StatusItemView.image(for: controller.snapshot)
        statusItem.button?.image = image
        statusItem.button?.toolTip = tooltip()
    }

    private func tooltip() -> String {
        guard let snap = controller.snapshot else { return "Claude Runway — \(controller.statusLine)" }
        let rows = snap.buckets.map { "\($0.displayName): \(Int($0.percent.rounded()))%" }
        return (rows + [controller.statusLine]).joined(separator: "\n")
    }

    private func observeController() {
        // Any published change re-renders the menu bar.
        controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.redraw() }
            .store(in: &cancellables)
    }

    // MARK: - Popover

    private func setUpPopover() {
        popover.behavior = .transient
        popover.delegate = self

        let host = NSHostingController(
            rootView: PopoverView(controller: controller, onQuit: { NSApp.terminate(nil) })
                .environmentObject(visibility)
        )
        // Without this, NSPopover keeps its 320x320 default while SwiftUI draws
        // its own (taller) intrinsic size, so AppKit positions the popover for
        // the wrong height and the overflow runs off the top of the screen.
        host.sizingOptions = [.preferredContentSize]

        popover.contentViewController = host
    }

    // AppKit keeps the content view alive across showings, so the views inside
    // have to be told when they are on screen. Both directions come from the
    // delegate rather than from `togglePopover`, which never sees a popover
    // dismissed by a click outside it.
    func popoverDidShow(_ notification: Notification) {
        visibility.isOpen = true
    }

    func popoverDidClose(_ notification: Notification) {
        visibility.isOpen = false
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            controller.requestRefresh(reason: "popover opened")
            NotificationCenter.default.post(name: .claudeActivity, object: nil)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Refresh triggers

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.controller.requestRefresh(reason: "system wake") }
            }
        }
    }

    /// Claude Code writes transcripts here, so activity is a strong hint that the
    /// numbers have moved. The 5-minute gate in the controller keeps this cheap.
    private func watchClaudeProjects() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        projectsWatcher = DirectoryWatcher(url: path, debounce: 3) { [weak self] in
            Task { @MainActor in
                self?.controller.requestRefresh(reason: "claude activity")
                // The same hint tells the work log a session may have grown.
                NotificationCenter.default.post(name: .claudeActivity, object: nil)
            }
        }
    }
}

// Top-level code is nonisolated, but the delegate is @MainActor. This runs
// before the run loop starts, so assuming the main actor here is sound.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar only — no Dock icon, no main window.
    app.setActivationPolicy(.accessory)
    // Keep the delegate alive for the process lifetime.
    withExtendedLifetime(delegate) { app.run() }
}

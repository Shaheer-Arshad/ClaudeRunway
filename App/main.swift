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
        setUpEditMenu()
        setUpStatusItem()
        setUpPopover()
        observeController()
        controller.explainKeychainAccess = { Self.showKeychainExplanation() }
        offerToRemoveOtherCopies()
        observeSystemEvents()
        watchClaudeProjects()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    // MARK: - Edit menu

    /// Cmd-V, Cmd-C and friends are dispatched through the main menu's key
    /// equivalents. A menu bar app has no visible menu, so without this the
    /// session key field ignores paste. The menu is never shown.
    private func setUpEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
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

    // MARK: - Keychain explanation

    private static func showKeychainExplanation() {
        let alert = NSAlert()
        alert.messageText = "macOS may ask for your Mac login password"
        alert.informativeText = """
            Without a claude.ai session key, Claude Runway uses your existing Claude \
            Code sign-in to check your usage. To do that, macOS needs your permission \
            to let it access "Claude Code-credentials" in your keychain.

            If macOS asks for a password, enter the password you use to log in to \
            this Mac (not your Claude password) and click Always Allow so you \
            aren't asked again.

            To skip this entirely, add a session key in the popover.
            """
        alert.addButton(withTitle: "Continue")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Duplicate installs

    /// Installing a new version next to an old one (rather than over it) leaves
    /// two apps with the same bundle ID, and Spotlight or Launch at login may
    /// keep opening the old one. Offer to trash the others.
    private func offerToRemoveOtherCopies() {
        let me = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let others = NSWorkspace.shared
            .urlsForApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { $0 != me && !$0.path.contains("/.Trash/") && FileManager.default.fileExists(atPath: $0.path) }
        guard !others.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Another copy of Claude Runway is installed"
        alert.informativeText = "This version is running from:\n\(me.path)\n\nOther copies:\n"
            + others.map(\.path).joined(separator: "\n")
            + "\n\nMove the other copies to the Trash so only this version remains?"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep Them")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for url in others {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
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
    /// numbers have moved. The per-transport floor in RefreshGate keeps this cheap.
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

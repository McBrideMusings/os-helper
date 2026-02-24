import ComposableArchitecture
import HexCore
import SwiftUI

private let appLogger = HexLog.app
private let cacheLogger = HexLog.caches

class HexAppDelegate: NSObject, NSApplicationDelegate {
	var invisibleWindow: InvisibleWindow?
	var settingsWindow: NSWindow?
	var continuousListeningPanel: ContinuousListeningPanel?
	var statusItem: NSStatusItem!

	@Dependency(\.soundEffects) var soundEffect
	@Dependency(\.recording) var recording
	@Shared(.hexSettings) var hexSettings: HexSettings

	func applicationDidFinishLaunching(_: Notification) {
		DiagnosticsLogging.bootstrapIfNeeded()
		// Ensure Parakeet/FluidAudio caches live under Application Support, not ~/.cache
		configureLocalCaches()
		if isTesting {
			appLogger.debug("Running in testing mode")
			return
		}

		Task {
			await soundEffect.preloadSounds()
		}
		appLogger.info("Application did finish launching")

		// Set activation policy first
		updateAppMode()

		// Add notification observer
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleAppModeUpdate),
			name: .updateAppMode,
			object: nil
		)

		// Start long-running app effects (global hotkeys, permissions, etc.)
		startLifecycleTasksIfNeeded()

		// Then present main views
		presentMainView()
		presentSettingsView()
		startContinuousListeningPanelObserver()
		NSApp.activate(ignoringOtherApps: true)
	}

	private func startLifecycleTasksIfNeeded() {
		Task { @MainActor in
			await HexApp.appStore.send(.task).finish()
		}
	}

	/// Sets XDG_CACHE_HOME so FluidAudio stores models under our app's
	/// Application Support folder, keeping everything in one place.
    private func configureLocalCaches() {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let cache = support.appendingPathComponent("com.kitlangton.Hex/cache", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            setenv("XDG_CACHE_HOME", cache.path, 1)
            cacheLogger.info("XDG_CACHE_HOME set to \(cache.path)")
        } catch {
            cacheLogger.error("Failed to configure local caches: \(error.localizedDescription)")
        }
    }

	func presentMainView() {
		guard invisibleWindow == nil else {
			return
		}
		let transcriptionStore = HexApp.appStore.scope(state: \.transcription, action: \.transcription)
		let transcriptionView = TranscriptionView(store: transcriptionStore).padding().padding(.top).padding(.top)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		invisibleWindow = InvisibleWindow.fromView(transcriptionView)
		invisibleWindow?.makeKeyAndOrderFront(nil)
	}

	func presentSettingsView() {
		if let settingsWindow = settingsWindow {
			settingsWindow.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
			return
		}

		let settingsView = AppView(store: HexApp.appStore)
		let settingsWindow = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 700, height: 700),
			styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable],
			backing: .buffered,
			defer: false
		)
		settingsWindow.titleVisibility = .visible
		settingsWindow.contentView = NSHostingView(rootView: settingsView)
		settingsWindow.isReleasedWhenClosed = false
		settingsWindow.center()
		settingsWindow.toolbarStyle = NSWindow.ToolbarStyle.unified
		settingsWindow.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
		self.settingsWindow = settingsWindow
	}

	private var continuousListeningObserverTask: Task<Void, Never>?

	private func startContinuousListeningPanelObserver() {
		continuousListeningObserverTask = Task { @MainActor [weak self] in
			let store = HexApp.appStore
			var wasActive = false
			var lastScreenID: CGDirectDisplayID?
			while !Task.isCancelled {
				let isActive = store.state.continuousListening.panelVisible
				if isActive != wasActive {
					appLogger.notice("Panel observer: panelVisible changed \(wasActive) → \(isActive)")
					wasActive = isActive
					if isActive {
						appLogger.notice("Panel observer: showing panel")
						self?.showContinuousListeningPanel()
						lastScreenID = self?.continuousListeningPanel?.screen?.displayID
					} else {
						appLogger.notice("Panel observer: hiding panel")
						self?.hideContinuousListeningPanel()
						lastScreenID = nil
					}
				}
				// Track which screen the frontmost app is on and move the panel if it changed
				if isActive, let panel = self?.continuousListeningPanel {
					let currentScreen = Self.screenOfFrontmostWindow() ?? NSScreen.main
					let currentID = currentScreen?.displayID
					if currentID != lastScreenID, let screen = currentScreen {
						self?.repositionPanel(panel, on: screen)
						lastScreenID = currentID
					}
				}
				try? await Task.sleep(for: .milliseconds(100))
			}
		}
	}

	private var panelMoveObserver: NSObjectProtocol?

	private func showContinuousListeningPanel() {
		guard continuousListeningPanel == nil else { return }
		let store = HexApp.appStore.scope(
			state: \.continuousListening,
			action: \.continuousListening
		)
		let panel = ContinuousListeningPanel(store: store)

		// Restore saved offset for the current screen
		if let screen = panel.screen ?? NSScreen.main {
			let displayKey = String(screen.displayID)
			if let offset = hexSettings.continuousListeningPanelOffsets[displayKey], offset.count == 2 {
				let defaultPos = Self.defaultPanelOrigin(on: screen)
				panel.setFrameOrigin(NSPoint(x: defaultPos.x + offset[0], y: defaultPos.y + offset[1]))
			}
		}

		panel.orderFront(nil)
		continuousListeningPanel = panel

		// Observe drag moves to save offset
		panelMoveObserver = NotificationCenter.default.addObserver(
			forName: NSWindow.didMoveNotification,
			object: panel,
			queue: .main
		) { [weak self] _ in
			self?.savePanelOffset()
		}

		appLogger.notice("Continuous listening panel shown")
	}

	private func hideContinuousListeningPanel() {
		savePanelOffset()
		if let observer = panelMoveObserver {
			NotificationCenter.default.removeObserver(observer)
			panelMoveObserver = nil
		}
		continuousListeningPanel?.orderOut(nil)
		continuousListeningPanel = nil
		appLogger.notice("Continuous listening panel hidden")
	}

	private func savePanelOffset() {
		guard let panel = continuousListeningPanel,
		      let screen = panel.screen ?? NSScreen.main else { return }
		let displayKey = String(screen.displayID)
		let defaultPos = Self.defaultPanelOrigin(on: screen)
		let dx = panel.frame.origin.x - defaultPos.x
		let dy = panel.frame.origin.y - defaultPos.y
		$hexSettings.withLock { $0.continuousListeningPanelOffsets[displayKey] = [dx, dy] }
	}

	private static func screenOfFrontmostWindow() -> NSScreen? {
		guard let frontApp = NSWorkspace.shared.frontmostApplication,
		      frontApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
			return nil
		}
		// Get the frontmost app's main window position via Accessibility API
		let pid = frontApp.processIdentifier
		let appRef = AXUIElementCreateApplication(pid)
		var windowValue: AnyObject?
		guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowValue) == .success else {
			return nil
		}
		let windowRef = windowValue as! AXUIElement
		var positionValue: AnyObject?
		guard AXUIElementCopyAttributeValue(windowRef, kAXPositionAttribute as CFString, &positionValue) == .success else {
			return nil
		}
		var point = CGPoint.zero
		AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
		// Find which screen contains this point
		return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
	}

	private static func defaultPanelOrigin(on screen: NSScreen) -> NSPoint {
		let panelWidth: CGFloat = 320
		let x = screen.visibleFrame.midX - panelWidth / 2
		let y = screen.visibleFrame.minY + 80
		return NSPoint(x: x, y: y)
	}

	private func repositionPanel(_ panel: NSPanel, on screen: NSScreen) {
		let defaultPos = Self.defaultPanelOrigin(on: screen)
		let displayKey = String(screen.displayID)
		if let offset = hexSettings.continuousListeningPanelOffsets[displayKey], offset.count == 2 {
			panel.setFrameOrigin(NSPoint(x: defaultPos.x + offset[0], y: defaultPos.y + offset[1]))
		} else {
			panel.setFrameOrigin(defaultPos)
		}
	}

	@objc private func handleAppModeUpdate() {
		Task {
			await updateAppMode()
		}
	}

	@MainActor
	private func updateAppMode() {
		appLogger.debug("showDockIcon = \(self.hexSettings.showDockIcon)")
		if self.hexSettings.showDockIcon {
			NSApp.setActivationPolicy(.regular)
		} else {
			NSApp.setActivationPolicy(.accessory)
		}
	}

	func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
		presentSettingsView()
		return true
	}

	func applicationWillTerminate(_: Notification) {
		Task {
			await recording.cleanup()
		}
	}
}

private extension NSScreen {
	var displayID: CGDirectDisplayID {
		(deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
	}
}

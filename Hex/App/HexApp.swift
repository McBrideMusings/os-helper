import ComposableArchitecture
import Inject
import Sparkle
import AppKit
import SwiftUI

@main
struct HexApp: App {
	static let appStore = Store(initialState: AppFeature.State()) {
		AppFeature()
	}

	@NSApplicationDelegateAdaptor(HexAppDelegate.self) var appDelegate
  
    var body: some Scene {
        MenuBarExtra {
            CheckForUpdatesView()

            // Copy last transcript to clipboard
            MenuBarCopyLastTranscriptButton()

            Button("Settings...") {
                appDelegate.presentSettingsView()
            }.keyboardShortcut(",")

			Divider()

			ContinuousListeningToggle()

			Divider()

			Button("Quit") {
				NSApplication.shared.terminate(nil)
			}.keyboardShortcut("q")
		} label: {
			let image: NSImage = {
				let ratio = $0.size.height / $0.size.width
				$0.size.height = 18
				$0.size.width = 18 / ratio
				return $0
			}(NSImage(named: "HexIcon")!)
			Image(nsImage: image)
		}


		WindowGroup {}.defaultLaunchBehavior(.suppressed)
			.commands {
				CommandGroup(after: .appInfo) {
					CheckForUpdatesView()

					Button("Settings...") {
						appDelegate.presentSettingsView()
					}.keyboardShortcut(",")
				}

				CommandGroup(replacing: .help) {}
			}
	}
}

struct ContinuousListeningToggle: View {
	var body: some View {
		let store = HexApp.appStore
		let isActive = store.state.continuousListening.isActive
		Button(isActive ? "Stop Continuous Listening" : "Continuous Listening...") {
			store.send(.continuousListening(.toggleMode))
		}
	}
}

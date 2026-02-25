import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct GeneralSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			Label {
				Toggle("Open on Login",
				       isOn: Binding(
				       	get: { store.hexSettings.openOnLogin },
				       	set: { store.send(.toggleOpenOnLogin($0)) }
				       ))
			} icon: {
				Image(systemName: "arrow.right.circle")
			}

			Label {
				Toggle("Show Dock Icon", isOn: $store.hexSettings.showDockIcon)
			} icon: {
				Image(systemName: "dock.rectangle")
			}

			Label {
				Toggle("Use clipboard to insert", isOn: $store.hexSettings.useClipboardPaste)
				Text("Use clipboard to insert text. Fast but may not restore all clipboard content.\nTurn off to use simulated keypresses. Slower, but doesn't need to restore clipboard")
			} icon: {
				Image(systemName: "doc.on.doc.fill")
			}

			Label {
				Toggle("Copy to clipboard", isOn: $store.hexSettings.copyToClipboard)
				Text("Copy transcription text to clipboard in addition to pasting it")
			} icon: {
				Image(systemName: "doc.on.clipboard")
			}

			Label {
				Toggle(
					"Prevent System Sleep while Recording",
					isOn: Binding(
						get: { store.hexSettings.preventSystemSleep },
						set: { store.send(.togglePreventSystemSleep($0)) }
					)
				)
			} icon: {
				Image(systemName: "zzz")
			}

			Label {
				HStack(alignment: .center) {
					Text("Audio Behavior while Recording")
				Spacer()
					Picker("", selection: Binding(
						get: { store.hexSettings.recordingAudioBehavior },
						set: { store.send(.setRecordingAudioBehavior($0)) }
					)) {
						Label("Pause Media", systemImage: "pause")
							.tag(RecordingAudioBehavior.pauseMedia)
						Label("Mute Volume", systemImage: "speaker.slash")
							.tag(RecordingAudioBehavior.mute)
						Label("Do Nothing", systemImage: "hand.raised.slash")
							.tag(RecordingAudioBehavior.doNothing)
					}
					.pickerStyle(.menu)
				}
			} icon: {
				Image(systemName: "speaker.wave.2")
			}
		} header: {
			Text("General")
		}

		Section {
			Label {
				HStack(alignment: .center) {
					Text("Mouse Button 3 (Back)")
					Spacer()
					Picker("", selection: Binding(
						get: { store.hexSettings.mouseButton3Action },
						set: { store.send(.setMouseButton3Action($0)) }
					)) {
						Text("None").tag(MouseButtonAction.none)
						Text("Send Text").tag(MouseButtonAction.sendText)
						Text("Clear Text").tag(MouseButtonAction.clearText)
					}
					.pickerStyle(.menu)
				}
			} icon: {
				Image(systemName: "computermouse")
			}

			Label {
				HStack(alignment: .center) {
					Text("Mouse Button 4 (Forward)")
					Spacer()
					Picker("", selection: Binding(
						get: { store.hexSettings.mouseButton4Action },
						set: { store.send(.setMouseButton4Action($0)) }
					)) {
						Text("None").tag(MouseButtonAction.none)
						Text("Send Text").tag(MouseButtonAction.sendText)
						Text("Clear Text").tag(MouseButtonAction.clearText)
					}
					.pickerStyle(.menu)
				}
			} icon: {
				Image(systemName: "computermouse")
			}

			Label {
				Toggle("Double-double-click to send", isOn: $store.hexSettings.doubleDoubleClickToSend)
				Text("Double-click twice in quick succession to send text. A single double-click still selects text normally.")
					.settingsCaption()
			} icon: {
				Image(systemName: "cursorarrow.click.2")
			}

			Label {
				Toggle("Double-right-click to clear", isOn: $store.hexSettings.doubleRightClickToClear)
				Text("Double-right-click to clear accumulated text.")
					.settingsCaption()
			} icon: {
				Image(systemName: "cursorarrow.click.2")
			}

			Text("Assign mouse buttons or click gestures to send or clear text during continuous dictation mode.")
				.settingsCaption()
		} header: {
			Text("Mouse Buttons (Continuous Dictation)")
		}

		Section {
			Label {
				HStack(alignment: .center) {
					Text("Engine")
					Spacer()
					Picker("", selection: $store.hexSettings.continuousListeningBackend) {
						Text("Chunked (VAD)").tag(ContinuousListeningBackend.chunked)
						Text("Streaming").tag(ContinuousListeningBackend.streaming)
					}
					.pickerStyle(.menu)
				}
			} icon: {
				Image(systemName: "waveform.badge.mic")
			}

			Label {
				Toggle("GPU Acceleration", isOn: $store.hexSettings.useGPUAcceleration)
				Text("Use GPU for model inference. May improve speed on Apple Silicon. Requires model reload.")
					.settingsCaption()
			} icon: {
				Image(systemName: "cpu")
			}

			if store.hexSettings.continuousListeningBackend == .chunked {
			Label {
				Toggle("Segment Splitting", isOn: $store.hexSettings.segmentSplittingEnabled)
				Text("Split text into segments after silence pauses during continuous dictation.")
					.settingsCaption()
			} icon: {
				Image(systemName: "waveform.path")
			}

			if store.hexSettings.segmentSplittingEnabled {
				Label {
					HStack {
						Text("Segment Silence")
						Spacer()
						Stepper(
							"\(store.hexSettings.segmentSilenceThreshold, specifier: "%.1f")s",
							value: $store.hexSettings.segmentSilenceThreshold,
							in: 0.5...10.0,
							step: 0.5
						)
					}
				} icon: {
					Image(systemName: "timer")
				}
			}
		}

		if store.hexSettings.continuousListeningBackend == .streaming {
				Label {
					HStack {
						Text("Confirmation Delay")
						Spacer()
						Stepper(
							"\(store.hexSettings.streamingMinConfirmationContext, specifier: "%.0f")s",
							value: $store.hexSettings.streamingMinConfirmationContext,
							in: 1...15,
							step: 1
						)
					}
				} icon: {
					Image(systemName: "timer")
				}

				Label {
					HStack {
						Text("Confidence Threshold")
						Spacer()
						Text("\(store.hexSettings.streamingConfirmationThreshold, specifier: "%.2f")")
							.monospacedDigit()
						Stepper(
							"",
							value: $store.hexSettings.streamingConfirmationThreshold,
							in: 0.50...0.99,
							step: 0.05
						)
						.labelsHidden()
					}
				} icon: {
					Image(systemName: "dial.low")
				}
			}

			Text("Chunked mode transcribes after each pause. Streaming mode shows live text but needs more audio context before confirming.")
				.settingsCaption()
		} header: {
			Text("Continuous Dictation Engine")
		}
		.enableInjection()
	}
}

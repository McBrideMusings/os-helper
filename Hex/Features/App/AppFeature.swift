//
//  AppFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//

import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import SwiftUI

private let appFeatureLogger = HexLog.app

@Reducer
struct AppFeature {
  enum ActiveTab: Equatable {
    case settings
    case remappings
    case history
    case about
  }

	@ObservableState
	struct State {
		var transcription: TranscriptionFeature.State = .init()
		var settings: SettingsFeature.State = .init()
		var history: HistoryFeature.State = .init()
		var continuousListening: ContinuousListeningFeature.State = .init()
		var activeTab: ActiveTab = .settings
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState

    // Permission state
    var microphonePermission: PermissionStatus = .notDetermined
    var accessibilityPermission: PermissionStatus = .notDetermined
    var inputMonitoringPermission: PermissionStatus = .notDetermined
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case transcription(TranscriptionFeature.Action)
    case settings(SettingsFeature.Action)
    case history(HistoryFeature.Action)
    case continuousListening(ContinuousListeningFeature.Action)
    case setActiveTab(ActiveTab)
    case task
    case pasteLastTranscript

    // Permission actions
    case checkPermissions
    case permissionsUpdated(mic: PermissionStatus, acc: PermissionStatus, input: PermissionStatus)
    case appActivated
    case requestMicrophone
    case requestAccessibility
    case requestInputMonitoring
    case modelStatusEvaluated(Bool)
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.transcription) var transcription
  @Dependency(\.permissions) var permissions

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.transcription, action: \.transcription) {
      TranscriptionFeature()
    }

    Scope(state: \.settings, action: \.settings) {
      SettingsFeature()
    }

    Scope(state: \.history, action: \.history) {
      HistoryFeature()
    }

    Scope(state: \.continuousListening, action: \.continuousListening) {
      ContinuousListeningFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        return .merge(
          startPasteLastTranscriptMonitoring(),
          startContinuousListeningMouseButtonMonitoring(),
          ensureSelectedModelReadiness(),
          startPermissionMonitoring()
        )

      case .pasteLastTranscript:
        @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
        guard let lastTranscript = transcriptionHistory.history.first?.text else {
          return .none
        }
        return .run { _ in
          await pasteboard.paste(lastTranscript)
        }

      case .continuousListening:
        return .none

      case .transcription(.hotKeyPressed):
        let panelVis = state.continuousListening.panelVisible
        let mode = state.continuousListening.recordingMode
        appFeatureLogger.notice("hotKeyPressed → showPanel + startPushToTalk (panelVisible=\(panelVis) recordingMode=\(String(describing: mode)))")
        return .merge(
          .send(.continuousListening(.showPanel)),
          .send(.continuousListening(.startPushToTalk))
        )

      case .transcription(.hotKeyReleased):
        let mode = state.continuousListening.recordingMode
        appFeatureLogger.notice("hotKeyReleased (recordingMode=\(String(describing: mode)))")
        if state.continuousListening.recordingMode == .pushToTalk {
          return .send(.continuousListening(.stopPushToTalk))
        }
        return .none

      case .transcription(.hotKeyDoubleTapped):
        let panelVis = state.continuousListening.panelVisible
        let mode = state.continuousListening.recordingMode
        appFeatureLogger.notice("hotKeyDoubleTapped → showPanel + toggleContinuousMode (panelVisible=\(panelVis) recordingMode=\(String(describing: mode)))")
        return .merge(
          .send(.continuousListening(.showPanel)),
          .send(.continuousListening(.toggleContinuousMode))
        )

      case .transcription(.cancel):
        // If the panel is visible, ESC stops recording but keeps panel open
        if state.continuousListening.panelVisible, state.continuousListening.isActive {
          state.continuousListening.recordingMode = .idle
          return .send(.continuousListening(.stopListening))
        }
        return .none

      case .transcription(.modelMissing):
        HexLog.app.notice("Model missing - activating app and switching to settings")
        state.activeTab = .settings
        state.settings.shouldFlashModelSection = true
        return .run { send in
          await MainActor.run {
            HexLog.app.notice("Activating app for model missing")
            NSApplication.shared.activate(ignoringOtherApps: true)
          }
          try? await Task.sleep(for: .seconds(2))
          await send(.settings(.set(\.shouldFlashModelSection, false)))
        }

      case .transcription:
        return .none

      case .settings:
        return .none

      case .history(.navigateToSettings):
        state.activeTab = .settings
        return .none
      case .history:
        return .none
		case let .setActiveTab(tab):
			state.activeTab = tab
			return .none

      // Permission handling
      case .checkPermissions:
        return .run { send in
          async let mic = permissions.microphoneStatus()
          async let acc = permissions.accessibilityStatus()
          async let input = permissions.inputMonitoringStatus()
          await send(.permissionsUpdated(mic: mic, acc: acc, input: input))
        }

      case let .permissionsUpdated(mic, acc, input):
        state.microphonePermission = mic
        state.accessibilityPermission = acc
        state.inputMonitoringPermission = input
        return .none

      case .appActivated:
        // App became active - re-check permissions
        return .send(.checkPermissions)

      case .requestMicrophone:
        return .run { send in
          _ = await permissions.requestMicrophone()
          await send(.checkPermissions)
        }

      case .requestAccessibility:
        return .run { send in
          await permissions.requestAccessibility()
          // Poll for status change (macOS doesn't provide callback)
          for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            await send(.checkPermissions)
          }
        }

      case .requestInputMonitoring:
        return .run { send in
          _ = await permissions.requestInputMonitoring()
          for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            await send(.checkPermissions)
          }
        }

      case .modelStatusEvaluated:
        return .none
      }
    }
  }
  
  private func startPasteLastTranscriptMonitoring() -> Effect<Action> {
    .run { send in
      @Shared(.isSettingPasteLastTranscriptHotkey) var isSettingPasteLastTranscriptHotkey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      let token = keyEventMonitor.handleKeyEvent { keyEvent in
        // Skip if user is setting a hotkey
        if isSettingPasteLastTranscriptHotkey {
          return false
        }

        // Check if this matches the paste last transcript hotkey
        guard let pasteHotkey = hexSettings.pasteLastTranscriptHotkey,
              let key = keyEvent.key,
              key == pasteHotkey.key,
              keyEvent.modifiers.matchesExactly(pasteHotkey.modifiers) else {
          return false
        }

        // Trigger paste action - use MainActor to avoid escaping send
        MainActor.assumeIsolated {
          send(.pasteLastTranscript)
        }
        return true // Intercept the key event
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  private func ensureSelectedModelReadiness() -> Effect<Action> {
    .run { send in
      @Shared(.hexSettings) var hexSettings: HexSettings
      @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
      let selectedModel = hexSettings.selectedModel
      guard !selectedModel.isEmpty else {
        await send(.modelStatusEvaluated(false))
        return
      }
      let isReady = await transcription.isModelDownloaded(selectedModel)
      $modelBootstrapState.withLock { state in
        state.modelIdentifier = selectedModel
        if state.modelDisplayName?.isEmpty ?? true {
          state.modelDisplayName = selectedModel
        }
        state.isModelReady = isReady
        if isReady {
          state.lastError = nil
          state.progress = 1
        } else {
          state.progress = 0
        }
      }
      await send(.modelStatusEvaluated(isReady))
    }
  }

  private func startPermissionMonitoring() -> Effect<Action> {
    .run { send in
      // Initial check on app launch
      await send(.checkPermissions)

      // Monitor app activation events
      for await activation in permissions.observeAppActivation() {
        if case .didBecomeActive = activation {
          await send(.appActivated)
        }
      }

    }
  }

  private func startContinuousListeningMouseButtonMonitoring() -> Effect<Action> {
    .run { send in
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Track timestamp of last left double-click for "double-double-click to send"
      nonisolated(unsafe) var lastLeftDoubleClickTime: ContinuousClock.Instant? = nil

      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Only handle when continuous listening panel is visible
        let store = HexApp.appStore
        guard store.state.continuousListening.panelVisible else {
          return false
        }

        switch inputEvent {
        case let .mouseButton(buttonNumber):
          let action: MouseButtonAction
          switch buttonNumber {
          case 3: action = hexSettings.mouseButton3Action
          case 4: action = hexSettings.mouseButton4Action
          default: return false
          }

          switch action {
          case .none:
            return false
          case .sendText:
            MainActor.assumeIsolated {
              send(.continuousListening(.dispatchText))
            }
            return true
          case .clearText:
            MainActor.assumeIsolated {
              send(.continuousListening(.clearText))
            }
            return true
          }

        case .leftDoubleClick:
          guard hexSettings.doubleDoubleClickToSend else { return false }
          let now = ContinuousClock.now
          if let last = lastLeftDoubleClickTime, now - last < .milliseconds(600) {
            // Second double-click within window — send text
            lastLeftDoubleClickTime = nil
            MainActor.assumeIsolated {
              send(.continuousListening(.dispatchText))
            }
            return true  // Consume to prevent text selection
          } else {
            // First double-click — record timestamp, pass through
            lastLeftDoubleClickTime = now
            return false
          }

        case .rightDoubleClick:
          guard hexSettings.doubleRightClickToClear else { return false }
          MainActor.assumeIsolated {
            send(.continuousListening(.clearText))
          }
          return true

        default:
          return false
        }
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  private func startContinuousListeningEnterMonitoring() -> Effect<Action> {
    .run { send in
      let token = keyEventMonitor.handleKeyEvent { keyEvent in
        guard let key = keyEvent.key, key == .return else {
          return false
        }

        // Only intercept when continuous listening panel is visible
        let store = HexApp.appStore
        guard store.state.continuousListening.panelVisible else {
          return false
        }

        MainActor.assumeIsolated {
          send(.continuousListening(.dispatchText))
        }
        return true
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }
}


struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>
  @State private var columnVisibility = NavigationSplitViewVisibility.automatic

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(selection: $store.activeTab) {
        Button {
          store.send(.setActiveTab(.settings))
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.settings)

        Button {
          store.send(.setActiveTab(.remappings))
        } label: {
          Label("Transforms", systemImage: "text.badge.plus")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.remappings)

        Button {
          store.send(.setActiveTab(.history))
        } label: {
          Label("History", systemImage: "clock")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.history)

        Button {
          store.send(.setActiveTab(.about))
        } label: {
          Label("About", systemImage: "info.circle")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.about)
      }
    } detail: {
      switch store.state.activeTab {
      case .settings:
        SettingsView(
          store: store.scope(state: \.settings, action: \.settings),
          microphonePermission: store.microphonePermission,
          accessibilityPermission: store.accessibilityPermission,
          inputMonitoringPermission: store.inputMonitoringPermission
        )
        .navigationTitle("Settings")
      case .remappings:
        WordRemappingsView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("Transforms")
      case .history:
        HistoryView(store: store.scope(state: \.history, action: \.history))
          .navigationTitle("History")
      case .about:
        AboutView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("About")
      }
    }
    .enableInjection()
  }
}

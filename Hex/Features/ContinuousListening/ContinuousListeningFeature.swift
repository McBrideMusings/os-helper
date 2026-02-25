//
//  ContinuousListeningFeature.swift
//  Hex
//

import AppKit
import AVFoundation
import ComposableArchitecture
import Foundation
import HexCore
import WhisperKit

private let logger = HexLog.continuousListening

// MARK: - Audio Buffer Writer

/// Writes an array of AVAudioPCMBuffers to a temporary WAV file for file-based transcription.
enum AudioBufferWriter {
  static func write(buffers: [AVAudioPCMBuffer]) throws -> URL {
    guard let first = buffers.first else {
      throw NSError(domain: "AudioBufferWriter", code: -1, userInfo: [NSLocalizedDescriptionKey: "No buffers to write"])
    }
    let format = first.format
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("hex-chunk-\(UUID().uuidString).wav")
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    for buffer in buffers {
      try file.write(from: buffer)
    }
    return url
  }
}

// MARK: - Text Block Model

struct TextBlock: Equatable, Identifiable {
  let id: UUID
  var text: String
  var status: Status
  let timestamp: Date
  var isSessionStart: Bool = false

  enum Status: Equatable {
    case transcribing
    case complete
    case error(String)
  }
}

@Reducer
struct ContinuousListeningFeature {
  enum RecordingMode: Equatable {
    case idle
    case continuous
    case pushToTalk
  }

  @ObservableState
  struct State: Equatable {
    var isActive: Bool = false
    var panelVisible: Bool = false
    var recordingMode: RecordingMode = .idle
    var textBlocks: IdentifiedArrayOf<TextBlock> = []
    var interimText: String?
    var meterLevel: Float = 0
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var error: String?
    var hasCaptureError: Bool = false
    var activeSegmentID: UUID? = nil
    var lastChunkTimestamp: Date? = nil
    var pendingChunkIDs: Set<UUID> = []
    var sessionHasProducedBlocks: Bool = false
    var sessionDividerVisible: Bool = false
    var isAwaitingDispatch: Bool = false
    @Shared(.isContinuousListeningActive) var isContinuousListeningActive: Bool = false
  }

  enum Action {
    case toggleMode
    case startListening
    case stopListening
    case meterLevelUpdated(Float)
    // Panel lifecycle
    case showPanel
    case hidePanel
    // Recording modes
    case startPushToTalk
    case stopPushToTalk
    case confirmStopPushToTalk
    case toggleContinuousMode
    // Streaming mode
    case streamingUpdate(StreamingTextUpdate)
    case streamingError(String)
    // Chunked mode
    case chunkReceived([AVAudioPCMBuffer])
    case chunkTranscribed(blockID: UUID, chunkID: UUID, text: String)
    case chunkFailed(blockID: UUID, chunkID: UUID, message: String)
    case interimTimerFired
    case interimTranscriptionResult(String)
    case segmentSilenceExceeded
    // Common
    case captureError(String)
    case retryCapture
    case dispatchText
    case clearText
    case textDispatched
  }

  private enum CancelID {
    case listening
    case meterObservation
    case rawBufferForwarding
    case streamingUpdates
    case chunkObservation
    case interimTimer
    case interimTranscription
    case watchdog
    case recovery
    case deferredPTTStop
    case segmentSilenceTimer
  }

  @Dependency(\.streamingAudio) var streamingAudio
  @Dependency(\.streamingTranscription) var streamingTranscription
  @Dependency(\.transcription) var transcription
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.soundEffects) var soundEffects
  @Dependency(\.date) var date
  @Shared(.hexSettings) var hexSettings: HexSettings

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .toggleMode:
        if state.isActive {
          return .send(.stopListening)
        } else {
          // Capture the frontmost app before we start
          let frontApp = NSWorkspace.shared.frontmostApplication
          state.sourceAppBundleID = frontApp?.bundleIdentifier
          state.sourceAppName = frontApp?.localizedName
          logger.notice(
            "Target app: \(frontApp?.localizedName ?? "unknown", privacy: .public) (\(frontApp?.bundleIdentifier ?? "?", privacy: .public))"
          )
          return .send(.startListening)
        }

      // MARK: - Panel Lifecycle

      case .showPanel:
        guard !state.panelVisible else { return .none }
        state.panelVisible = true
        state.recordingMode = .idle
        // Capture the frontmost app before panel appears
        let frontApp = NSWorkspace.shared.frontmostApplication
        state.sourceAppBundleID = frontApp?.bundleIdentifier
        state.sourceAppName = frontApp?.localizedName
        logger.notice(
          "Panel shown, target app: \(frontApp?.localizedName ?? "unknown", privacy: .public)"
        )
        return .none

      case .hidePanel:
        state.panelVisible = false
        state.recordingMode = .idle
        state.textBlocks = []
        state.interimText = nil
        state.error = nil
        state.activeSegmentID = nil
        state.lastChunkTimestamp = nil
        state.pendingChunkIDs = []
        state.sessionHasProducedBlocks = false
        state.sessionDividerVisible = false
        state.isAwaitingDispatch = false
        logger.notice("Panel hidden, text cleared")
        if state.isActive {
          return .send(.stopListening)
        }
        return .none

      // MARK: - Recording Modes

      case .startPushToTalk:
        let isActive = state.isActive
        let panelVis = state.panelVisible
        logger.notice("startPushToTalk: isActive=\(isActive) panelVisible=\(panelVis)")
        state.recordingMode = .pushToTalk
        // Cancel any deferred stop from a previous PTT release
        let cancelDeferred = Effect<Action>.cancel(id: CancelID.deferredPTTStop)
        if state.isActive {
          return cancelDeferred
        }
        return .merge(cancelDeferred, .send(.startListening))

      case .stopPushToTalk:
        let mode = state.recordingMode
        logger.notice("stopPushToTalk: recordingMode=\(String(describing: mode))")
        guard state.recordingMode == .pushToTalk else { return .none }
        // Defer the actual stop by 350ms to allow double-tap upgrade to continuous
        return .run { send in
          try await Task.sleep(for: .milliseconds(350))
          await send(.confirmStopPushToTalk)
        }
        .cancellable(id: CancelID.deferredPTTStop, cancelInFlight: true)

      case .confirmStopPushToTalk:
        let mode = state.recordingMode
        let panelVis = state.panelVisible
        logger.notice("confirmStopPushToTalk: recordingMode=\(String(describing: mode)) panelVisible=\(panelVis)")
        // Only stop if still in PTT mode (not upgraded to continuous)
        guard state.recordingMode == .pushToTalk else { return .none }
        state.recordingMode = .idle
        return .send(.stopListening)

      case .toggleContinuousMode:
        // Cancel any deferred PTT stop
        let cancelDeferred = Effect<Action>.cancel(id: CancelID.deferredPTTStop)
        if state.recordingMode == .continuous {
          state.recordingMode = .idle
          logger.notice("Continuous mode toggled OFF")
          return .merge(cancelDeferred, .send(.stopListening))
        } else {
          state.recordingMode = .continuous
          logger.notice("Continuous mode toggled ON")
          if state.isActive {
            return cancelDeferred
          }
          return .merge(cancelDeferred, .send(.startListening))
        }

      case .startListening:
        state.isActive = true
        state.hasCaptureError = false
        state.$isContinuousListeningActive.withLock { $0 = true }
        state.meterLevel = 0
        state.error = nil
        state.interimText = nil
        state.activeSegmentID = nil
        state.lastChunkTimestamp = nil
        state.sessionHasProducedBlocks = false
        state.sessionDividerVisible = false

        let model = hexSettings.selectedModel
        let backend = hexSettings.continuousListeningBackend
        let threshold = hexSettings.streamingConfirmationThreshold
        let minContext = hexSettings.streamingMinConfirmationContext

        logger.notice("Starting continuous listening backend=\(backend.rawValue, privacy: .public) model=\(model, privacy: .public)")

        return .merge(
          // Start audio capture
          .run { send in
            do {
              try await streamingAudio.startCapture()
              logger.notice("Continuous audio capture started")
            } catch {
              logger.error("Failed to start capture: \(error.localizedDescription)")
              await send(.captureError(error.localizedDescription))
              return
            }

            if backend == .streaming {
              do {
                try await streamingTranscription.startStreaming(model, threshold, minContext)
                logger.notice("Streaming transcription started (threshold=\(threshold), minContext=\(minContext))")
              } catch {
                logger.error("Failed to start streaming transcription: \(error.localizedDescription)")
                await send(.streamingError(error.localizedDescription))
              }
            }
          },
          // Observe meter levels
          .run { send in
            for await level in streamingAudio.observeMeterLevels() {
              await send(.meterLevelUpdated(level))
            }
          }
          .cancellable(id: CancelID.meterObservation),
          // Backend-specific effects
          backendEffects(backend: backend, model: model, threshold: threshold, minContext: minContext),
          // Watchdog — if no meter data arrives within 3s, the hardware IO likely failed
          .run { send in
            try await Task.sleep(for: .seconds(3))
            await send(.captureError("No audio data received — microphone may be in use by another app"))
          }
          .cancellable(id: CancelID.watchdog)
        )
        .cancellable(id: CancelID.listening)

      case .stopListening:
        state.isActive = false
        state.hasCaptureError = false
        state.$isContinuousListeningActive.withLock { $0 = false }
        // Don't clear interimText — let in-flight transcriptions replace it
        state.meterLevel = 0
        state.error = nil
        state.activeSegmentID = nil
        state.lastChunkTimestamp = nil

        return .merge(
          .cancel(id: CancelID.meterObservation),
          .cancel(id: CancelID.rawBufferForwarding),
          .cancel(id: CancelID.streamingUpdates),
          .cancel(id: CancelID.chunkObservation),
          .cancel(id: CancelID.interimTimer),
          .cancel(id: CancelID.interimTranscription),
          .cancel(id: CancelID.watchdog),
          .cancel(id: CancelID.recovery),
          .cancel(id: CancelID.segmentSilenceTimer),
          .cancel(id: CancelID.listening),
          .run { _ in
            await streamingTranscription.cancel()
            await streamingAudio.stopCapture()
            logger.notice("Continuous listening stopped")
          }
        )

      case let .meterLevelUpdated(level):
        state.meterLevel = level
        // Audio is flowing — cancel the watchdog and any pending recovery
        if state.hasCaptureError {
          state.hasCaptureError = false
          state.error = nil
          logger.notice("Audio recovered — capture is working again")
        }
        return .merge(
          .cancel(id: CancelID.watchdog),
          .cancel(id: CancelID.recovery)
        )

      // MARK: - Streaming Mode Updates

      case let .streamingUpdate(update):
        let trimmed = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        var output = applyTextProcessing(trimmed)

        if update.isConfirmed {
          let block = TextBlock(
            id: UUID(),
            text: output,
            status: .complete,
            timestamp: Date()
          )
          state.textBlocks.append(block)
          state.interimText = nil

          let totalChars = state.textBlocks.filter { $0.status == .complete }.reduce(0) { $0 + $1.text.count }
          logger.notice("Confirmed text (\(totalChars) total chars): \(output, privacy: .private)")
        } else {
          state.interimText = output
        }
        return .none

      case let .streamingError(message):
        state.error = message
        logger.error("Streaming transcription error: \(message)")
        return .none

      // MARK: - Chunked Mode Updates

      case let .chunkReceived(buffers):
        let now = date.now
        let splittingDisabled = state.recordingMode == .pushToTalk || !hexSettings.segmentSplittingEnabled
        let threshold = hexSettings.segmentSilenceThreshold
        let elapsed = state.lastChunkTimestamp.map { now.timeIntervalSince($0) }
        let wasDividerVisible = state.sessionDividerVisible
        state.lastChunkTimestamp = now
        state.sessionDividerVisible = false

        let chunkID = UUID()
        state.pendingChunkIDs.insert(chunkID)

        let blockID: UUID
        // When splitting is disabled (PTT or toggle off), always merge into the active segment
        if splittingDisabled, let activeID = state.activeSegmentID,
           state.textBlocks[id: activeID] != nil {
          blockID = activeID
          state.textBlocks[id: blockID]?.status = .transcribing
        } else if !splittingDisabled, !wasDividerVisible, let elapsed, elapsed < threshold,
           let activeID = state.activeSegmentID,
           state.textBlocks[id: activeID] != nil {
          // Continuous mode with splitting: merge if within silence threshold
          blockID = activeID
          state.textBlocks[id: blockID]?.status = .transcribing
        } else {
          // New segment
          blockID = UUID()
          let isSessionStart = !splittingDisabled
            && (wasDividerVisible || (!state.sessionHasProducedBlocks && !state.textBlocks.isEmpty))
          let block = TextBlock(
            id: blockID,
            text: "",
            status: .transcribing,
            timestamp: now,
            isSessionStart: isSessionStart
          )
          state.textBlocks.append(block)
          state.activeSegmentID = blockID
          state.sessionHasProducedBlocks = true
        }
        state.interimText = nil

        let model = hexSettings.selectedModel
        let language = hexSettings.outputLanguage

        var effects: [Effect<Action>] = [
          .run { send in
            do {
              let url = try AudioBufferWriter.write(buffers: buffers)
              defer { try? FileManager.default.removeItem(at: url) }

              let decodeOptions = DecodingOptions(
                language: language,
                detectLanguage: language == nil,
                chunkingStrategy: .vad
              )
              let text = try await transcription.transcribe(url, model, decodeOptions) { _ in }
              await send(.chunkTranscribed(blockID: blockID, chunkID: chunkID, text: text))
            } catch {
              await send(.chunkFailed(blockID: blockID, chunkID: chunkID, message: error.localizedDescription))
            }
          },
        ]

        // Only run segment silence timer when splitting is enabled
        if !splittingDisabled {
          effects.append(
            .run { [threshold] send in
              try await Task.sleep(for: .seconds(threshold))
              await send(.segmentSilenceExceeded)
            }
            .cancellable(id: CancelID.segmentSilenceTimer, cancelInFlight: true)
          )
        }

        return .merge(effects)

      case let .chunkTranscribed(blockID, chunkID, text):
        state.pendingChunkIDs.remove(chunkID)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          // If block text is still empty and no more pending chunks, remove the block
          if let block = state.textBlocks[id: blockID],
             block.text.isEmpty && state.pendingChunkIDs.isEmpty {
            state.textBlocks.remove(id: blockID)
            if state.activeSegmentID == blockID { state.activeSegmentID = nil }
          }
          // Auto-dispatch if we were waiting for transcriptions to complete
          if state.pendingChunkIDs.isEmpty && state.isAwaitingDispatch {
            return .send(.dispatchText)
          }
          return .none
        }

        let output = applyTextProcessing(trimmed)
        if let existing = state.textBlocks[id: blockID]?.text, !existing.isEmpty {
          state.textBlocks[id: blockID]?.text = existing + " " + output
        } else {
          state.textBlocks[id: blockID]?.text = output
        }
        if state.pendingChunkIDs.isEmpty {
          state.textBlocks[id: blockID]?.status = .complete
        }

        let totalChars = state.textBlocks.filter { $0.status == .complete }.reduce(0) { $0 + $1.text.count }
        logger.notice("Chunk transcribed (\(totalChars) total chars): \(output, privacy: .private)")

        // Auto-dispatch if we were waiting for transcriptions to complete
        if state.pendingChunkIDs.isEmpty && state.isAwaitingDispatch {
          return .send(.dispatchText)
        }
        return .none

      case let .chunkFailed(blockID, chunkID, message):
        state.pendingChunkIDs.remove(chunkID)
        state.textBlocks[id: blockID]?.status = .error(message)
        logger.error("Chunk transcription failed: \(message)")

        // Auto-dispatch if we were waiting for transcriptions to complete
        if state.pendingChunkIDs.isEmpty && state.isAwaitingDispatch {
          return .send(.dispatchText)
        }
        return .none

      case .interimTimerFired:
        let model = hexSettings.selectedModel
        let language = hexSettings.outputLanguage

        return .run { [streamingAudio] send in
          let buffers = await streamingAudio.peekBuffers()
          guard !buffers.isEmpty else { return }
          do {
            let url = try AudioBufferWriter.write(buffers: buffers)
            defer { try? FileManager.default.removeItem(at: url) }
            let decodeOptions = DecodingOptions(
              language: language,
              detectLanguage: language == nil,
              chunkingStrategy: .vad
            )
            let text = try await transcription.transcribe(url, model, decodeOptions) { _ in }
            await send(.interimTranscriptionResult(text))
          } catch {
            logger.debug("Interim transcription failed: \(error.localizedDescription)")
          }
        }
        .cancellable(id: CancelID.interimTranscription, cancelInFlight: true)

      case let .interimTranscriptionResult(text):
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
          state.interimText = nil
        } else {
          state.interimText = applyTextProcessing(trimmed)
        }
        return .none

      case .segmentSilenceExceeded:
        // Only show divider if we've produced blocks in this session
        guard state.sessionHasProducedBlocks else { return .none }
        state.sessionDividerVisible = true
        state.activeSegmentID = nil
        logger.notice("Segment silence exceeded — session divider shown")
        return .none

      // MARK: - Common

      case let .captureError(message):
        state.hasCaptureError = true
        state.error = message
        state.meterLevel = 0
        logger.error("Capture error: \(message)")
        return .merge(
          .cancel(id: CancelID.meterObservation),
          .cancel(id: CancelID.rawBufferForwarding),
          .cancel(id: CancelID.streamingUpdates),
          .cancel(id: CancelID.chunkObservation),
          .cancel(id: CancelID.interimTimer),
          .cancel(id: CancelID.interimTranscription),
          .cancel(id: CancelID.watchdog),
          .cancel(id: CancelID.segmentSilenceTimer),
          .run { _ in
            await streamingTranscription.cancel()
            await streamingAudio.stopCapture()
          },
          .run { send in
            try await Task.sleep(for: .seconds(5))
            await send(.retryCapture)
          }
          .cancellable(id: CancelID.recovery)
        )

      case .retryCapture:
        guard state.isActive else { return .none }
        logger.notice("Auto-retrying audio capture...")
        state.hasCaptureError = false
        state.error = nil

        let model = hexSettings.selectedModel
        let backend = hexSettings.continuousListeningBackend
        let threshold = hexSettings.streamingConfirmationThreshold
        let minContext = hexSettings.streamingMinConfirmationContext

        return .merge(
          // Restart audio capture
          .run { send in
            do {
              try await streamingAudio.startCapture()
              logger.notice("Capture retry succeeded")
            } catch {
              logger.error("Capture retry failed: \(error.localizedDescription)")
              await send(.captureError(error.localizedDescription))
              return
            }

            if backend == .streaming {
              do {
                try await streamingTranscription.startStreaming(model, threshold, minContext)
                logger.notice("Streaming transcription retry succeeded")
              } catch {
                logger.error("Streaming transcription retry failed: \(error.localizedDescription)")
                await send(.streamingError(error.localizedDescription))
              }
            }
          },
          // Re-observe meter levels
          .run { send in
            for await level in streamingAudio.observeMeterLevels() {
              await send(.meterLevelUpdated(level))
            }
          }
          .cancellable(id: CancelID.meterObservation),
          // Backend-specific effects
          backendEffects(backend: backend, model: model, threshold: threshold, minContext: minContext),
          // New watchdog
          .run { send in
            try await Task.sleep(for: .seconds(3))
            await send(.captureError("No audio data received — microphone may be in use by another app"))
          }
          .cancellable(id: CancelID.watchdog)
        )

      case .clearText:
        let blockCount = state.textBlocks.count
        state.textBlocks = []
        state.interimText = nil
        state.error = nil
        state.activeSegmentID = nil
        state.lastChunkTimestamp = nil
        state.pendingChunkIDs = []
        state.sessionHasProducedBlocks = false
        state.sessionDividerVisible = false
        state.isAwaitingDispatch = false
        logger.notice("Cleared \(blockCount) text blocks")
        return .cancel(id: CancelID.segmentSilenceTimer)

      case .dispatchText:
        // If transcriptions are still in flight, defer dispatch until they complete
        if !state.pendingChunkIDs.isEmpty {
          state.isAwaitingDispatch = true
          let pendingCount = state.pendingChunkIDs.count
          logger.notice("Dispatch deferred — waiting for \(pendingCount) pending transcription(s)")
          return .none
        }
        state.isAwaitingDispatch = false

        var text = ""
        for block in state.textBlocks where block.status == .complete {
          if !text.isEmpty {
            text += block.isSessionStart ? "\n" : " "
          }
          text += block.text
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }

        // Clear completed blocks
        state.textBlocks = state.textBlocks.filter { $0.status != .complete }
        logger.notice("Dispatching \(text.count) characters to target app")

        let modeDesc = String(describing: state.recordingMode)
        let active = state.isActive
        logger.notice("Dispatching: recordingMode=\(modeDesc) isActive=\(active)")

        return .run { send in
          soundEffects.play(.pasteTranscript)
          await pasteboard.paste(text)
          await send(.textDispatched)
        }

      case .textDispatched:
        // Reset segment tracking for the next batch of dictation
        state.activeSegmentID = nil
        state.lastChunkTimestamp = nil
        state.sessionHasProducedBlocks = false
        state.sessionDividerVisible = false
        let dispatchedMode = String(describing: state.recordingMode)
        let dispatchedActive = state.isActive
        logger.notice("Text dispatched: recordingMode=\(dispatchedMode) isActive=\(dispatchedActive)")
        return .none
      }
    }
  }

  // MARK: - Helpers

  private func applyTextProcessing(_ text: String) -> String {
    var output = text
    if hexSettings.wordRemovalsEnabled {
      output = WordRemovalApplier.apply(output, removals: hexSettings.wordRemovals)
    }
    output = WordRemappingApplier.apply(output, remappings: hexSettings.wordRemappings)
    return output
  }

  private func backendEffects(
    backend: ContinuousListeningBackend,
    model: String,
    threshold: Double,
    minContext: Double
  ) -> Effect<Action> {
    switch backend {
    case .streaming:
      return .merge(
        // Forward raw audio buffers to streaming transcription
        .run { _ in
          for await buffer in streamingAudio.observeRawBuffers() {
            await streamingTranscription.streamAudio(buffer)
          }
        }
        .cancellable(id: CancelID.rawBufferForwarding),
        // Observe streaming transcription updates
        .run { send in
          for await update in streamingTranscription.observeUpdates() {
            await send(.streamingUpdate(update))
          }
        }
        .cancellable(id: CancelID.streamingUpdates)
      )

    case .chunked:
      return .merge(
        // Observe VAD-triggered audio chunks
        .run { send in
          for await buffers in streamingAudio.observeAudioChunks() {
            await send(.chunkReceived(buffers))
          }
        }
        .cancellable(id: CancelID.chunkObservation),
        // Interim timer — periodically transcribe accumulated buffers for gray preview text
        .run { send in
          while true {
            try await Task.sleep(for: .seconds(1.5))
            await send(.interimTimerFired)
          }
        }
        .cancellable(id: CancelID.interimTimer)
      )
    }
  }
}

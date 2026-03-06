//
//  ContinuousListeningFeature.swift
//  Hex
//

import AppKit
import AVFoundation
import ComposableArchitecture
import Foundation
import HexCore
import IdentifiedCollections
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

// MARK: - Types

enum EmissionMode: Equatable {
  case inactive
  case pushToTalk
  case continuous
}

struct TranscriptEntry: Equatable, Identifiable {
  let id: UUID
  let text: String
  let timestamp: Date
}

@Reducer
struct ContinuousListeningFeature {

  @ObservableState
  struct State: Equatable {
    var panelVisible: Bool = false
    var isCapturing: Bool = false
    var meterLevel: Float = 0
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var error: String?
    var hasCaptureError: Bool = false

    // Rolling text buffer (panel display)
    var transcriptEntries: IdentifiedArrayOf<TranscriptEntry> = []
    var currentUtteranceText: String = ""
    var isSpeaking: Bool = false

    // Cursor emission
    var emissionMode: EmissionMode = .inactive
    var emissionAnchorText: String = ""
    var lastEmittedText: String = ""

    // Transcription pipeline
    var pendingTranscription: Bool = false
    var lastFullTranscription: String = ""
    var sessionStartTime: Date?

    @Shared(.isContinuousListeningActive) var isContinuousListeningActive: Bool = false
  }

  enum Action {
    // Panel lifecycle (implicitly controls capture)
    case showPanel
    case hidePanel
    // Capture (internal)
    case captureStarted
    case meterLevelUpdated(Float)
    case captureError(String)
    case retryCapture
    // Cursor emission (driven by hotkey)
    case startEmission(EmissionMode)
    case stopEmission
    case confirmStopEmission
    // Transcription pipeline
    case vadStateChanged(VADEvent)
    case streamingTickFired
    case transcriptionCompleted(String)
    case finalTranscriptionCompleted(String)
    case deltaEmitted
    // Buffer management
    case pruneExpiredEntries
  }

  private enum CancelID {
    case capture
    case meterObservation
    case vadObservation
    case streamingTick
    case transcription
    case watchdog
    case recovery
    case deferredEmissionStop
    case pruneTimer
  }

  @Dependency(\.streamingAudio) var streamingAudio
  @Dependency(\.transcription) var transcription
  @Dependency(\.textEmission) var textEmission
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.soundEffects) var soundEffects
  @Dependency(\.date) var date
  @Dependency(\.uuid) var uuid
  @Shared(.hexSettings) var hexSettings: HexSettings

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {

      // MARK: - Panel Lifecycle

      case .showPanel:
        guard !state.panelVisible else { return .none }
        state.panelVisible = true
        state.isCapturing = true
        state.hasCaptureError = false
        state.meterLevel = 0
        state.error = nil
        state.sessionStartTime = date.now
        state.$isContinuousListeningActive.withLock { $0 = true }

        let frontApp = NSWorkspace.shared.frontmostApplication
        state.sourceAppBundleID = frontApp?.bundleIdentifier
        state.sourceAppName = frontApp?.localizedName
        logger.notice(
          "Panel shown + capture started [build:v2-decoupled], target app: \(frontApp?.localizedName ?? "unknown", privacy: .public)"
        )

        return .merge(
          // Start audio capture
          .run { send in
            do {
              try await streamingAudio.startCapture()
              await send(.captureStarted)
            } catch {
              logger.error("Failed to start capture: \(error.localizedDescription)")
              await send(.captureError(error.localizedDescription))
            }
          },
          // Observe meter levels
          .run { send in
            for await level in streamingAudio.observeMeterLevels() {
              await send(.meterLevelUpdated(level))
            }
          }
          .cancellable(id: CancelID.meterObservation),
          // Observe VAD state transitions
          .run { send in
            for await event in streamingAudio.observeVADState() {
              await send(.vadStateChanged(event))
            }
          }
          .cancellable(id: CancelID.vadObservation),
          // Watchdog
          .run { send in
            try await Task.sleep(for: .seconds(3))
            await send(.captureError("No audio data received — microphone may be in use by another app"))
          }
          .cancellable(id: CancelID.watchdog),
          // Prune timer
          .run { send in
            while true {
              try await Task.sleep(for: .seconds(1))
              await send(.pruneExpiredEntries)
            }
          }
          .cancellable(id: CancelID.pruneTimer)
        )
        .cancellable(id: CancelID.capture)

      case .hidePanel:
        let wasCapturing = state.isCapturing
        // Reset everything
        state.panelVisible = false
        state.isCapturing = false
        state.emissionMode = .inactive
        state.meterLevel = 0
        state.error = nil
        state.hasCaptureError = false
        state.transcriptEntries = []
        state.currentUtteranceText = ""
        state.isSpeaking = false
        state.emissionAnchorText = ""
        state.lastEmittedText = ""
        state.pendingTranscription = false
        state.lastFullTranscription = ""
        state.sessionStartTime = nil
        state.$isContinuousListeningActive.withLock { $0 = false }
        logger.notice("Panel hidden, all state reset")

        guard wasCapturing else { return .none }
        return .merge(
          .cancel(id: CancelID.meterObservation),
          .cancel(id: CancelID.vadObservation),
          .cancel(id: CancelID.streamingTick),
          .cancel(id: CancelID.transcription),
          .cancel(id: CancelID.watchdog),
          .cancel(id: CancelID.recovery),
          .cancel(id: CancelID.capture),
          .cancel(id: CancelID.deferredEmissionStop),
          .cancel(id: CancelID.pruneTimer),
          .run { _ in
            await streamingAudio.stopCapture()
            logger.notice("Audio capture stopped")
          }
        )

      case .captureStarted:
        return .none

      // MARK: - Emission Lifecycle

      case let .startEmission(mode):
        guard state.panelVisible else { return .none }

        if mode == .continuous && state.emissionMode == .continuous {
          // Toggle off
          state.emissionMode = .inactive
          logger.notice("Continuous emission toggled OFF")
          return .cancel(id: CancelID.deferredEmissionStop)
        }

        state.emissionMode = mode
        state.emissionAnchorText = state.lastFullTranscription
        state.lastEmittedText = ""
        let anchorPreview = String(state.emissionAnchorText.prefix(40))
        logger.notice(
          "Emission started: \(String(describing: mode), privacy: .public), anchor=\(anchorPreview, privacy: .private(mask: .hash))"
        )
        return .cancel(id: CancelID.deferredEmissionStop)

      case .stopEmission:
        switch state.emissionMode {
        case .pushToTalk:
          return .run { send in
            try await Task.sleep(for: .milliseconds(350))
            await send(.confirmStopEmission)
          }
          .cancellable(id: CancelID.deferredEmissionStop, cancelInFlight: true)
        case .continuous:
          state.emissionMode = .inactive
          logger.notice("Continuous emission stopped")
          return .none
        case .inactive:
          return .none
        }

      case .confirmStopEmission:
        guard state.emissionMode == .pushToTalk else { return .none }
        state.emissionMode = .inactive
        logger.notice("PTT emission confirmed stop")
        return .none

      // MARK: - Streaming Pipeline

      case let .vadStateChanged(event):
        switch event {
        case .speechStarted:
          state.isSpeaking = true
          logger.notice("Speech started — beginning streaming transcription")
          return .run { send in
            while true {
              try await Task.sleep(for: .milliseconds(400))
              await send(.streamingTickFired)
            }
          }
          .cancellable(id: CancelID.streamingTick, cancelInFlight: true)

        case .speechEnded:
          state.isSpeaking = false
          logger.notice("Speech ended — running final transcription")
          let model = hexSettings.selectedModel
          let language = hexSettings.outputLanguage

          return .merge(
            .cancel(id: CancelID.streamingTick),
            .run { [streamingAudio] send in
              let buffers = await streamingAudio.flushBuffers()
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
                await send(.finalTranscriptionCompleted(text))
              } catch {
                logger.error("Final transcription failed: \(error.localizedDescription)")
              }
            }
            .cancellable(id: CancelID.transcription, cancelInFlight: true)
          )
        }

      case .streamingTickFired:
        guard !state.pendingTranscription else { return .none }
        state.pendingTranscription = true
        let model = hexSettings.selectedModel
        let language = hexSettings.outputLanguage

        return .run { [streamingAudio] send in
          let buffers = await streamingAudio.peekBuffers()
          guard !buffers.isEmpty else {
            await send(.transcriptionCompleted(""))
            return
          }
          do {
            let url = try AudioBufferWriter.write(buffers: buffers)
            defer { try? FileManager.default.removeItem(at: url) }
            let decodeOptions = DecodingOptions(
              language: language,
              detectLanguage: language == nil,
              chunkingStrategy: .vad
            )
            let text = try await transcription.transcribe(url, model, decodeOptions) { _ in }
            await send(.transcriptionCompleted(text))
          } catch {
            logger.debug("Streaming transcription failed: \(error.localizedDescription)")
            await send(.transcriptionCompleted(""))
          }
        }
        .cancellable(id: CancelID.transcription, cancelInFlight: true)

      case let .transcriptionCompleted(rawText):
        state.pendingTranscription = false
        let text = applyTextProcessing(rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return .none }

        // ALWAYS update panel display
        state.currentUtteranceText = text
        state.lastFullTranscription = text
        logger.debug("Live preview: \(text.prefix(60), privacy: .private(mask: .hash))")

        // IF emitting: compute delta and type to cursor
        guard state.emissionMode != .inactive else { return .none }

        let emittableText: String
        if !state.emissionAnchorText.isEmpty && text.hasPrefix(state.emissionAnchorText) {
          emittableText = String(text.dropFirst(state.emissionAnchorText.count))
        } else if !state.emissionAnchorText.isEmpty {
          // Anchor doesn't match as prefix — try word-level stripping
          let anchorWords = state.emissionAnchorText.split(separator: " ", omittingEmptySubsequences: true)
          let textWords = text.split(separator: " ", omittingEmptySubsequences: true)
          if textWords.count > anchorWords.count {
            let newWords = textWords[anchorWords.count...]
            emittableText = " " + newWords.joined(separator: " ")
          } else {
            emittableText = ""
          }
        } else {
          emittableText = text
        }

        guard !emittableText.isEmpty else { return .none }

        // Diff against lastEmittedText — only append (no corrections during streaming)
        let delta = TranscriptionDiff.compute(old: state.lastEmittedText, new: state.lastEmittedText + emittableText)
        guard !delta.isEmpty, delta.deleteCount == 0 else { return .none }

        let insertText = delta.insertText
        state.lastEmittedText += insertText

        return .run { send in
          await textEmission.typeText(insertText)
          await send(.deltaEmitted)
        }

      case let .finalTranscriptionCompleted(rawText):
        state.pendingTranscription = false
        let text = applyTextProcessing(rawText.trimmingCharacters(in: .whitespacesAndNewlines))

        // Commit entry to rolling buffer
        if !text.isEmpty {
          let entry = TranscriptEntry(id: uuid(), text: text, timestamp: date.now)
          state.transcriptEntries.append(entry)
          let entryCount = state.transcriptEntries.count
          logger.notice("Entry committed (\(entryCount) total): \(text.prefix(60), privacy: .private(mask: .hash))")
        }
        state.currentUtteranceText = ""

        // IF emitting: apply final correction delta
        if state.emissionMode != .inactive && !text.isEmpty {
          let emittableText: String
          if !state.emissionAnchorText.isEmpty {
            let anchorWords = state.emissionAnchorText.split(separator: " ", omittingEmptySubsequences: true)
            let textWords = text.split(separator: " ", omittingEmptySubsequences: true)
            if textWords.count > anchorWords.count {
              emittableText = " " + textWords[anchorWords.count...].joined(separator: " ")
            } else if state.emissionAnchorText.isEmpty {
              emittableText = text
            } else {
              emittableText = ""
            }
          } else {
            emittableText = text
          }

          if !emittableText.isEmpty {
            let delta = TranscriptionDiff.compute(old: state.lastEmittedText, new: emittableText)

            if !delta.isEmpty {
              let deleteCount = delta.deleteCount
              let insertText = delta.insertText
              state.lastEmittedText = emittableText

              // Reset anchor for next utterance
              state.lastFullTranscription = ""
              state.emissionAnchorText = ""

              return .run { send in
                if deleteCount > 0 {
                  await textEmission.deleteBackward(deleteCount)
                }
                if !insertText.isEmpty {
                  await textEmission.typeText(insertText)
                }
                await send(.deltaEmitted)
              }
            }
          }
        }

        // Reset for next utterance
        state.lastFullTranscription = ""
        state.emissionAnchorText = ""
        state.lastEmittedText = ""
        return .none

      case .deltaEmitted:
        return .none

      // MARK: - Buffer Management

      case .pruneExpiredEntries:
        let now = date.now
        state.transcriptEntries.removeAll { entry in
          now.timeIntervalSince(entry.timestamp) > 60
        }
        return .none

      // MARK: - Capture Errors

      case let .meterLevelUpdated(level):
        state.meterLevel = level
        if state.hasCaptureError {
          state.hasCaptureError = false
          state.error = nil
          logger.notice("Audio recovered — capture is working again")
        }
        return .merge(
          .cancel(id: CancelID.watchdog),
          .cancel(id: CancelID.recovery)
        )

      case let .captureError(message):
        state.hasCaptureError = true
        state.error = message
        state.meterLevel = 0
        logger.error("Capture error: \(message)")
        return .merge(
          .cancel(id: CancelID.meterObservation),
          .cancel(id: CancelID.vadObservation),
          .cancel(id: CancelID.streamingTick),
          .cancel(id: CancelID.transcription),
          .cancel(id: CancelID.watchdog),
          .run { _ in
            await streamingAudio.stopCapture()
          },
          .run { send in
            try await Task.sleep(for: .seconds(5))
            await send(.retryCapture)
          }
          .cancellable(id: CancelID.recovery)
        )

      case .retryCapture:
        guard state.isCapturing else { return .none }
        logger.notice("Auto-retrying audio capture...")
        state.hasCaptureError = false
        state.error = nil

        return .merge(
          .run { send in
            do {
              try await streamingAudio.startCapture()
              logger.notice("Capture retry succeeded")
            } catch {
              logger.error("Capture retry failed: \(error.localizedDescription)")
              await send(.captureError(error.localizedDescription))
            }
          },
          .run { send in
            for await level in streamingAudio.observeMeterLevels() {
              await send(.meterLevelUpdated(level))
            }
          }
          .cancellable(id: CancelID.meterObservation),
          .run { send in
            for await event in streamingAudio.observeVADState() {
              await send(.vadStateChanged(event))
            }
          }
          .cancellable(id: CancelID.vadObservation),
          .run { send in
            try await Task.sleep(for: .seconds(3))
            await send(.captureError("No audio data received — microphone may be in use by another app"))
          }
          .cancellable(id: CancelID.watchdog)
        )
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
}

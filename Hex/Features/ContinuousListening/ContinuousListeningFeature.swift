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

// MARK: - Text Block Model

struct TextBlock: Equatable, Identifiable {
  let id: UUID
  var text: String
  var status: Status
  let timestamp: Date

  enum Status: Equatable {
    case transcribing
    case complete
    case error(String)
  }
}

@Reducer
struct ContinuousListeningFeature {
  @ObservableState
  struct State {
    var isActive: Bool = false
    var textBlocks: IdentifiedArrayOf<TextBlock> = []
    var interimText: String?
    var meterLevel: Float = 0
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var error: String?
    var hasCaptureError: Bool = false
    @Shared(.isContinuousListeningActive) var isContinuousListeningActive: Bool = false
  }

  enum Action {
    case toggleMode
    case startListening
    case stopListening
    case meterLevelUpdated(Float)
    case audioChunkReceived([AVAudioPCMBuffer])
    case chunkTranscriptionResult(id: UUID, text: String)
    case chunkTranscriptionError(id: UUID, error: Error)
    case captureError(String)
    case retryCapture
    case interimTimerFired
    case interimTranscriptionResult(String)
    case dispatchText
    case clearText
    case textDispatched
  }

  private enum CancelID {
    case listening
    case meterObservation
    case chunkObservation
    case interimTimer
    case interimTranscription
    case watchdog
    case recovery
  }

  @Dependency(\.streamingAudio) var streamingAudio
  @Dependency(\.transcription) var transcription
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.soundEffects) var soundEffects
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

      case .startListening:
        state.isActive = true
        state.hasCaptureError = false
        state.$isContinuousListeningActive.withLock { $0 = true }
        state.textBlocks = []
        state.meterLevel = 0
        state.error = nil

        return .merge(
          // Start audio capture
          .run { send in
            do {
              try await streamingAudio.startCapture()
              logger.notice("Continuous audio capture started")
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
          // Observe VAD-triggered audio chunks
          .run { send in
            for await chunk in streamingAudio.observeAudioChunks() {
              await send(.audioChunkReceived(chunk))
            }
          }
          .cancellable(id: CancelID.chunkObservation),
          // Interim transcription timer — peek at buffers every 2s for live preview
          .run { send in
            while !Task.isCancelled {
              try await Task.sleep(for: .seconds(2))
              await send(.interimTimerFired)
            }
          }
          .cancellable(id: CancelID.interimTimer),
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
        state.textBlocks = []
        state.interimText = nil
        state.meterLevel = 0
        state.sourceAppBundleID = nil
        state.sourceAppName = nil
        state.error = nil

        return .merge(
          .cancel(id: CancelID.meterObservation),
          .cancel(id: CancelID.chunkObservation),
          .cancel(id: CancelID.interimTimer),
          .cancel(id: CancelID.interimTranscription),
          .cancel(id: CancelID.watchdog),
          .cancel(id: CancelID.recovery),
          .cancel(id: CancelID.listening),
          .run { _ in
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

      case .interimTimerFired:
        guard state.isActive else { return .none }
        let model = hexSettings.selectedModel

        return .run { send in
          let buffers = await streamingAudio.peekBuffers()
          guard !buffers.isEmpty else { return }

          let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hex-interim-\(UUID().uuidString).wav")

          do {
            try AudioBufferWriter.writeWAV(buffers: buffers, to: tempURL)
            let decodeOptions = DecodingOptions(
              language: nil,
              detectLanguage: true,
              chunkingStrategy: .vad
            )
            let result = try await transcription.transcribe(tempURL, model, decodeOptions) { _ in }
            try? FileManager.default.removeItem(at: tempURL)
            await send(.interimTranscriptionResult(result))
          } catch {
            try? FileManager.default.removeItem(at: tempURL)
          }
        }
        .cancellable(id: CancelID.interimTranscription, cancelInFlight: true)

      case let .interimTranscriptionResult(text):
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        state.interimText = trimmed.isEmpty ? nil : trimmed
        return .none

      case let .audioChunkReceived(buffers):
        // Real chunk arrived — clear interim text and cancel any in-flight interim transcription
        state.interimText = nil
        guard state.isActive, !buffers.isEmpty else { return .none }

        let blockID = UUID()
        let block = TextBlock(
          id: blockID,
          text: "",
          status: .transcribing,
          timestamp: Date()
        )
        state.textBlocks.append(block)

        // Capture settings values before the closure to avoid capturing self
        let model = hexSettings.selectedModel
        let wordRemovalsEnabled = hexSettings.wordRemovalsEnabled
        let wordRemovals = hexSettings.wordRemovals
        let wordRemappings = hexSettings.wordRemappings

        return .run { send in
          let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hex-continuous-\(blockID.uuidString).wav")

          do {
            try AudioBufferWriter.writeWAV(buffers: buffers, to: tempURL)
            logger.notice(
              "Wrote \(buffers.count) buffer(s) to \(tempURL.lastPathComponent, privacy: .public)"
            )

            let decodeOptions = DecodingOptions(
              language: nil,
              detectLanguage: true,
              chunkingStrategy: .vad
            )
            let result = try await transcription.transcribe(tempURL, model, decodeOptions) { _ in }
            try? FileManager.default.removeItem(at: tempURL)

            // Apply word removals and remappings
            var output = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if wordRemovalsEnabled {
              output = WordRemovalApplier.apply(output, removals: wordRemovals)
            }
            output = WordRemappingApplier.apply(output, remappings: wordRemappings)

            await send(.chunkTranscriptionResult(id: blockID, text: output))
          } catch {
            try? FileManager.default.removeItem(at: tempURL)
            logger.error("Chunk transcription failed: \(error.localizedDescription)")
            await send(.chunkTranscriptionError(id: blockID, error: error))
          }
        }

      case let .chunkTranscriptionResult(id, text):
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
          // Remove empty blocks
          state.textBlocks.remove(id: id)
        } else {
          state.textBlocks[id: id]?.text = trimmed
          state.textBlocks[id: id]?.status = .complete
        }

        let totalChars = state.textBlocks.filter { $0.status == .complete }.reduce(0) { $0 + $1.text.count }
        logger.notice("Accumulated text length: \(totalChars)")
        return .none

      case let .chunkTranscriptionError(id, error):
        state.textBlocks[id: id]?.status = .error(error.localizedDescription)
        state.error = error.localizedDescription
        logger.error("Transcription error: \(error.localizedDescription)")
        return .none

      case let .captureError(message):
        state.hasCaptureError = true
        state.error = message
        state.meterLevel = 0
        logger.error("Capture error: \(message)")
        // Stop streams and schedule auto-retry in 5 seconds
        return .merge(
          .cancel(id: CancelID.meterObservation),
          .cancel(id: CancelID.chunkObservation),
          .cancel(id: CancelID.interimTimer),
          .cancel(id: CancelID.interimTranscription),
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
        guard state.isActive else { return .none }
        logger.notice("Auto-retrying audio capture...")
        state.hasCaptureError = false
        state.error = nil

        return .merge(
          // Restart audio capture
          .run { send in
            do {
              try await streamingAudio.startCapture()
              logger.notice("Capture retry succeeded")
            } catch {
              logger.error("Capture retry failed: \(error.localizedDescription)")
              await send(.captureError(error.localizedDescription))
            }
          },
          // Re-observe meter levels
          .run { send in
            for await level in streamingAudio.observeMeterLevels() {
              await send(.meterLevelUpdated(level))
            }
          }
          .cancellable(id: CancelID.meterObservation),
          // Re-observe audio chunks
          .run { send in
            for await chunk in streamingAudio.observeAudioChunks() {
              await send(.audioChunkReceived(chunk))
            }
          }
          .cancellable(id: CancelID.chunkObservation),
          // Restart interim timer
          .run { send in
            while !Task.isCancelled {
              try await Task.sleep(for: .seconds(2))
              await send(.interimTimerFired)
            }
          }
          .cancellable(id: CancelID.interimTimer),
          // New watchdog for this attempt
          .run { send in
            try await Task.sleep(for: .seconds(3))
            await send(.captureError("No audio data received — microphone may be in use by another app"))
          }
          .cancellable(id: CancelID.watchdog)
        )

      case .clearText:
        let blockCount = state.textBlocks.count
        state.textBlocks = []
        state.error = nil
        logger.notice("Cleared \(blockCount) text blocks")
        return .none

      case .dispatchText:
        let text = state.textBlocks
          .filter { $0.status == .complete }
          .map(\.text)
          .joined(separator: " ")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }

        // Clear completed blocks
        state.textBlocks = state.textBlocks.filter { $0.status == .transcribing }
        logger.notice("Dispatching \(text.count) characters to target app")

        return .run { send in
          soundEffects.play(.pasteTranscript)
          await pasteboard.paste(text)
          await send(.textDispatched)
        }

      case .textDispatched:
        logger.notice("Text dispatched successfully")
        return .none
      }
    }
  }
}

// MARK: - Audio Buffer WAV Writer

enum AudioBufferWriter {
  /// Writes an array of AVAudioPCMBuffers to a 16kHz mono WAV file.
  static func writeWAV(buffers: [AVAudioPCMBuffer], to url: URL) throws {
    guard let firstBuffer = buffers.first else {
      throw AudioBufferWriterError.noBuffers
    }

    let sourceFormat = firstBuffer.format
    let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16000,
      channels: 1,
      interleaved: false
    )!

    let needsConversion = sourceFormat.sampleRate != 16000 || sourceFormat.channelCount != 1

    guard let outputFile = try? AVAudioFile(
      forWriting: url,
      settings: targetFormat.settings,
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    ) else {
      throw AudioBufferWriterError.cannotCreateFile
    }

    if needsConversion {
      guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
        throw AudioBufferWriterError.cannotCreateConverter
      }

      for buffer in buffers {
        let ratio = 16000.0 / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(
          pcmFormat: targetFormat,
          frameCapacity: outputFrameCount
        ) else { continue }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
          if consumed {
            outStatus.pointee = .noDataNow
            return nil
          }
          consumed = true
          outStatus.pointee = .haveData
          return buffer
        }

        if let error {
          logger.error("Conversion error: \(error.localizedDescription)")
          continue
        }

        try outputFile.write(from: outputBuffer)
      }
    } else {
      for buffer in buffers {
        try outputFile.write(from: buffer)
      }
    }
  }

  enum AudioBufferWriterError: Error, LocalizedError {
    case noBuffers
    case cannotCreateFile
    case cannotCreateConverter

    var errorDescription: String? {
      switch self {
      case .noBuffers: "No audio buffers to write"
      case .cannotCreateFile: "Cannot create output WAV file"
      case .cannotCreateConverter: "Cannot create audio format converter"
      }
    }
  }
}

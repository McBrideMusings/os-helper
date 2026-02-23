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

@Reducer
struct ContinuousListeningFeature {
  @ObservableState
  struct State {
    var isActive: Bool = false
    var accumulatedText: String = ""
    var isTranscribingChunk: Bool = false
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var error: String?
    @Shared(.isContinuousListeningActive) var isContinuousListeningActive: Bool = false
  }

  enum Action {
    case toggleMode
    case startListening
    case stopListening
    case chunkTimerFired
    case chunkTranscriptionResult(String)
    case chunkTranscriptionError(Error)
    case dispatchText
    case textDispatched
  }

  private enum CancelID {
    case chunkTimer
    case listening
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
        state.$isContinuousListeningActive.withLock { $0 = true }
        state.accumulatedText = ""
        state.error = nil
        state.isTranscribingChunk = false

        return .merge(
          // Start audio capture
          .run { send in
            do {
              try await streamingAudio.startCapture()
              logger.notice("Continuous audio capture started")
            } catch {
              logger.error("Failed to start capture: \(error.localizedDescription)")
              await send(.chunkTranscriptionError(error))
            }
          },
          // Start 5s repeating timer
          .run { send in
            while !Task.isCancelled {
              try await Task.sleep(for: .seconds(5))
              await send(.chunkTimerFired)
            }
          }
          .cancellable(id: CancelID.chunkTimer)
        )
        .cancellable(id: CancelID.listening)

      case .stopListening:
        state.isActive = false
        state.$isContinuousListeningActive.withLock { $0 = false }
        state.accumulatedText = ""
        state.isTranscribingChunk = false
        state.sourceAppBundleID = nil
        state.sourceAppName = nil
        state.error = nil

        return .merge(
          .cancel(id: CancelID.chunkTimer),
          .cancel(id: CancelID.listening),
          .run { _ in
            await streamingAudio.stopCapture()
            logger.notice("Continuous listening stopped")
          }
        )

      case .chunkTimerFired:
        guard state.isActive, !state.isTranscribingChunk else {
          if state.isTranscribingChunk {
            logger.debug("Skipping chunk — previous transcription still in progress")
          }
          return .none
        }

        state.isTranscribingChunk = true
        let model = hexSettings.selectedModel

        return .run { send in
          let buffers = await streamingAudio.flushBuffers()
          guard !buffers.isEmpty else {
            logger.debug("No audio buffers to transcribe")
            await send(.chunkTranscriptionResult(""))
            return
          }

          let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hex-continuous-\(UUID().uuidString).wav")

          do {
            try AudioBufferWriter.writeWAV(buffers: buffers, to: tempURL)
            logger.notice("Wrote \(buffers.count) buffer(s) to \(tempURL.lastPathComponent, privacy: .public)")

            let decodeOptions = DecodingOptions(
              language: nil,
              detectLanguage: true,
              chunkingStrategy: .vad
            )
            let result = try await transcription.transcribe(tempURL, model, decodeOptions) { _ in }
            try? FileManager.default.removeItem(at: tempURL)

            await send(.chunkTranscriptionResult(result))
          } catch {
            try? FileManager.default.removeItem(at: tempURL)
            logger.error("Chunk transcription failed: \(error.localizedDescription)")
            await send(.chunkTranscriptionError(error))
          }
        }

      case let .chunkTranscriptionResult(text):
        state.isTranscribingChunk = false

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        // Apply word removals and remappings
        var output = trimmed
        if hexSettings.wordRemovalsEnabled {
          output = WordRemovalApplier.apply(output, removals: hexSettings.wordRemovals)
        }
        output = WordRemappingApplier.apply(output, remappings: hexSettings.wordRemappings)

        guard !output.isEmpty else { return .none }

        if state.accumulatedText.isEmpty {
          state.accumulatedText = output
        } else {
          state.accumulatedText += " " + output
        }

        let textLength = state.accumulatedText.count
        logger.notice("Accumulated text length: \(textLength)")
        return .none

      case let .chunkTranscriptionError(error):
        state.isTranscribingChunk = false
        state.error = error.localizedDescription
        logger.error("Transcription error: \(error.localizedDescription)")
        return .none

      case .dispatchText:
        let text = state.accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }

        state.accumulatedText = ""
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

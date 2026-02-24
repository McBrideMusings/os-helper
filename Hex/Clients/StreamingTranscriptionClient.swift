//
//  StreamingTranscriptionClient.swift
//  Hex
//

import AVFoundation
import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

#if canImport(FluidAudio)
import FluidAudio
#endif

private let logger = HexLog.continuousListening

// MARK: - Streaming Update (framework-agnostic wrapper)

struct StreamingTextUpdate: Equatable, Sendable {
  let text: String
  let isConfirmed: Bool
  let confidence: Float
}

// MARK: - Dependency Client

@DependencyClient
struct StreamingTranscriptionClient {
  var startStreaming: @Sendable (_ model: String, _ confirmationThreshold: Double, _ minConfirmationContext: Double) async throws -> Void
  var streamAudio: @Sendable (_ buffer: AVAudioPCMBuffer) async -> Void
  var observeUpdates: @Sendable () -> AsyncStream<StreamingTextUpdate> = { .finished }
  var finish: @Sendable () async throws -> String = { "" }
  var cancel: @Sendable () async -> Void
}

extension StreamingTranscriptionClient: DependencyKey {
  static var liveValue: Self {
    let live = StreamingTranscriptionClientLive()
    return Self(
      startStreaming: { try await live.startStreaming(model: $0, confirmationThreshold: $1, minConfirmationContext: $2) },
      streamAudio: { await live.streamAudio($0) },
      observeUpdates: { live.observeUpdates() },
      finish: { try await live.finish() },
      cancel: { await live.cancel() }
    )
  }
}

extension DependencyValues {
  var streamingTranscription: StreamingTranscriptionClient {
    get { self[StreamingTranscriptionClient.self] }
    set { self[StreamingTranscriptionClient.self] = newValue }
  }
}

// MARK: - Live Implementation

#if canImport(FluidAudio)

private actor StreamingTranscriptionClientLive {
  private var manager: StreamingAsrManager?
  private let parakeet = ParakeetClient()
  private var updateContinuation: AsyncStream<StreamingTextUpdate>.Continuation?

  func startStreaming(model: String, confirmationThreshold: Double, minConfirmationContext: Double) async throws {
    // Ensure Parakeet models are loaded
    try await parakeet.ensureLoaded(modelName: model) { _ in }

    guard let models = await parakeet.getLoadedModels() else {
      throw NSError(
        domain: "StreamingTranscription",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Failed to get loaded Parakeet models"]
      )
    }

    let config = StreamingAsrConfig(
      chunkSeconds: 11.0,
      hypothesisChunkSeconds: 1.0,
      leftContextSeconds: 2.0,
      rightContextSeconds: 2.0,
      minContextForConfirmation: minConfirmationContext,
      confirmationThreshold: confirmationThreshold
    )
    let mgr = StreamingAsrManager(config: config)
    try await mgr.start(models: models, source: .microphone)
    self.manager = mgr
    logger.notice("Streaming transcription started")

    // Forward transcription updates
    let updates = await mgr.transcriptionUpdates
    Task { [weak self] in
      for await update in updates {
        let wrapped = StreamingTextUpdate(
          text: update.text,
          isConfirmed: update.isConfirmed,
          confidence: update.confidence
        )
        await self?.yieldUpdate(wrapped)
      }
      await self?.finishUpdates()
    }
  }

  func streamAudio(_ buffer: AVAudioPCMBuffer) async {
    await manager?.streamAudio(buffer)
  }

  nonisolated func observeUpdates() -> AsyncStream<StreamingTextUpdate> {
    AsyncStream { continuation in
      Task { await self.setUpdateContinuation(continuation) }
    }
  }

  func finish() async throws -> String {
    guard let manager else { return "" }
    let result = try await manager.finish()
    self.manager = nil
    updateContinuation?.finish()
    updateContinuation = nil
    logger.notice("Streaming transcription finished")
    return result
  }

  func cancel() async {
    guard let manager else { return }
    await manager.cancel()
    self.manager = nil
    updateContinuation?.finish()
    updateContinuation = nil
    logger.notice("Streaming transcription cancelled")
  }

  private func setUpdateContinuation(_ continuation: AsyncStream<StreamingTextUpdate>.Continuation) {
    updateContinuation = continuation
  }

  private func yieldUpdate(_ update: StreamingTextUpdate) {
    updateContinuation?.yield(update)
  }

  private func finishUpdates() {
    updateContinuation?.finish()
    updateContinuation = nil
  }
}

#else

private actor StreamingTranscriptionClientLive {
  func startStreaming(model: String, confirmationThreshold: Double, minConfirmationContext: Double) async throws {
    throw NSError(
      domain: "StreamingTranscription",
      code: -2,
      userInfo: [NSLocalizedDescriptionKey: "FluidAudio not available"]
    )
  }
  func streamAudio(_ buffer: AVAudioPCMBuffer) {}
  nonisolated func observeUpdates() -> AsyncStream<StreamingTextUpdate> { .finished }
  func finish() async throws -> String { "" }
  func cancel() async {}
}

#endif

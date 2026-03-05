import CoreML
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let logger = HexLog.vad

@DependencyClient
struct SileroVADClient {
  var load: @Sendable () async throws -> Void
  var processFrame: @Sendable ([Float]) async -> Float = { _ in 0.0 }
  var resetState: @Sendable () async -> Void
}

extension SileroVADClient: DependencyKey {
  static var liveValue: Self {
    let live = SileroVADClientLive()
    return Self(
      load: { try await live.load() },
      processFrame: { await live.processFrame($0) },
      resetState: { await live.resetState() }
    )
  }
}

extension DependencyValues {
  var sileroVAD: SileroVADClient {
    get { self[SileroVADClient.self] }
    set { self[SileroVADClient.self] = newValue }
  }
}

// MARK: - Live Implementation

private actor SileroVADClientLive {
  private var model: MLModel?

  func load() throws {
    let t0 = Date()
    guard let url = Bundle.main.url(forResource: "silero_vad", withExtension: "mlmodelc") else {
      throw SileroVADError.modelNotFound
    }
    let config = MLModelConfiguration()
    config.computeUnits = .cpuAndNeuralEngine
    model = try MLModel(contentsOf: url, configuration: config)

    // Warmup: one dummy inference to trigger CoreML graph compilation
    let dummy = try MLMultiArray(shape: [1, 512], dataType: .float32)
    let provider = try MLDictionaryFeatureProvider(dictionary: ["audio_chunk": dummy])
    _ = try model?.prediction(from: provider)

    logger.info("Silero VAD loaded and warmed up in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000))ms")
  }

  func processFrame(_ samples: [Float]) -> Float {
    guard let model, samples.count == 512 else { return 0.0 }
    do {
      let input = try MLMultiArray(shape: [1, 512], dataType: .float32)
      for i in 0..<512 {
        input[i] = NSNumber(value: samples[i])
      }
      let provider = try MLDictionaryFeatureProvider(dictionary: ["audio_chunk": input])
      let result = try model.prediction(from: provider)
      guard let output = result.featureValue(for: "vad_probability")?.multiArrayValue else { return 0.0 }
      return output[0].floatValue
    } catch {
      logger.error("VAD inference failed: \(error.localizedDescription)")
      return 0.0
    }
  }

  func resetState() {
    // Model is stateless (no LSTM state to reset), but we keep this
    // for the DependencyClient contract in case we swap to a stateful model later.
    logger.debug("VAD state reset (no-op for stateless model)")
  }
}

enum SileroVADError: LocalizedError {
  case modelNotFound

  var errorDescription: String? {
    switch self {
    case .modelNotFound:
      return "silero_vad.mlmodelc not found in app bundle"
    }
  }
}

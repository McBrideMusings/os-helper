import ArgumentParser
import AVFoundation
import CoreML
import Foundation

#if canImport(FluidAudio)
import FluidAudio
#endif
import WhisperKit

@main
struct Benchmark: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Compare transcription engines on the same audio file."
  )

  @Argument(help: "Path to a WAV file to transcribe.")
  var wavFile: String

  @Option(name: .long, help: "WhisperKit model variant (default: openai_whisper-base)")
  var whisperModel: String = "openai_whisper-base"

  @Option(name: .long, help: "Number of runs per engine for averaging (default: 1)")
  var runs: Int = 1

  @Option(name: .long, help: "CoreML compute units: all, cpu-ane, cpu-gpu, cpu (default: all)")
  var compute: String = "all"

  @Flag(name: .long, help: "Skip Parakeet engine")
  var skipParakeet: Bool = false

  @Flag(name: .long, help: "Skip WhisperKit engine")
  var skipWhisper: Bool = false

  @Flag(name: .long, help: "Skip Qwen3 engine")
  var skipQwen: Bool = false

  @Option(name: .long, help: "Qwen3 model variant: f32, int8 (default: f32)")
  var qwenVariant: String = "f32"

  var computeUnits: MLComputeUnits {
    switch compute.lowercased() {
    case "cpu-ane": return .cpuAndNeuralEngine
    case "cpu-gpu": return .cpuAndGPU
    case "cpu": return .cpuOnly
    default: return .all
    }
  }

  var computeLabel: String {
    switch compute.lowercased() {
    case "cpu-ane": return "CPU + ANE"
    case "cpu-gpu": return "CPU + GPU"
    case "cpu": return "CPU only"
    default: return "All (CPU + GPU + ANE)"
    }
  }

  func run() async throws {
    let url = URL(fileURLWithPath: wavFile)
    guard FileManager.default.fileExists(atPath: url.path) else {
      print("Error: File not found: \(wavFile)")
      throw ExitCode.failure
    }

    let audioFile = try AVAudioFile(forReading: url)
    let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
    print("Audio: \(url.lastPathComponent) (\(String(format: "%.1f", duration))s, \(Int(audioFile.fileFormat.sampleRate))Hz, \(audioFile.fileFormat.channelCount)ch)")
    print("Runs per engine: \(runs)")
    print("Compute units: \(computeLabel)")
    print(String(repeating: "─", count: 70))

    var results: [EngineResult] = []

    // --- Parakeet ---
    #if canImport(FluidAudio)
    if !skipParakeet {
      if let result = try await benchmarkParakeet(url: url, duration: duration) {
        results.append(result)
      }
    }

    // --- Qwen3 ---
    if !skipQwen {
      if #available(macOS 15, *) {
        if let result = try await benchmarkQwen3(url: url, duration: duration) {
          results.append(result)
        }
      } else {
        print("\n⚠ Qwen3: Requires macOS 15+, skipping")
      }
    }
    #else
    if !skipParakeet { print("\n⚠ Parakeet: FluidAudio not linked, skipping") }
    if !skipQwen { print("\n⚠ Qwen3: FluidAudio not linked, skipping") }
    #endif

    // --- WhisperKit ---
    if !skipWhisper {
      if let result = try await benchmarkWhisperKit(url: url, duration: duration) {
        results.append(result)
      }
    }

    // --- Summary ---
    printSummary(results, audioDuration: duration)
  }

  // MARK: - Engines

  #if canImport(FluidAudio)
  func benchmarkParakeet(url: URL, duration: Double) async throws -> EngineResult? {
    print("\n▶ Parakeet TDT v3 (CoreML)")
    print("  Compute units: \(computeLabel)")
    print("  Loading model...")

    let loadStart = CFAbsoluteTimeGetCurrent()
    let config = MLModelConfiguration()
    config.computeUnits = computeUnits
    let models = try await AsrModels.downloadAndLoad(configuration: config, version: .v3)
    let manager = AsrManager(config: .init())
    try await manager.initialize(models: models)
    let loadTime = CFAbsoluteTimeGetCurrent() - loadStart
    print("  Model loaded in \(String(format: "%.2f", loadTime))s")

    // Warmup
    let warmupURL = try generateSilence()
    _ = try? await manager.transcribe(warmupURL)
    try? FileManager.default.removeItem(at: warmupURL)
    print("  Warmup done")

    let preparedURL = try ensureMinDuration(url: url)

    var times: [Double] = []
    var lastText = ""
    for i in 1...runs {
      let t0 = CFAbsoluteTimeGetCurrent()
      let result = try await manager.transcribe(preparedURL)
      let elapsed = CFAbsoluteTimeGetCurrent() - t0
      times.append(elapsed)
      lastText = result.text
      if runs > 1 {
        print("  Run \(i): \(String(format: "%.3f", elapsed))s")
      }
    }

    if preparedURL != url { try? FileManager.default.removeItem(at: preparedURL) }

    let stats = Stats(times: times)
    let result = EngineResult(name: "Parakeet TDT v3", loadTime: loadTime, stats: stats, audioDuration: duration, text: lastText)
    printEngineResult(result)
    return result
  }

  @available(macOS 15, *)
  func benchmarkQwen3(url: URL, duration: Double) async throws -> EngineResult? {
    let variant: Qwen3AsrVariant = qwenVariant == "int8" ? .int8 : .f32
    print("\n▶ Qwen3 ASR 0.6B (CoreML, \(qwenVariant))")
    print("  Compute units: \(computeLabel)")
    print("  Loading model (will download on first run)...")

    let loadStart = CFAbsoluteTimeGetCurrent()
    // downloadAndLoad handles both download (if needed) and loading
    let cacheDir = Qwen3AsrModels.defaultCacheDirectory(variant: variant)
    _ = try await Qwen3AsrModels.downloadAndLoad(variant: variant, to: cacheDir, computeUnits: computeUnits)
    let manager = Qwen3AsrManager()
    try await manager.loadModels(from: cacheDir, computeUnits: computeUnits)
    let loadTime = CFAbsoluteTimeGetCurrent() - loadStart
    print("  Model loaded in \(String(format: "%.2f", loadTime))s")

    // Warmup
    let silenceSamples = [Float](repeating: 0, count: 16000)
    _ = try? await manager.transcribe(audioSamples: silenceSamples)
    print("  Warmup done")

    // Read audio samples from WAV
    let audioFile = try AVAudioFile(forReading: url)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let frameCount = AVAudioFrameCount(audioFile.length)

    // Resample to 16kHz mono if needed
    let samples: [Float]
    if audioFile.fileFormat.sampleRate == 16000 && audioFile.fileFormat.channelCount == 1 {
      guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
        print("  Error: Failed to create buffer")
        return nil
      }
      try audioFile.read(into: buffer)
      samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    } else {
      guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
        print("  Error: Failed to create buffer")
        return nil
      }
      try audioFile.read(into: buffer)

      let converter = AVAudioConverter(from: audioFile.processingFormat, to: format)!
      let ratio = 16000.0 / audioFile.fileFormat.sampleRate
      let outFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)
      guard let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outFrameCount) else {
        print("  Error: Failed to create output buffer")
        return nil
      }
      var consumed = false
      try converter.convert(to: outBuffer, error: nil) { _, outStatus in
        if consumed { outStatus.pointee = .endOfStream; return nil }
        consumed = true
        outStatus.pointee = .haveData
        return buffer
      }
      samples = Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
    }

    var times: [Double] = []
    var lastText = ""
    for i in 1...runs {
      let t0 = CFAbsoluteTimeGetCurrent()
      let text = try await manager.transcribe(audioSamples: samples)
      let elapsed = CFAbsoluteTimeGetCurrent() - t0
      times.append(elapsed)
      lastText = text
      if runs > 1 {
        print("  Run \(i): \(String(format: "%.3f", elapsed))s")
      }
    }

    let stats = Stats(times: times)
    let result = EngineResult(name: "Qwen3 ASR (\(qwenVariant))", loadTime: loadTime, stats: stats, audioDuration: duration, text: lastText)
    printEngineResult(result)
    return result
  }
  #endif

  func benchmarkWhisperKit(url: URL, duration: Double) async throws -> EngineResult? {
    print("\n▶ WhisperKit (\(whisperModel))")
    print("  Loading model...")

    let loadStart = CFAbsoluteTimeGetCurrent()
    let wkConfig = WhisperKitConfig(
      model: whisperModel,
      prewarm: true,
      load: true
    )
    let whisper = try await WhisperKit(wkConfig)
    let loadTime = CFAbsoluteTimeGetCurrent() - loadStart
    print("  Model loaded in \(String(format: "%.2f", loadTime))s (includes prewarm)")

    var times: [Double] = []
    var lastText = ""
    for i in 1...runs {
      let t0 = CFAbsoluteTimeGetCurrent()
      let segments = try await whisper.transcribe(audioPath: url.path)
      let elapsed = CFAbsoluteTimeGetCurrent() - t0
      times.append(elapsed)
      lastText = segments.map(\.text).joined(separator: " ")
      if runs > 1 {
        print("  Run \(i): \(String(format: "%.3f", elapsed))s")
      }
    }

    let stats = Stats(times: times)
    let result = EngineResult(name: "WhisperKit (\(whisperModel))", loadTime: loadTime, stats: stats, audioDuration: duration, text: lastText)
    printEngineResult(result)
    return result
  }

  // MARK: - Output

  func printEngineResult(_ r: EngineResult) {
    if runs > 1 {
      print("  ✓ Mean: \(String(format: "%.3f", r.stats.mean))s | Median: \(String(format: "%.3f", r.stats.median))s | RTF: \(String(format: "%.2f", r.stats.mean / r.audioDuration))x")
    } else {
      print("  ✓ Time: \(String(format: "%.3f", r.stats.mean))s | RTF: \(String(format: "%.2f", r.stats.mean / r.audioDuration))x")
    }
    print("  Text: \"\(r.text.trimmingCharacters(in: .whitespacesAndNewlines))\"")
  }

  func printSummary(_ results: [EngineResult], audioDuration: Double) {
    guard !results.isEmpty else { return }
    print("\n" + String(repeating: "═", count: 70))
    print("SUMMARY")
    print(String(repeating: "─", count: 70))

    let sorted = results.sorted { $0.stats.median < $1.stats.median }
    let fastest = sorted[0].stats.median

    for (i, r) in sorted.enumerated() {
      let marker = i == 0 ? " ← fastest" : ""
      let slower = i == 0 ? "" : " (\(String(format: "%.1f", r.stats.median / fastest))x slower)"
      var line = "  \(r.name)"
      line += "\n    Load: \(String(format: "%.1f", r.loadTime))s"
      if runs > 1 {
        line += " | Mean: \(String(format: "%.3f", r.stats.mean))s | Median: \(String(format: "%.3f", r.stats.median))s"
        if r.stats.times.count >= 3 {
          line += " | Min: \(String(format: "%.3f", r.stats.min))s | Max: \(String(format: "%.3f", r.stats.max))s"
        }
      } else {
        line += " | Time: \(String(format: "%.3f", r.stats.mean))s"
      }
      line += " | RTF: \(String(format: "%.2f", r.stats.median / audioDuration))x\(slower)\(marker)"
      print(line)
    }

    // Text comparison
    if results.count > 1 {
      print(String(repeating: "─", count: 70))
      print("Transcripts:")
      for r in sorted {
        let cleaned = r.text
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .replacingOccurrences(of: "\"", with: "'")
        print("  \(r.name):")
        print("    \"\(cleaned)\"")
      }
    }
  }
}

// MARK: - Stats

struct Stats {
  let times: [Double]

  var mean: Double { times.reduce(0, +) / Double(times.count) }
  var min: Double { times.min() ?? 0 }
  var max: Double { times.max() ?? 0 }

  var median: Double {
    let sorted = times.sorted()
    let n = sorted.count
    if n == 0 { return 0 }
    if n % 2 == 0 {
      return (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    } else {
      return sorted[n / 2]
    }
  }
}

struct EngineResult {
  let name: String
  let loadTime: Double
  let stats: Stats
  let audioDuration: Double
  let text: String
}

// MARK: - Helpers

func generateSilence(duration: TimeInterval = 1.0) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench_warmup.wav")
  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
  let frameCount = AVAudioFrameCount(16000 * duration)
  guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
    throw NSError(domain: "Benchmark", code: -1, userInfo: nil)
  }
  buffer.frameLength = frameCount
  let file = try AVAudioFile(forWriting: url, settings: format.settings)
  try file.write(from: buffer)
  return url
}

/// Parakeet needs >= 0.5s audio. Pad with silence if needed.
func ensureMinDuration(url: URL, minSeconds: Double = 0.6) throws -> URL {
  let file = try AVAudioFile(forReading: url)
  let duration = Double(file.length) / file.fileFormat.sampleRate
  guard duration < minSeconds else { return url }

  let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("bench_padded.wav")
  let format = file.processingFormat
  let totalFrames = AVAudioFrameCount(minSeconds * format.sampleRate)
  guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else { return url }

  let origFrames = AVAudioFrameCount(file.length)
  guard let origBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: origFrames) else { return url }
  try file.read(into: origBuffer)

  if let src = origBuffer.floatChannelData, let dst = buffer.floatChannelData {
    for ch in 0..<Int(format.channelCount) {
      memcpy(dst[ch], src[ch], Int(origFrames) * MemoryLayout<Float>.size)
    }
  }
  buffer.frameLength = totalFrames

  let outFile = try AVAudioFile(forWriting: outURL, settings: format.settings)
  try outFile.write(from: buffer)
  return outURL
}

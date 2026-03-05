import AVFoundation
import Foundation

enum WarmupHelper {
  /// Generate a minimal WAV file with silence for warmup inference.
  static func generateSilenceWAV(duration: TimeInterval = 1.0, sampleRate: Double = 16000) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("warmup_silence_\(UUID().uuidString).wav")
    let frameCount = AVAudioFrameCount(sampleRate * duration)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
      throw NSError(domain: "WarmupHelper", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
    }
    buffer.frameLength = frameCount
    // Buffer is already zeroed (silence)
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
  }

  /// Delete the temp file.
  static func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}

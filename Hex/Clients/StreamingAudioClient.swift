//
//  StreamingAudioClient.swift
//  Hex
//

import AVFoundation
import ComposableArchitecture
import CoreAudio
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let logger = HexLog.continuousListening

@DependencyClient
struct StreamingAudioClient {
  var startCapture: @Sendable () async throws -> Void
  var stopCapture: @Sendable () async -> Void
  var flushBuffers: @Sendable () async -> [AVAudioPCMBuffer] = { [] }
  var peekBuffers: @Sendable () async -> [AVAudioPCMBuffer] = { [] }
  var observeMeterLevels: @Sendable () -> AsyncStream<Float> = { .finished }
  var observeAudioChunks: @Sendable () -> AsyncStream<[AVAudioPCMBuffer]> = { .finished }
  var observeRawBuffers: @Sendable () -> AsyncStream<AVAudioPCMBuffer> = { .finished }
}

extension StreamingAudioClient: DependencyKey {
  static var liveValue: Self {
    let live = StreamingAudioClientLive()
    return Self(
      startCapture: { try await live.startCapture() },
      stopCapture: { await live.stopCapture() },
      flushBuffers: { await live.flushBuffers() },
      peekBuffers: { await live.peekBuffers() },
      observeMeterLevels: { live.startMeterStream() },
      observeAudioChunks: { live.startChunkStream() },
      observeRawBuffers: { live.startRawBufferStream() }
    )
  }
}

extension DependencyValues {
  var streamingAudio: StreamingAudioClient {
    get { self[StreamingAudioClient.self] }
    set { self[StreamingAudioClient.self] = newValue }
  }
}

// MARK: - Live Implementation

private actor StreamingAudioClientLive {
  private var engine: AVAudioEngine?
  private var buffers: [AVAudioPCMBuffer] = []
  private let targetSampleRate: Double = 16000
  private let targetChannels: AVAudioChannelCount = 1

  // Meter stream
  private var meterContinuation: AsyncStream<Float>.Continuation?

  // Raw buffer stream (for streaming transcription)
  private var rawBufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

  // VAD-triggered chunk stream
  private var chunkContinuation: AsyncStream<[AVAudioPCMBuffer]>.Continuation?
  private let silenceThreshold: Float = 0.01
  private let silenceDuration: TimeInterval = 0.4
  private var isVoiceActive: Bool = false
  private var silenceStart: Date?
  private var voiceStartTime: Date?
  private let maxChunkDuration: TimeInterval = 5.0

  // MARK: - Stream factories (nonisolated for sync access)

  nonisolated func startMeterStream() -> AsyncStream<Float> {
    AsyncStream<Float> { continuation in
      Task { await self.setMeterContinuation(continuation) }
    }
  }

  nonisolated func startChunkStream() -> AsyncStream<[AVAudioPCMBuffer]> {
    AsyncStream<[AVAudioPCMBuffer]> { continuation in
      Task { await self.setChunkContinuation(continuation) }
    }
  }

  nonisolated func startRawBufferStream() -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream<AVAudioPCMBuffer> { continuation in
      Task { await self.setRawBufferContinuation(continuation) }
    }
  }

  private func setMeterContinuation(_ continuation: AsyncStream<Float>.Continuation) {
    meterContinuation = continuation
  }

  private func setChunkContinuation(_ continuation: AsyncStream<[AVAudioPCMBuffer]>.Continuation) {
    chunkContinuation = continuation
  }

  private func setRawBufferContinuation(_ continuation: AsyncStream<AVAudioPCMBuffer>.Continuation) {
    rawBufferContinuation = continuation
  }

  // MARK: - RMS

  static func computeRMS(buffer: AVAudioPCMBuffer) -> Float {
    guard let channelData = buffer.floatChannelData else { return 0 }
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return 0 }
    let samples = channelData[0]
    var sumOfSquares: Float = 0
    for i in 0..<frames {
      let sample = samples[i]
      sumOfSquares += sample * sample
    }
    let rms = sqrtf(sumOfSquares / Float(frames))
    // Convert to dB scale for perceptually linear response, then normalize.
    // Raw RMS of speech is typically 0.005-0.1 which is nearly invisible on a linear scale.
    let db = 20 * log10f(max(rms, 1e-6))
    // Map -60dB..0dB to 0..1
    let normalized = (db + 60) / 60
    return max(min(normalized, 1.0), 0.0)
  }

  // MARK: - Meter & VAD

  private func emitMeterLevel(_ level: Float) {
    meterContinuation?.yield(level)
  }

  private func processVAD(level: Float) {
    if level >= silenceThreshold {
      if !isVoiceActive {
        voiceStartTime = Date()
      }
      isVoiceActive = true
      silenceStart = nil

      // Force-flush if voice has been active longer than maxChunkDuration
      if let start = voiceStartTime, Date().timeIntervalSince(start) >= maxChunkDuration {
        if !buffers.isEmpty {
          chunkContinuation?.yield(buffers)
          buffers.removeAll()
        }
        voiceStartTime = Date()
      }
    } else if isVoiceActive {
      if silenceStart == nil {
        silenceStart = Date()
      }
      if let start = silenceStart, Date().timeIntervalSince(start) >= silenceDuration {
        // Silence exceeded threshold — flush chunk
        if !buffers.isEmpty {
          chunkContinuation?.yield(buffers)
          buffers.removeAll()
        }
        isVoiceActive = false
        silenceStart = nil
        voiceStartTime = nil
      }
    }
  }

  // MARK: - Capture

  func startCapture() throws {
    // Select microphone if configured
    configureInputDevice()

    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let hardwareFormat = inputNode.outputFormat(forBus: 0)

    logger.notice(
      "Hardware format: \(hardwareFormat.sampleRate)Hz, \(hardwareFormat.channelCount)ch"
    )

    let bufferSize: AVAudioFrameCount = 4096
    inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) {
      [weak self] buffer, _ in
      guard let self else { return }
      let level = Self.computeRMS(buffer: buffer)
      Task {
        await self.appendBuffer(buffer)
        await self.emitMeterLevel(level)
        await self.processVAD(level: level)
      }
    }

    try engine.start()
    self.engine = engine
    logger.notice("Audio capture started")
  }

  func stopCapture() {
    guard let engine else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    self.engine = nil

    // Flush any remaining buffers as a final chunk
    if !buffers.isEmpty {
      chunkContinuation?.yield(buffers)
    }
    buffers.removeAll()

    meterContinuation?.finish()
    meterContinuation = nil
    chunkContinuation?.finish()
    chunkContinuation = nil
    rawBufferContinuation?.finish()
    rawBufferContinuation = nil
    isVoiceActive = false
    silenceStart = nil

    logger.notice("Audio capture stopped")
  }

  func flushBuffers() -> [AVAudioPCMBuffer] {
    let flushed = buffers
    buffers.removeAll()
    return flushed
  }

  func peekBuffers() -> [AVAudioPCMBuffer] {
    return Array(buffers)
  }

  private func appendBuffer(_ buffer: AVAudioPCMBuffer) {
    buffers.append(buffer)
    rawBufferContinuation?.yield(buffer)
  }

  private func configureInputDevice() {
    @Shared(.hexSettings) var hexSettings: HexSettings
    guard let selectedDeviceIDString = hexSettings.selectedMicrophoneID,
          let selectedDeviceID = AudioDeviceID(selectedDeviceIDString)
    else {
      return
    }

    // Verify device is still available and has input
    let devices = getAllAudioDevices()
    guard devices.contains(selectedDeviceID), deviceHasInput(deviceID: selectedDeviceID) else {
      logger.notice("Selected device \(selectedDeviceID) unavailable; using system default")
      return
    }

    let currentDefault = getDefaultInputDevice()
    if selectedDeviceID != currentDefault {
      logger.notice("Switching input device to \(selectedDeviceID)")
      setInputDevice(deviceID: selectedDeviceID)
    }
  }

  // MARK: - Core Audio Helpers (same as RecordingClient)

  private func getAllAudioDevices() -> [AudioDeviceID] {
    var propSize: UInt32 = 0
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize)
    let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &devices)
    return devices
  }

  private func deviceHasInput(deviceID: AudioDeviceID) -> Bool {
    var propSize: UInt32 = 0
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propSize)
    return propSize > 0
  }

  private func getDefaultInputDevice() -> AudioDeviceID? {
    var deviceID: AudioDeviceID = 0
    var propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &deviceID
    )
    return status == noErr ? deviceID : nil
  }

  private func setInputDevice(deviceID: AudioDeviceID) {
    var mutableDeviceID = deviceID
    let propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, propSize, &mutableDeviceID
    )
  }
}

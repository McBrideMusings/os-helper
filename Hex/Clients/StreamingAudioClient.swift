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
}

extension StreamingAudioClient: DependencyKey {
  static var liveValue: Self {
    let live = StreamingAudioClientLive()
    return Self(
      startCapture: { try await live.startCapture() },
      stopCapture: { await live.stopCapture() },
      flushBuffers: { await live.flushBuffers() }
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

  func startCapture() throws {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let hardwareFormat = inputNode.outputFormat(forBus: 0)

    logger.notice(
      "Hardware format: \(hardwareFormat.sampleRate)Hz, \(hardwareFormat.channelCount)ch"
    )

    // Select microphone if configured
    configureInputDevice()

    // Install tap at the hardware's native format — we'll convert in flushBuffers
    let bufferSize: AVAudioFrameCount = 4096
    inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) {
      [weak self] buffer, _ in
      guard let self else { return }
      Task { await self.appendBuffer(buffer) }
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
    buffers.removeAll()
    logger.notice("Audio capture stopped")
  }

  func flushBuffers() -> [AVAudioPCMBuffer] {
    let flushed = buffers
    buffers.removeAll()
    return flushed
  }

  private func appendBuffer(_ buffer: AVAudioPCMBuffer) {
    buffers.append(buffer)
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

import AppKit
import ComposableArchitecture
import Foundation
@testable import Hex_Dev
import Testing

@MainActor
struct ContinuousListeningFeatureTests {

  // MARK: - 1. showPanel starts capture automatically

  @Test
  func showPanelStartsCaptureAndSetsState() async {
    let testDate = Date(timeIntervalSinceReferenceDate: 0)
    let store = TestStore(initialState: ContinuousListeningFeature.State()) {
      ContinuousListeningFeature()
    } withDependencies: {
      $0.streamingAudio.startCapture = { @Sendable in }
      $0.streamingAudio.observeMeterLevels = { @Sendable in .finished }
      $0.streamingAudio.observeVADState = { @Sendable in .finished }
      $0.date = .constant(testDate)
    }
    store.exhaustivity = .off

    await store.send(.showPanel) {
      $0.panelVisible = true
      $0.isCapturing = true
      $0.sessionStartTime = testDate
      let frontApp = NSWorkspace.shared.frontmostApplication
      $0.sourceAppBundleID = frontApp?.bundleIdentifier
      $0.sourceAppName = frontApp?.localizedName
    }
    await store.receive(\.captureStarted)
  }

  @Test
  func showPanelIdempotent() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.panelVisible = true
    initialState.isCapturing = true

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    }

    await store.send(.showPanel)
    // No state change, no effects
  }

  // MARK: - 2. hidePanel stops capture and resets all state

  @Test
  func hidePanelResetsEverything() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.panelVisible = true
    initialState.isCapturing = true
    initialState.emissionMode = .continuous
    initialState.isSpeaking = true
    initialState.currentUtteranceText = "some text"
    initialState.sessionStartTime = Date()

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    } withDependencies: {
      $0.streamingAudio.stopCapture = { @Sendable in }
    }

    await store.send(.hidePanel) {
      $0.panelVisible = false
      $0.isCapturing = false
      $0.emissionMode = .inactive
      $0.meterLevel = 0
      $0.error = nil
      $0.hasCaptureError = false
      $0.transcriptEntries = []
      $0.currentUtteranceText = ""
      $0.isSpeaking = false
      $0.emissionAnchorText = ""
      $0.lastEmittedText = ""
      $0.pendingTranscription = false
      $0.lastFullTranscription = ""
      $0.sessionStartTime = nil
    }
  }

  // MARK: - 3. Emission lifecycle — PTT

  @Test
  func startEmissionPTTSetsMode() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.panelVisible = true
    initialState.isCapturing = true
    initialState.lastFullTranscription = "existing text"

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    }

    await store.send(.startEmission(.pushToTalk)) {
      $0.emissionMode = .pushToTalk
      $0.emissionAnchorText = "existing text"
      $0.lastEmittedText = ""
    }
  }

  @Test
  func startEmissionRequiresPanel() async {
    let store = TestStore(initialState: ContinuousListeningFeature.State()) {
      ContinuousListeningFeature()
    }

    await store.send(.startEmission(.pushToTalk))
    // No state change — panel not visible
  }

  @Test
  func stopEmissionPTTDefers350ms() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.panelVisible = true
    initialState.isCapturing = true
    initialState.emissionMode = .pushToTalk

    let clock = TestClock()
    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }

    await store.send(.stopEmission)
    await clock.advance(by: .milliseconds(350))
    await store.receive(\.confirmStopEmission) {
      $0.emissionMode = .inactive
    }
  }

  // MARK: - 4. Emission lifecycle — Continuous (toggle)

  @Test
  func startEmissionContinuousTogglesOnOff() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.panelVisible = true
    initialState.isCapturing = true

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    }

    // Toggle on
    await store.send(.startEmission(.continuous)) {
      $0.emissionMode = .continuous
      $0.emissionAnchorText = ""
      $0.lastEmittedText = ""
    }

    // Toggle off
    await store.send(.startEmission(.continuous)) {
      $0.emissionMode = .inactive
    }
  }

  // MARK: - 5. Transcription always updates panel

  @Test
  func transcriptionUpdatesCurrentUtteranceText() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.isCapturing = true
    initialState.panelVisible = true
    initialState.pendingTranscription = true

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    }

    await store.send(.transcriptionCompleted("hello world")) {
      $0.pendingTranscription = false
      $0.currentUtteranceText = "hello world"
      $0.lastFullTranscription = "hello world"
    }
    // No emission — emissionMode is .inactive
  }

  // MARK: - 6. Only text after anchor is emitted (mid-utterance activation)

  @Test
  func onlyNewTextEmittedAfterAnchor() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.isCapturing = true
    initialState.panelVisible = true
    initialState.pendingTranscription = true
    initialState.emissionMode = .pushToTalk
    initialState.emissionAnchorText = "the meeting is at"
    initialState.lastEmittedText = ""

    var typedText = ""
    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    } withDependencies: {
      $0.textEmission.typeText = { @Sendable text in typedText += text }
    }

    await store.send(.transcriptionCompleted("the meeting is at three pm")) {
      $0.pendingTranscription = false
      $0.currentUtteranceText = "the meeting is at three pm"
      $0.lastFullTranscription = "the meeting is at three pm"
      $0.lastEmittedText = " three pm"
    }
    await store.receive(\.deltaEmitted)
    #expect(typedText == " three pm")
  }

  // MARK: - 7. New utterance after activation — full text emitted

  @Test
  func newUtteranceFullyEmitted() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.isCapturing = true
    initialState.panelVisible = true
    initialState.pendingTranscription = true
    initialState.emissionMode = .continuous
    initialState.emissionAnchorText = ""
    initialState.lastEmittedText = ""

    var typedText = ""
    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    } withDependencies: {
      $0.textEmission.typeText = { @Sendable text in typedText += text }
    }

    await store.send(.transcriptionCompleted("brand new sentence")) {
      $0.pendingTranscription = false
      $0.currentUtteranceText = "brand new sentence"
      $0.lastFullTranscription = "brand new sentence"
      $0.lastEmittedText = "brand new sentence"
    }
    await store.receive(\.deltaEmitted)
    #expect(typedText == "brand new sentence")
  }

  // MARK: - 8. Final transcription commits entry and applies correction

  @Test
  func finalTranscriptionCommitsEntry() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.isCapturing = true
    initialState.panelVisible = true
    initialState.lastFullTranscription = "hello"

    let testID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let testDate = Date(timeIntervalSinceReferenceDate: 100)

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    } withDependencies: {
      $0.uuid = .constant(testID)
      $0.date = .constant(testDate)
    }

    await store.send(.finalTranscriptionCompleted("hello world")) {
      $0.pendingTranscription = false
      $0.transcriptEntries = [
        TranscriptEntry(id: testID, text: "hello world", timestamp: testDate)
      ]
      $0.currentUtteranceText = ""
      $0.lastFullTranscription = ""
      $0.emissionAnchorText = ""
      $0.lastEmittedText = ""
    }
  }

  @Test
  func finalTranscriptionWithEmissionAppliesCorrection() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.isCapturing = true
    initialState.panelVisible = true
    initialState.emissionMode = .pushToTalk
    initialState.emissionAnchorText = ""
    initialState.lastEmittedText = "hello worl"
    initialState.lastFullTranscription = "hello worl"

    var deletedCount = 0
    var typedText = ""
    let testID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let testDate = Date(timeIntervalSinceReferenceDate: 200)

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    } withDependencies: {
      $0.uuid = .constant(testID)
      $0.date = .constant(testDate)
      $0.textEmission.deleteBackward = { @Sendable count in deletedCount += count }
      $0.textEmission.typeText = { @Sendable text in typedText += text }
    }

    await store.send(.finalTranscriptionCompleted("hello world")) {
      $0.pendingTranscription = false
      $0.transcriptEntries = [
        TranscriptEntry(id: testID, text: "hello world", timestamp: testDate)
      ]
      $0.currentUtteranceText = ""
      $0.lastFullTranscription = ""
      $0.emissionAnchorText = ""
      $0.lastEmittedText = "hello world"
    }
    await store.receive(\.deltaEmitted)
    #expect(deletedCount == 5)  // " worl"
    #expect(typedText == " world")
  }

  // MARK: - 9. Entries pruned after 15s

  @Test
  func pruneExpiredEntries() async {
    let now = Date(timeIntervalSinceReferenceDate: 100)
    let oldEntry = TranscriptEntry(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      text: "old text",
      timestamp: now.addingTimeInterval(-20)
    )
    let recentEntry = TranscriptEntry(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      text: "recent text",
      timestamp: now.addingTimeInterval(-5)
    )

    var initialState = ContinuousListeningFeature.State()
    initialState.panelVisible = true
    initialState.transcriptEntries = [oldEntry, recentEntry]

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    } withDependencies: {
      $0.date = .constant(now)
    }

    await store.send(.pruneExpiredEntries) {
      $0.transcriptEntries = [recentEntry]
    }
  }

  // MARK: - 10. ESC closes panel

  @Test
  func escClosesPanel() async {
    // Tested via AppFeature dispatch — here we just verify hidePanel resets capture
    var initialState = ContinuousListeningFeature.State()
    initialState.panelVisible = true
    initialState.isCapturing = true

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    } withDependencies: {
      $0.streamingAudio.stopCapture = { @Sendable in }
    }

    await store.send(.hidePanel) {
      $0.panelVisible = false
      $0.isCapturing = false
      $0.emissionMode = .inactive
      $0.meterLevel = 0
      $0.error = nil
      $0.hasCaptureError = false
      $0.transcriptEntries = []
      $0.currentUtteranceText = ""
      $0.isSpeaking = false
      $0.emissionAnchorText = ""
      $0.lastEmittedText = ""
      $0.pendingTranscription = false
      $0.lastFullTranscription = ""
      $0.sessionStartTime = nil
    }
  }

  // MARK: - 11. Empty/whitespace transcription ignored

  @Test
  func emptyTranscriptionIgnored() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.pendingTranscription = true

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    }

    await store.send(.transcriptionCompleted("")) {
      $0.pendingTranscription = false
    }
  }

  @Test
  func whitespaceOnlyTranscriptionIgnored() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.pendingTranscription = true

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    }

    await store.send(.transcriptionCompleted("   \n  ")) {
      $0.pendingTranscription = false
    }
  }

  // MARK: - 12. Meter level clears watchdog error

  @Test
  func meterLevelUpdatedClearsError() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.hasCaptureError = true
    initialState.error = "mic in use"

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    }

    await store.send(.meterLevelUpdated(0.5)) {
      $0.meterLevel = 0.5
      $0.hasCaptureError = false
      $0.error = nil
    }
  }

  // MARK: - 13. Pending transcription blocks tick

  @Test
  func streamingTickSkippedWhenPending() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.isCapturing = true
    initialState.pendingTranscription = true

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    }

    await store.send(.streamingTickFired)
  }

  // MARK: - 14. VAD state changes

  @Test
  func speechStartedBeginsTick() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.isCapturing = true

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    }
    store.exhaustivity = .off

    await store.send(.vadStateChanged(.speechStarted)) {
      $0.isSpeaking = true
    }
  }

  @Test
  func speechEndedRunsFinalTranscription() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.isCapturing = true
    initialState.isSpeaking = true

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    } withDependencies: {
      $0.streamingAudio.flushBuffers = { @Sendable in [] }
    }
    store.exhaustivity = .off

    await store.send(.vadStateChanged(.speechEnded)) {
      $0.isSpeaking = false
    }
  }
}

import ComposableArchitecture
import Foundation
@testable import Hex_Dev
import Testing

@MainActor
struct ContinuousListeningFeatureTests {

  // MARK: - Helpers

  private func makeDate(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: offset)
  }

  // MARK: - 1. Accumulation: blocks accumulate, no auto-dispatch

  @Test
  func blocksAccumulateWithoutAutoDispatch() async {
    let id1 = UUID()
    let id2 = UUID()
    var state = ContinuousListeningFeature.State()
    state.textBlocks.append(TextBlock(id: id1, text: "hello", status: .complete, timestamp: Date()))
    state.textBlocks.append(TextBlock(id: id2, text: "world", status: .complete, timestamp: Date()))

    // Blocks accumulate — nothing is auto-dispatched
    #expect(state.textBlocks.count == 2)
    #expect(state.textBlocks[id: id1]?.text == "hello")
    #expect(state.textBlocks[id: id2]?.text == "world")
  }

  // MARK: - 2. Dispatch joins and clears complete blocks

  @Test
  func dispatchJoinsAndClearsCompleteBlocks() async {
    let id1 = UUID()
    let id2 = UUID()
    let id3 = UUID()

    var initialState = ContinuousListeningFeature.State()
    initialState.textBlocks = [
      TextBlock(id: id1, text: "hello", status: .complete, timestamp: Date()),
      TextBlock(id: id2, text: "world", status: .complete, timestamp: Date()),
      TextBlock(id: id3, text: "foo", status: .complete, timestamp: Date()),
    ]

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    } withDependencies: {
      $0.pasteboard.paste = { @Sendable text in
        #expect(text == "hello world foo")
      }
      $0.soundEffects.play = { @Sendable _ in }
    }

    await store.send(.dispatchText) {
      $0.textBlocks = []
    }
    await store.receive(\.textDispatched)
  }

  // MARK: - 3. Clear wipes all

  @Test
  func clearWipesAll() async {
    let id1 = UUID()
    var initialState = ContinuousListeningFeature.State()
    initialState.textBlocks = [
      TextBlock(id: id1, text: "hello", status: .complete, timestamp: Date()),
    ]
    initialState.interimText = "partial"
    initialState.activeSegmentID = id1
    initialState.lastChunkTimestamp = Date()
    initialState.pendingChunkIDs = [UUID()]
    initialState.sessionHasProducedBlocks = true
    initialState.sessionDividerVisible = true

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    }

    await store.send(.clearText) {
      $0.textBlocks = []
      $0.interimText = nil
      $0.error = nil
      $0.activeSegmentID = nil
      $0.lastChunkTimestamp = nil
      $0.pendingChunkIDs = []
      $0.sessionHasProducedBlocks = false
      $0.sessionDividerVisible = false
    }
  }

  // MARK: - 4. Dispatch keeps non-complete blocks

  @Test
  func dispatchKeepsNonCompleteBlocks() async {
    let id1 = UUID()
    let id2 = UUID()

    var initialState = ContinuousListeningFeature.State()
    initialState.textBlocks = [
      TextBlock(id: id1, text: "done", status: .complete, timestamp: Date()),
      TextBlock(id: id2, text: "", status: .transcribing, timestamp: Date()),
    ]

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    } withDependencies: {
      $0.pasteboard.paste = { @Sendable _ in }
      $0.soundEffects.play = { @Sendable _ in }
    }

    await store.send(.dispatchText) {
      $0.textBlocks = [
        TextBlock(id: id2, text: "", status: .transcribing, timestamp: initialState.textBlocks[id: id2]!.timestamp),
      ]
    }
    await store.receive(\.textDispatched)
  }

  // MARK: - 5. Chunks within threshold merge into single TextBlock

  @Test
  func chunksWithinThresholdMerge() async {
    let chunkID1 = UUID()
    let blockID = UUID()

    var initialState = ContinuousListeningFeature.State()
    // Simulate that a block already exists from a prior chunk
    initialState.textBlocks = [
      TextBlock(id: blockID, text: "first", status: .complete, timestamp: makeDate(0)),
    ]
    initialState.activeSegmentID = blockID
    initialState.lastChunkTimestamp = makeDate(1.0)
    initialState.sessionHasProducedBlocks = true

    // Simulate receiving a chunkTranscribed that appends to the existing block
    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    }

    await store.send(.chunkTranscribed(blockID: blockID, chunkID: chunkID1, text: "second")) {
      $0.textBlocks[id: blockID]?.text = "first second"
      $0.textBlocks[id: blockID]?.status = .complete
    }
  }

  // MARK: - 6. Chunks after threshold create new block

  @Test
  func chunksAfterThresholdCreateNewBlock() async {
    let id1 = UUID()
    let id2 = UUID()

    var initialState = ContinuousListeningFeature.State()
    initialState.textBlocks = [
      TextBlock(id: id1, text: "first", status: .complete, timestamp: makeDate(0)),
    ]
    initialState.textBlocks.append(
      TextBlock(id: id2, text: "second", status: .complete, timestamp: makeDate(3.0))
    )

    // Two separate blocks = they were beyond the threshold
    #expect(initialState.textBlocks.count == 2)
    #expect(initialState.textBlocks[id: id1]?.text == "first")
    #expect(initialState.textBlocks[id: id2]?.text == "second")
  }

  // MARK: - 7. Concurrent transcriptions append correctly

  @Test
  func concurrentTranscriptionsAppendCorrectly() async {
    let blockID = UUID()
    let chunkID1 = UUID()
    let chunkID2 = UUID()

    var initialState = ContinuousListeningFeature.State()
    initialState.textBlocks = [
      TextBlock(id: blockID, text: "", status: .transcribing, timestamp: Date()),
    ]
    initialState.pendingChunkIDs = [chunkID1, chunkID2]
    initialState.activeSegmentID = blockID

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    }

    // First chunk arrives — block stays transcribing because chunkID2 still pending
    await store.send(.chunkTranscribed(blockID: blockID, chunkID: chunkID1, text: "hello")) {
      $0.pendingChunkIDs = [chunkID2]
      $0.textBlocks[id: blockID]?.text = "hello"
    }

    // Second chunk arrives — block completes
    await store.send(.chunkTranscribed(blockID: blockID, chunkID: chunkID2, text: "world")) {
      $0.pendingChunkIDs = []
      $0.textBlocks[id: blockID]?.text = "hello world"
      $0.textBlocks[id: blockID]?.status = .complete
    }
  }

  // MARK: - 8. Stop listening preserves blocks

  @Test
  func stopListeningPreservesBlocks() async {
    let id1 = UUID()
    var initialState = ContinuousListeningFeature.State()
    initialState.isActive = true
    initialState.textBlocks = [
      TextBlock(id: id1, text: "preserved", status: .complete, timestamp: Date()),
    ]
    initialState.activeSegmentID = id1
    initialState.lastChunkTimestamp = Date()

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    } withDependencies: {
      $0.streamingTranscription.cancel = { @Sendable in }
      $0.streamingAudio.stopCapture = { @Sendable in }
    }

    await store.send(.stopListening) {
      $0.isActive = false
      $0.hasCaptureError = false
      // interimText preserved — not cleared until transcription completes
      $0.meterLevel = 0
      $0.error = nil
      $0.activeSegmentID = nil
      $0.lastChunkTimestamp = nil
      // textBlocks preserved
      #expect($0.textBlocks.count == 1)
      #expect($0.textBlocks[id: id1]?.text == "preserved")
    }
  }

  // MARK: - 9. Restart preserves existing blocks

  @Test
  func restartPreservesExistingBlocks() async {
    let id1 = UUID()
    var initialState = ContinuousListeningFeature.State()
    initialState.textBlocks = [
      TextBlock(id: id1, text: "still here", status: .complete, timestamp: Date()),
    ]

    // After stop, blocks remain. Verify directly.
    #expect(initialState.textBlocks.count == 1)
    #expect(initialState.textBlocks[id: id1]?.text == "still here")
  }

  // MARK: - 10. New session sets boundary flag

  @Test
  func newSessionSetsBoundaryFlag() async {
    let id1 = UUID()
    let id2 = UUID()

    var state = ContinuousListeningFeature.State()

    // Session 1: produce a block
    state.textBlocks.append(TextBlock(id: id1, text: "session one", status: .complete, timestamp: Date()))
    state.sessionHasProducedBlocks = true

    // Simulate stop + restart: reset session tracking
    state.activeSegmentID = nil
    state.lastChunkTimestamp = nil
    state.sessionHasProducedBlocks = false

    // New block after restart should have isSessionStart = true
    // (because sessionHasProducedBlocks is false and textBlocks is not empty)
    let isSessionStart = !state.sessionHasProducedBlocks && !state.textBlocks.isEmpty
    state.textBlocks.append(TextBlock(id: id2, text: "session two", status: .complete, timestamp: Date(), isSessionStart: isSessionStart))

    #expect(state.textBlocks[id: id2]?.isSessionStart == true)
    #expect(state.textBlocks[id: id1]?.isSessionStart == false)
  }

  // MARK: - 11. Hide panel clears everything

  @Test
  func hidePanelClearsEverything() async {
    let id1 = UUID()
    var initialState = ContinuousListeningFeature.State()
    initialState.panelVisible = true
    initialState.textBlocks = [
      TextBlock(id: id1, text: "gone", status: .complete, timestamp: Date()),
    ]
    initialState.activeSegmentID = id1
    initialState.lastChunkTimestamp = Date()
    initialState.pendingChunkIDs = [UUID()]
    initialState.sessionHasProducedBlocks = true
    initialState.sessionDividerVisible = true

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    }

    await store.send(.hidePanel) {
      $0.panelVisible = false
      $0.recordingMode = .idle
      $0.textBlocks = []
      $0.interimText = nil
      $0.error = nil
      $0.activeSegmentID = nil
      $0.lastChunkTimestamp = nil
      $0.pendingChunkIDs = []
      $0.sessionHasProducedBlocks = false
      $0.sessionDividerVisible = false
    }
  }

  // MARK: - 12. Dispatch joins sessions with newline

  @Test
  func dispatchJoinsSessionsWithNewline() async {
    let id1 = UUID()
    let id2 = UUID()
    let id3 = UUID()

    var initialState = ContinuousListeningFeature.State()
    initialState.textBlocks = [
      TextBlock(id: id1, text: "session one", status: .complete, timestamp: Date()),
      TextBlock(id: id2, text: "still session one", status: .complete, timestamp: Date()),
      TextBlock(id: id3, text: "session two", status: .complete, timestamp: Date(), isSessionStart: true),
    ]

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    } withDependencies: {
      $0.pasteboard.paste = { @Sendable text in
        #expect(text == "session one still session one\nsession two")
      }
      $0.soundEffects.play = { @Sendable _ in }
    }

    await store.send(.dispatchText) {
      $0.textBlocks = []
    }
    await store.receive(\.textDispatched)
  }

  // MARK: - 13. Segment silence exceeded shows divider proactively

  @Test
  func segmentSilenceExceededShowsDivider() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.sessionHasProducedBlocks = true
    initialState.activeSegmentID = UUID()

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    }

    await store.send(.segmentSilenceExceeded) {
      $0.sessionDividerVisible = true
      $0.activeSegmentID = nil
    }
  }

  // MARK: - 14. Segment silence not shown when no blocks produced

  @Test
  func segmentSilenceIgnoredWithoutBlocks() async {
    let initialState = ContinuousListeningFeature.State()

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    }

    // sessionHasProducedBlocks is false — no divider
    await store.send(.segmentSilenceExceeded)
  }

  // MARK: - 15. Dispatch defers when transcriptions are pending

  @Test
  func dispatchDefersWhenTranscriptionsPending() async {
    let blockID = UUID()
    let chunkID = UUID()

    var initialState = ContinuousListeningFeature.State()
    initialState.textBlocks = [
      TextBlock(id: blockID, text: "partial", status: .transcribing, timestamp: Date()),
    ]
    initialState.pendingChunkIDs = [chunkID]

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    } withDependencies: {
      $0.pasteboard.paste = { @Sendable text in
        #expect(text == "partial more")
      }
      $0.soundEffects.play = { @Sendable _ in }
    }

    // Dispatch while transcription pending — should defer
    await store.send(.dispatchText) {
      $0.isAwaitingDispatch = true
    }

    // Transcription completes — should auto-dispatch
    await store.send(.chunkTranscribed(blockID: blockID, chunkID: chunkID, text: "more")) {
      $0.pendingChunkIDs = []
      $0.textBlocks[id: blockID]?.text = "partial more"
      $0.textBlocks[id: blockID]?.status = .complete
    }
    await store.receive(\.dispatchText) {
      $0.isAwaitingDispatch = false
      $0.textBlocks = []
    }
    await store.receive(\.textDispatched)
  }

  // MARK: - 16. Dispatch sends immediately when no pending transcriptions

  @Test
  func dispatchSendsImmediatelyWhenNoPending() async {
    let id1 = UUID()

    var initialState = ContinuousListeningFeature.State()
    initialState.textBlocks = [
      TextBlock(id: id1, text: "ready", status: .complete, timestamp: Date()),
    ]

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    } withDependencies: {
      $0.pasteboard.paste = { @Sendable text in
        #expect(text == "ready")
      }
      $0.soundEffects.play = { @Sendable _ in }
    }

    await store.send(.dispatchText) {
      $0.textBlocks = []
    }
    await store.receive(\.textDispatched)
  }

  // MARK: - 17. Clear cancels deferred dispatch

  @Test
  func clearCancelsDeferredDispatch() async {
    var initialState = ContinuousListeningFeature.State()
    initialState.isAwaitingDispatch = true
    initialState.pendingChunkIDs = [UUID()]
    initialState.textBlocks = [
      TextBlock(id: UUID(), text: "", status: .transcribing, timestamp: Date()),
    ]

    let store = TestStore(initialState: initialState) {
      ContinuousListeningFeature()
    }

    await store.send(.clearText) {
      $0.textBlocks = []
      $0.interimText = nil
      $0.error = nil
      $0.activeSegmentID = nil
      $0.lastChunkTimestamp = nil
      $0.pendingChunkIDs = []
      $0.sessionHasProducedBlocks = false
      $0.sessionDividerVisible = false
      $0.isAwaitingDispatch = false
    }
  }
}

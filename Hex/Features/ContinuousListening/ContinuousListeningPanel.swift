//
//  ContinuousListeningPanel.swift
//  Hex
//

import AppKit
import ComposableArchitecture
import SwiftUI

class ContinuousListeningPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(store: StoreOf<ContinuousListeningFeature>) {
    let panelWidth: CGFloat = 320
    let panelHeight: CGFloat = 200

    let screen = NSScreen.main ?? NSScreen.screens[0]
    let x = screen.visibleFrame.midX - panelWidth / 2
    let y = screen.visibleFrame.minY + 80

    let contentRect = NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
    let styleMask: NSWindow.StyleMask = [
      .nonactivatingPanel,
      .fullSizeContentView,
      .borderless,
      .utilityWindow,
    ]

    super.init(
      contentRect: contentRect,
      styleMask: styleMask,
      backing: .buffered,
      defer: false
    )

    level = .floating
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    hidesOnDeactivate = false
    canHide = false
    becomesKeyOnlyIfNeeded = true
    isMovableByWindowBackground = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let overlayView = ContinuousListeningOverlayView(store: store)
    contentView = NSHostingView(rootView: overlayView)
  }
}

// MARK: - SwiftUI Overlay View

struct ContinuousListeningOverlayView: View {
  let store: StoreOf<ContinuousListeningFeature>

  private var hasError: Bool { store.hasCaptureError }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Header
      HStack(spacing: 6) {
        if hasError {
          Circle()
            .fill(.gray)
            .frame(width: 8, height: 8)
          AudioLevelBars(level: 0, disabled: true)
          Text("Error")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
        } else {
          PulsingDot()
          AudioLevelBars(level: store.meterLevel)
          Text("Listening...")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
        }
        Spacer()
      }

      Divider()

      // Body — flowing paragraph
      ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
          FlowingTextView(
            textBlocks: store.textBlocks,
            interimText: store.interimText,
            isCapturingAudio: !hasError && store.meterLevel > 0.05
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .id("bottom")
        }
        .onChange(of: store.textBlocks.count) {
          withAnimation {
            proxy.scrollTo("bottom", anchor: .bottom)
          }
        }
      }

      // Error
      if let error = store.error {
        Text(error)
          .font(.system(size: 10))
          .foregroundStyle(.red)
          .lineLimit(3)
      }
    }
    .padding(12)
    .frame(width: 320)
    .frame(minHeight: 80, maxHeight: 200)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}

// MARK: - Flowing Text View

private struct FlowingTextView: View {
  let textBlocks: IdentifiedArrayOf<TextBlock>
  let interimText: String?
  let isCapturingAudio: Bool

  /// Timestamps when each word first appeared, keyed by global word index.
  @State private var wordAppearTimes: [Int: Date] = [:]
  /// Tracks the last known total so we can detect clears.
  @State private var lastKnownTotal: Int = 0
  /// Tick counter to drive re-renders for the fade.
  @State private var tick: Int = 0
  @State private var tickTask: Task<Void, Never>?

  /// How long a word stays gray before it's fully white.
  private let settleDuration: TimeInterval = 1.5

  private var totalCompletedWords: Int {
    textBlocks.filter { $0.status == .complete }
      .reduce(0) { $0 + $1.text.split(separator: " ").count }
  }

  /// True when we've received audio that hasn't finished transcribing yet.
  private var isTranscribing: Bool {
    textBlocks.contains(where: { $0.status == .transcribing })
      || isCapturingAudio
  }

  private var showEllipsis: Bool {
    interimText != nil || isTranscribing
  }

  var body: some View {
    let hasContent = !textBlocks.isEmpty || interimText != nil || isCapturingAudio
    if !hasContent {
      Text("Speak to start...")
        .font(.system(size: 13))
        .foregroundStyle(.tertiary)
        .italic()
    } else {
      (buildFlowingText() + (showEllipsis ? Text(" ") : Text("")))
        .font(.system(size: 13))
        .textSelection(.enabled)
        .onAppear { startTicking() }
        .onDisappear { tickTask?.cancel() }
        .onChange(of: totalCompletedWords) { _, newTotal in
          if newTotal < lastKnownTotal {
            wordAppearTimes.removeAll()
          }
          let now = Date()
          for i in lastKnownTotal..<newTotal {
            if wordAppearTimes[i] == nil {
              wordAppearTimes[i] = now
            }
          }
          lastKnownTotal = newTotal
        }
        .overlay(alignment: .trailingLastTextBaseline) {
          if showEllipsis {
            AnimatedEllipsis()
              .font(.system(size: 13))
          }
        }
    }
  }

  /// Ticks every 100ms to drive smooth color transitions.
  private func startTicking() {
    tickTask?.cancel()
    tickTask = Task { @MainActor in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        tick += 1
      }
    }
  }

  private func wordOpacity(at globalIndex: Int) -> Double {
    // Force dependency on tick so we re-render
    _ = tick
    guard let appeared = wordAppearTimes[globalIndex] else { return 0.5 }
    let elapsed = Date().timeIntervalSince(appeared)
    let progress = min(elapsed / settleDuration, 1.0)
    // Interpolate from 0.5 (gray) to 1.0 (white)
    return 0.5 + progress * 0.5
  }

  private func buildFlowingText() -> Text {
    var globalWordIndex = 0
    var result = textBlocks.enumerated().reduce(Text("")) { acc, pair in
      let (index, block) = pair
      let separator = index > 0 ? Text(" ") : Text("")
      switch block.status {
      case .complete:
        let words = block.text.split(separator: " ")
        var blockText = Text("")
        for (wi, word) in words.enumerated() {
          let wordSep = wi > 0 ? Text(" ") : Text("")
          let opacity = wordOpacity(at: globalWordIndex)
          blockText = blockText + wordSep + Text(word)
            .foregroundColor(.primary.opacity(opacity))
          globalWordIndex += 1
        }
        return acc + separator + blockText
      case .transcribing:
        return acc + separator + Text("...")
          .foregroundColor(.secondary)
      case .error(let message):
        return acc + separator + Text(message)
          .foregroundColor(.red)
      }
    }

    if let interim = interimText {
      let separator = textBlocks.isEmpty ? Text("") : Text(" ")
      result = result + separator + Text(interim)
        .foregroundColor(.secondary.opacity(0.7))
    }

    return result
  }
}

// MARK: - Animated Ellipsis

private struct AnimatedEllipsis: View {
  @State private var dotCount = 0

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.4)) { timeline in
      let dots = dotCountFor(timeline.date)
      Text(String(repeating: ".", count: dots))
        .foregroundColor(.secondary.opacity(0.4))
    }
  }

  private func dotCountFor(_ date: Date) -> Int {
    let cycle = Int(date.timeIntervalSinceReferenceDate / 0.4) % 3
    return cycle + 1
  }
}

// MARK: - Audio Level Bars

private struct AudioLevelBars: View {
  let level: Float
  var disabled: Bool = false
  private let barCount = 7
  private let barWeights: [Float] = [0.5, 0.7, 0.85, 1.0, 0.9, 0.75, 0.55]

  var body: some View {
    HStack(spacing: 1.5) {
      ForEach(0..<barCount, id: \.self) { index in
        RoundedRectangle(cornerRadius: 1)
          .fill(disabled ? .gray : .red)
          .frame(width: 2.5, height: disabled ? 2 : barHeight(for: index))
      }
    }
    .frame(height: 16)
    .animation(disabled ? nil : .easeOut(duration: 0.06), value: level)
  }

  private func barHeight(for index: Int) -> CGFloat {
    let weight = barWeights[index]
    let minHeight: CGFloat = 2
    let maxHeight: CGFloat = 16
    let scaled = CGFloat(level * weight)
    return minHeight + scaled * (maxHeight - minHeight)
  }
}

// MARK: - Pulsing Red Dot

private struct PulsingDot: View {
  @State private var isPulsing = false

  var body: some View {
    Circle()
      .fill(.red)
      .frame(width: 8, height: 8)
      .opacity(isPulsing ? 0.4 : 1.0)
      .animation(
        .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
        value: isPulsing
      )
      .onAppear { isPulsing = true }
  }
}

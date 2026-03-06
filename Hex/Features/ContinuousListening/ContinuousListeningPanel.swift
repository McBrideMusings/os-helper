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
    let panelWidth: CGFloat = 260
    let panelHeight: CGFloat = 160

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

  private var statusText: String {
    if hasError { return "Error" }
    if store.emissionMode != .inactive { return "Typing" }
    return "Listening"
  }

  private var isEmitting: Bool {
    store.emissionMode != .inactive
  }

  private var sessionDuration: String? {
    guard let start = store.sessionStartTime else { return nil }
    let elapsed = Int(Date().timeIntervalSince(start))
    let minutes = elapsed / 60
    let seconds = elapsed % 60
    return String(format: "%d:%02d", minutes, seconds)
  }

  var body: some View {
    VStack(spacing: 0) {
      statusBar

      Divider()
        .opacity(0.3)

      // Transcript: chronological top-to-bottom, current utterance at the bottom edge.
      // Old text at top fades out. Overflow clips at top.
      GeometryReader { geo in
        VStack(alignment: .leading, spacing: 3) {
          // Committed entries — chronological (oldest at top, newest at bottom)
          ForEach(store.transcriptEntries) { entry in
            let age = Date().timeIntervalSince(entry.timestamp)
            let fadeOpacity: Double = age < 10 ? 1.0 : age > 60 ? 0.0 : 1.0 - (age - 10) / 50.0
            Text(entry.text)
              .font(.system(size: 11))
              .foregroundStyle(.primary)
              .opacity(fadeOpacity)
          }

          // Live utterance at the bottom — gray italic, continuously updating
          if !store.currentUtteranceText.isEmpty {
            Text(store.currentUtteranceText)
              .font(.system(size: 11))
              .italic()
              .foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Pin content to the bottom so it grows upward
        .frame(height: nil)
        .frame(maxHeight: .infinity, alignment: .bottom)
      }
      .clipped()
      .mask(
        VStack(spacing: 0) {
          // Fade old text at top
          LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            .frame(height: 20)
          Color.black
        }
      )
    }
    .frame(width: 260, height: 160)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var statusBar: some View {
    HStack(spacing: 6) {
      if hasError {
        Circle()
          .fill(.gray)
          .frame(width: 8, height: 8)
      } else {
        PulsingDot()
        AudioLevelBars(level: store.meterLevel)
      }

      Text(statusText)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.primary)

      if isEmitting {
        Image(systemName: "pencil")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.orange)
      }

      Spacer()

      if let duration = sessionDuration {
        Text(duration)
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundStyle(.tertiary)
      }

      CloseButton { store.send(.hidePanel) }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(height: 40)
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

// MARK: - Close Button

private struct CloseButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.secondary)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { inside in
      if inside {
        NSCursor.arrow.push()
      } else {
        NSCursor.pop()
      }
    }
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

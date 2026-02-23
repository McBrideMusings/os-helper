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
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let overlayView = ContinuousListeningOverlayView(store: store)
    contentView = NSHostingView(rootView: overlayView)
  }
}

// MARK: - SwiftUI Overlay View

struct ContinuousListeningOverlayView: View {
  let store: StoreOf<ContinuousListeningFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Header
      HStack(spacing: 6) {
        PulsingDot()
        AudioLevelBars(level: store.meterLevel)
        Text("Listening...")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.primary)
        Spacer()
        Text("Press Enter to send")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      }

      Divider()

      // Body — text block list
      ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
          LazyVStack(alignment: .leading, spacing: 6) {
            if store.textBlocks.isEmpty {
              Text("Speak to start...")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .italic()
            } else {
              ForEach(store.textBlocks) { block in
                TextBlockView(block: block)
                  .id(block.id)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: store.textBlocks.count) {
          if let lastID = store.textBlocks.last?.id {
            withAnimation {
              proxy.scrollTo(lastID, anchor: .bottom)
            }
          }
        }
      }

      // Error
      if let error = store.error {
        Text(error)
          .font(.system(size: 10))
          .foregroundStyle(.red)
          .lineLimit(2)
      }
    }
    .padding(12)
    .frame(width: 320)
    .frame(minHeight: 80, maxHeight: 200)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}

// MARK: - Text Block View

private struct TextBlockView: View {
  let block: TextBlock

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      switch block.status {
      case .transcribing:
        ProgressView()
          .controlSize(.mini)
          .frame(width: 12, height: 12)
        Text("Transcribing...")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .italic()
      case .complete:
        Text(block.text)
          .font(.system(size: 13))
          .foregroundStyle(.primary)
          .textSelection(.enabled)
      case .error(let message):
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 10))
          .foregroundStyle(.red)
        Text(message)
          .font(.system(size: 11))
          .foregroundStyle(.red)
          .lineLimit(1)
      }
    }
  }
}

// MARK: - Audio Level Bars

private struct AudioLevelBars: View {
  let level: Float
  private let barCount = 5
  private let barWeights: [Float] = [0.6, 0.85, 1.0, 0.9, 0.7]

  var body: some View {
    HStack(spacing: 2) {
      ForEach(0..<barCount, id: \.self) { index in
        RoundedRectangle(cornerRadius: 1)
          .fill(.red.opacity(0.8))
          .frame(width: 3, height: barHeight(for: index))
      }
    }
    .frame(height: 14)
    .animation(.easeOut(duration: 0.08), value: level)
  }

  private func barHeight(for index: Int) -> CGFloat {
    let weight = barWeights[index]
    let minHeight: CGFloat = 2
    let maxHeight: CGFloat = 14
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

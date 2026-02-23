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
        Text("Listening...")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.primary)
        Spacer()
        Text("Press Enter to send")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      }

      Divider()

      // Body
      ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading) {
            if store.accumulatedText.isEmpty {
              Text("Speak to start...")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .italic()
            } else {
              Text(store.accumulatedText)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .id("text-bottom")
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: store.accumulatedText) {
          withAnimation {
            proxy.scrollTo("text-bottom", anchor: .bottom)
          }
        }
      }

      // Transcribing indicator
      if store.isTranscribingChunk {
        HStack(spacing: 4) {
          ProgressView()
            .controlSize(.mini)
          Text("Transcribing...")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
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

//
//  ScrollingCaptureHUDView.swift
//  Snapzy
//
//  SwiftUI content for the scrolling capture control HUD.
//  Chrome-free: the capsule glass buttons float on their own so the HUD never reads
//  as a second panel next to the preview rail.
//

import SwiftUI

struct ScrollingCaptureHUDView: View {
  @ObservedObject var model: ScrollingCaptureSessionModel
  let onStart: () -> Void
  let onDone: () -> Void
  let onCancel: () -> Void
  let onToggleAutoScroll: () -> Void
  @State private var isShowingHelp = false

  var body: some View {
    actionButtons
      .fixedSize(horizontal: true, vertical: false)
      .animation(LiquidGlassTokens.settleSpring, value: model.phase)
  }

  // MARK: - Actions

  @ViewBuilder
  private var actionButtons: some View {
    switch model.phase {
    case .ready:
      HStack(spacing: 8) {
        Button(L10n.Common.cancel, action: onCancel)
          .buttonStyle(.liquidGlass(emphasis: .secondary, capsule: true))

        Button(L10n.ScrollingCapture.startCapture, action: onStart)
          .buttonStyle(.liquidGlass(emphasis: .primary, capsule: true))
          .disabled(!model.canStartCapture)

        // Кнопка помощи рядом со Start Capture, как у эталона.
        Button { isShowingHelp.toggle() } label: {
          Image(systemName: "questionmark")
            .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.liquidGlass(emphasis: .secondary, capsule: true))
        .help(L10n.ScrollingCaptureHelp.helpButton)
        .accessibilityLabel(L10n.ScrollingCaptureHelp.helpButton)
        .popover(isPresented: $isShowingHelp, arrowEdge: .bottom) {
          ScrollingCaptureHelpView { isShowingHelp = false }
        }
      }
      .liquidGlassGroup(spacing: 8)

    case .capturing, .finalizing, .saving:
      HStack(spacing: 8) {
        Button(L10n.Common.cancel, action: onCancel)
          .buttonStyle(.liquidGlass(emphasis: .secondary, capsule: true))
          .disabled(!model.canCancelSession)

        Button(action: onToggleAutoScroll) {
          Label(
            model.isAutoScrolling ? L10n.ScrollingCapture.stopAutoScroll : L10n.ScrollingCapture.autoScroll,
            systemImage: model.isAutoScrolling ? "stop.fill" : "play.fill"
          )
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.liquidGlass(
          emphasis: model.isAutoScrolling ? .primary : .secondary,
          capsule: true
        ))
        .disabled(!model.canToggleAutoScroll)

        Button(L10n.Common.done, action: onDone)
          .buttonStyle(.liquidGlass(emphasis: .primary, capsule: true))
          .disabled(!model.canFinishCapture)
      }
      .liquidGlassGroup(spacing: 8)
    }
  }
}

// MARK: - Help

/// Страницы помощи эталона: выбор области, медленная прокрутка, направление и ограничения склейки.
enum ScrollingCaptureHelpPage: Int, CaseIterable {
  case area
  case scroll
  case orientation
  case limitations

  var title: String {
    switch self {
    case .area: L10n.ScrollingCaptureHelp.areaTitle
    case .scroll: L10n.ScrollingCaptureHelp.scrollTitle
    case .orientation: L10n.ScrollingCaptureHelp.orientationTitle
    case .limitations: L10n.ScrollingCaptureHelp.limitationsIntro
    }
  }

  var body: String {
    switch self {
    case .area: L10n.ScrollingCaptureHelp.areaBody
    case .scroll: L10n.ScrollingCaptureHelp.scrollBody
    case .orientation: L10n.ScrollingCaptureHelp.orientationBody
    case .limitations: L10n.ScrollingCaptureHelp.limitations
    }
  }

  var next: ScrollingCaptureHelpPage? {
    ScrollingCaptureHelpPage(rawValue: rawValue + 1)
  }
}

struct ScrollingCaptureHelpView: View {
  let onClose: () -> Void
  @State private var page: ScrollingCaptureHelpPage = .area

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if page == .area {
        ScrollingCaptureAreaIllustrations()
      }
      Text(page.title)
        .font(.system(size: 15, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
      Text(page.body)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        if let next = page.next {
          Button(L10n.ScrollingCaptureHelp.next) { page = next }
            .keyboardShortcut(.defaultAction)
        } else {
          Button(L10n.Common.done, action: onClose)
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(16)
    .frame(width: 340)
  }
}

/// Три схемы выбора области, нарисованные кодом: верная с галочкой и две неверные с крестиком.
private struct ScrollingCaptureAreaIllustrations: View {
  var body: some View {
    HStack(spacing: 10) {
      sample(selection: CGRect(x: 0.08, y: 0.28, width: 0.72, height: 0.64), isValid: true)
      // Выделение захватывает неподвижную шапку.
      sample(selection: CGRect(x: 0.08, y: 0.04, width: 0.72, height: 0.88), isValid: false)
      // Выделение захватывает полосу прокрутки.
      sample(selection: CGRect(x: 0.08, y: 0.28, width: 0.88, height: 0.64), isValid: false)
    }
  }

  private func sample(selection: CGRect, isValid: Bool) -> some View {
    GeometryReader { proxy in
      let size = proxy.size
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06))
        // Неподвижная шапка.
        Rectangle().fill(Color.primary.opacity(0.14))
          .frame(width: size.width, height: size.height * 0.2)
        // Строки содержимого.
        VStack(alignment: .leading, spacing: size.height * 0.07) {
          ForEach(0..<5, id: \.self) { index in
            Capsule().fill(Color.primary.opacity(0.18))
              .frame(width: size.width * (index.isMultiple(of: 2) ? 0.6 : 0.45), height: 3)
          }
        }
        .offset(x: size.width * 0.14, y: size.height * 0.34)
        // Полоса прокрутки.
        Capsule().fill(Color.primary.opacity(0.25))
          .frame(width: 3, height: size.height * 0.3)
          .offset(x: size.width * 0.9, y: size.height * 0.4)
        RoundedRectangle(cornerRadius: 3)
          .strokeBorder(isValid ? Color.green : Color.red, lineWidth: 1.5)
          .frame(width: size.width * selection.width, height: size.height * selection.height)
          .offset(x: size.width * selection.minX, y: size.height * selection.minY)
      }
      .overlay(alignment: .bottomTrailing) {
        Image(systemName: isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
          .font(.system(size: 14))
          .foregroundStyle(.white, isValid ? Color.green : Color.red)
          .offset(x: 5, y: 5)
      }
    }
    .frame(width: 96, height: 64)
  }
}

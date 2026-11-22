//
//  AnnotateImageDropZoneOverlay.swift
//  Snapzy
//
//  Четыре зоны при перетаскивании изображения на холст, где уже есть
//  изображение: градиенты у сторон, стрелка и подпись «Place on the …»
//  у ближайшей стороны (ANDropZoneView эталона).
//

import SwiftUI
import UniformTypeIdentifiers

/// Размер области перетаскивания для расчёта ближайшей стороны.
struct AnnotateDropAreaSizeKey: PreferenceKey {
  static var defaultValue: CGSize = .zero
  static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
    value = nextValue()
  }
}

/// Делегат перетаскивания: следит за курсором и выбирает сторону размещения.
struct AnnotateImageDropDelegate: DropDelegate {
  let areaSize: CGSize
  let hasImage: Bool
  @Binding var isDragOver: Bool
  @Binding var edge: AnnotateImageDropEdge?
  let perform: ([NSItemProvider], AnnotateImageDropEdge?) -> Bool

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [.fileURL, .image])
  }

  func dropEntered(info: DropInfo) {
    isDragOver = true
    updateEdge(info)
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    updateEdge(info)
    return DropProposal(operation: .copy)
  }

  func dropExited(info: DropInfo) {
    isDragOver = false
    edge = nil
  }

  func performDrop(info: DropInfo) -> Bool {
    let resolved = hasImage ? AnnotateImageDropEdge.closest(to: info.location, in: areaSize) : nil
    isDragOver = false
    edge = nil
    return perform(info.itemProviders(for: [.fileURL, .image]), resolved)
  }

  private func updateEdge(_ info: DropInfo) {
    let next = hasImage ? AnnotateImageDropEdge.closest(to: info.location, in: areaSize) : nil
    if next != edge { edge = next }
  }
}

struct AnnotateImageDropZoneOverlay: View {
  let edge: AnnotateImageDropEdge

  /// Глубина градиента у стороны.
  static let gradientDepth: CGFloat = 120

  var body: some View {
    ZStack {
      ForEach(AnnotateImageDropEdge.allCases, id: \.self) { side in
        gradient(for: side)
      }
      label
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: edge))
        .padding(28)
    }
    .animation(.easeOut(duration: 0.15), value: edge)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(edge.title)
  }

  private var label: some View {
    HStack(spacing: 6) {
      Image(systemName: edge.arrowSymbolName)
        .font(.system(size: 13, weight: .semibold))
      Text(edge.title)
        .font(.system(size: 13, weight: .medium))
    }
    .foregroundColor(.white)
    .padding(.horizontal, 12)
    .frame(height: 30)
    .background(Capsule().fill(Color.black.opacity(0.65)))
  }

  private func gradient(for side: AnnotateImageDropEdge) -> some View {
    let strength = side == edge ? 0.45 : 0.12
    let colors = [Color.accentColor.opacity(strength), Color.accentColor.opacity(0)]
    let isHorizontal = side == .left || side == .right
    return LinearGradient(colors: colors, startPoint: startPoint(for: side), endPoint: endPoint(for: side))
      .frame(
        width: isHorizontal ? Self.gradientDepth : nil,
        height: isHorizontal ? nil : Self.gradientDepth
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: side))
  }

  private func alignment(for side: AnnotateImageDropEdge) -> Alignment {
    switch side {
    case .top: return .top
    case .bottom: return .bottom
    case .left: return .leading
    case .right: return .trailing
    }
  }

  private func startPoint(for side: AnnotateImageDropEdge) -> UnitPoint {
    switch side {
    case .top: return .top
    case .bottom: return .bottom
    case .left: return .leading
    case .right: return .trailing
    }
  }

  private func endPoint(for side: AnnotateImageDropEdge) -> UnitPoint {
    switch side {
    case .top: return .bottom
    case .bottom: return .top
    case .left: return .trailing
    case .right: return .leading
    }
  }
}

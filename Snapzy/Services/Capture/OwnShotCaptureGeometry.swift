import Foundation
import CoreGraphics

nonisolated enum OwnShotCaptureGeometry {
  static func screenIndex(for selection: CGRect, in frames: [CGRect]) -> Int? {
    var bestIndex: Int?
    var bestArea: CGFloat = 0
    for (index, frame) in frames.enumerated() {
      let overlap = selection.intersection(frame)
      guard !overlap.isEmpty else { continue }
      let area = overlap.width * overlap.height
      if area > bestArea {
        bestIndex = index
        bestArea = area
      }
    }
    return bestIndex
  }

  static func toolbarOrigin(for selection: CGRect, panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
    let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
    let below = selection.minY - 30 - panelSize.height
    let preferredY = below >= bounds.minY ? below : selection.maxY + 30
    return CGPoint(
      x: min(max(selection.midX - panelSize.width / 2, bounds.minX), max(bounds.minX, bounds.maxX - panelSize.width)),
      y: min(max(preferredY, bounds.minY), max(bounds.minY, bounds.maxY - panelSize.height))
    )
  }

  static func resized(_ rect: CGRect, width: CGFloat?, height: CGFloat?, locked: Bool, within bounds: CGRect, keepingCenter: Bool = false) -> CGRect {
    guard rect.width > 0, rect.height > 0, !bounds.isEmpty else { return rect }
    var size = rect.size
    let ratio = rect.width / rect.height
    if let width {
      guard width.isFinite, width > 0 else { return rect }
      size.width = width
      if locked, height == nil { size.height = width / ratio }
    }
    if let height {
      guard height.isFinite, height > 0 else { return rect }
      size.height = height
      if locked, width == nil { size.width = height * ratio }
    }
    if locked {
      // Две явно заданные стороны пресета уменьшаются вместе в исходной пропорции.
      let factor = min(1, bounds.width / size.width, bounds.height / size.height)
      size.width *= factor
      size.height *= factor
    } else {
      size.width = min(size.width, bounds.width)
      size.height = min(size.height, bounds.height)
    }
    let origin = keepingCenter
      ? CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
      : rect.origin
    return CGRect(x: min(max(origin.x, bounds.minX), bounds.maxX - size.width), y: min(max(origin.y, bounds.minY), bounds.maxY - size.height), width: size.width, height: size.height)
  }

  static func applyingAspectRatio(_ ratio: CGFloat, to rect: CGRect, within bounds: CGRect) -> CGRect {
    guard ratio.isFinite, ratio > 0,
          rect.width.isFinite, rect.height.isFinite,
          rect.width > 0, rect.height > 0,
          bounds.width.isFinite, bounds.height.isFinite, !bounds.isEmpty else { return rect }
    let width = rect.height * ratio
    guard width.isFinite, width > 0 else { return rect }
    // Выбор пресета меняет ширину вокруг центра, сохраняя высоту, как в эталоне.
    let factor = min(1, bounds.width / width, bounds.height / rect.height)
    let size = CGSize(width: width * factor, height: rect.height * factor)
    return CGRect(
      x: min(max(rect.midX - size.width / 2, bounds.minX), bounds.maxX - size.width),
      y: min(max(rect.midY - size.height / 2, bounds.minY), bounds.maxY - size.height),
      width: size.width,
      height: size.height
    )
  }

  static func constrainedResize(_ proposed: CGRect, from start: CGRect, aspectRatio: CGFloat, within bounds: CGRect, fixedAnchor: CGPoint? = nil) -> CGRect {
    guard aspectRatio.isFinite, aspectRatio > 0, !bounds.isEmpty,
          proposed.width.isFinite, proposed.height.isFinite,
          proposed.width > 0, proposed.height > 0 else { return start }
    let movesLeft = abs(proposed.minX - start.minX) > 0.001
    let movesRight = abs(proposed.maxX - start.maxX) > 0.001
    let movesBottom = abs(proposed.minY - start.minY) > 0.001
    let movesTop = abs(proposed.maxY - start.maxY) > 0.001
    let anchorX: CGFloat = fixedAnchor?.x ?? (movesLeft ? 1 : movesRight ? 0 : 0.5)
    let anchorY: CGFloat = fixedAnchor?.y ?? (movesBottom ? 1 : movesTop ? 0 : 0.5)
    let anchor = CGPoint(x: start.minX + start.width * anchorX, y: start.minY + start.height * anchorY)
    let widthDrives = abs(proposed.width - start.width) / aspectRatio >= abs(proposed.height - start.height)
    var width = widthDrives ? proposed.width : proposed.height * aspectRatio
    var height = width / aspectRatio
    // Минимальный размер обеих сторон не должен ломать выбранную пропорцию.
    let minimumScale = max(1, 50 / width, 50 / height)
    width *= minimumScale
    height *= minimumScale
    let availableWidth = anchorX == 0 ? bounds.maxX - anchor.x
      : anchorX == 1 ? anchor.x - bounds.minX
      : 2 * min(anchor.x - bounds.minX, bounds.maxX - anchor.x)
    let availableHeight = anchorY == 0 ? bounds.maxY - anchor.y
      : anchorY == 1 ? anchor.y - bounds.minY
      : 2 * min(anchor.y - bounds.minY, bounds.maxY - anchor.y)
    guard availableWidth > 0, availableHeight > 0 else { return start }
    let factor = min(1, availableWidth / width, availableHeight / height)
    let size = CGSize(width: width * factor, height: height * factor)
    return CGRect(x: anchor.x - size.width * anchorX, y: anchor.y - size.height * anchorY, width: size.width, height: size.height)
  }
}

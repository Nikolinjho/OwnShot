import AppKit
import SwiftUI

/// Нативный ползунок управляет тем же смещением, что колесо и инструмент руки.
struct AnnotateCanvasScrollbar: NSViewRepresentable {
  @ObservedObject var state: AnnotateState
  let vertical: Bool

  static var thickness: CGFloat {
    NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
  }

  func makeNSView(context: Context) -> AnnotateCanvasScroller {
    AnnotateCanvasScroller(state: state, vertical: vertical)
  }

  func updateNSView(_ view: AnnotateCanvasScroller, context: Context) {
    view.synchronize()
  }
}

final class AnnotateCanvasScroller: NSScroller {
  private weak var state: AnnotateState?
  private let vertical: Bool

  init(state: AnnotateState, vertical: Bool) {
    self.state = state
    self.vertical = vertical
    let thickness = AnnotateCanvasScrollbar.thickness
    super.init(frame: CGRect(x: 0, y: 0,
      width: vertical ? thickness : 100, height: vertical ? 100 : thickness))
    scrollerStyle = .legacy
    isContinuous = true
    target = self
    action = #selector(scrollCanvas)
    synchronize()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func scrollWheel(with event: NSEvent) {
    state?.pan(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
    synchronize()
  }

  private var viewportLength: CGFloat {
    guard let state else { return 0 }
    return vertical ? state.canvasContainerSize.height : state.canvasContainerSize.width
  }

  private var contentLength: CGFloat {
    guard let state else { return 0 }
    return (vertical ? state.baseCanvasDisplaySize.height : state.baseCanvasDisplaySize.width) * state.zoomLevel
  }

  func synchronize() {
    guard let state else { return }
    let range = max(0, contentLength - viewportLength)
    isEnabled = range > 0.5
    isHidden = !isEnabled
    knobProportion = min(1, viewportLength / max(1, contentLength))
    let offset = vertical ? state.panOffset.height : state.panOffset.width
    doubleValue = range > 0 ? Double(min(1, max(0, 0.5 - offset / range))) : 0
  }

  @objc private func scrollCanvas() {
    guard let state else { return }
    let range = contentLength - viewportLength
    guard range > 0.5 else { return }
    var position = CGFloat(doubleValue)
    switch hitPart {
    case .decrementLine: position -= 20 / range
    case .incrementLine: position += 20 / range
    case .decrementPage: position -= viewportLength * 0.9 / range
    case .incrementPage: position += viewportLength * 0.9 / range
    default: break
    }
    let offset = (0.5 - min(1, max(0, position))) * range
    let delta = vertical
      ? CGSize(width: 0, height: offset - state.panOffset.height)
      : CGSize(width: offset - state.panOffset.width, height: 0)
    state.pan(by: delta)
    synchronize()
  }
}

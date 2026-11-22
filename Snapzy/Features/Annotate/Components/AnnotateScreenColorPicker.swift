//
//  AnnotateScreenColorPicker.swift
//  Snapzy
//
//  Собственная пипетка-лупа по контракту GlobalColorPicker эталона:
//  NSWindowController с таймером и PickerView (gridSize, magnification,
//  labelView, label, swatch, currentColor) в PickerWindow (NSPanel,
//  canBecomeKeyWindow, cancelOperation:, resignKeyWindow). mouseUp: выбирает
//  цвет под курсором, Escape и потеря ключевого окна отменяют выбор.
//

import AppKit
import CoreGraphics

/// Геометрия и выборка пикселей лупы, без окон – для тестов.
nonisolated enum AnnotateScreenColorPickerGeometry {
  /// Пикселей экрана по стороне сетки. Нечётное: центральная ячейка – выбираемый пиксель.
  static let gridSize = 11
  /// Точек на один пиксель экрана в лупе.
  static let magnification: CGFloat = 10
  static let labelHeight: CGFloat = 22
  static let labelGap: CGFloat = 6
  static let labelWidth: CGFloat = 96

  static var loupeDiameter: CGFloat { CGFloat(gridSize) * magnification }

  static var windowSize: CGSize {
    CGSize(width: max(loupeDiameter, labelWidth), height: loupeDiameter + labelGap + labelHeight)
  }

  /// Рамка окна в координатах AppKit: центр лупы совпадает с курсором, подпись под лупой.
  static func windowFrame(cursor: CGPoint) -> CGRect {
    let size = windowSize
    return CGRect(
      x: cursor.x - size.width / 2,
      y: cursor.y + loupeDiameter / 2 - size.height,
      width: size.width,
      height: size.height
    )
  }

  /// Прямоугольник захвата в глобальных координатах CG (начало слева сверху у главного экрана),
  /// выровненный по пикселям так, чтобы пиксель под курсором стал центральной ячейкой.
  static func captureRect(cursor: CGPoint, primaryScreenHeight: CGFloat, backingScale: CGFloat) -> CGRect {
    let scale = max(backingScale, 1)
    let cgY = primaryScreenHeight - cursor.y
    let pixelX = floor(cursor.x * scale)
    // Точка AppKit на нижней границе пикселя принадлежит пикселю выше: сдвигаем на эпсилон.
    let pixelY = floor((cgY - 0.0001) * scale)
    let half = CGFloat(gridSize / 2)
    let side = CGFloat(gridSize) / scale
    return CGRect(x: (pixelX - half) / scale, y: (pixelY - half) / scale, width: side, height: side)
  }

  /// Пиксели снимка в sRGB построчно сверху вниз, gridSize × gridSize.
  /// Снимок другого размера масштабируется без интерполяции.
  static func pixels(of image: CGImage) -> [RGBAColor]? {
    let side = gridSize
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return nil }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let data = context.data else { return nil }
    let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
    var result: [RGBAColor] = []
    result.reserveCapacity(side * side)
    // Первая строка буфера CGContext – верх изображения.
    for row in 0..<side {
      for column in 0..<side {
        let offset = (row * side + column) * 4
        let alpha = Double(bytes[offset + 3]) / 255
        let unpremultiply = alpha > 0 ? 1 / alpha : 0
        result.append(RGBAColor(
          red: Double(bytes[offset]) / 255 * unpremultiply,
          green: Double(bytes[offset + 1]) / 255 * unpremultiply,
          blue: Double(bytes[offset + 2]) / 255 * unpremultiply,
          alpha: alpha
        ))
      }
    }
    return result
  }

  /// Цвет центральной ячейки сетки.
  static func centerColor(of pixels: [RGBAColor]) -> RGBAColor? {
    let center = (gridSize / 2) * gridSize + gridSize / 2
    guard pixels.count == gridSize * gridSize else { return nil }
    let color = pixels[center]
    // Экран непрозрачен, альфа снимка в выбранный цвет не переносится.
    return RGBAColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
  }

  /// Подпись лупы: «#RRGGBB».
  static func hexString(_ color: RGBAColor) -> String {
    func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
  }
}

/// Пипетка-лупа. Держит себя сама, пока идёт выбор, отдаёт sRGB-цвет или nil при отмене.
@MainActor
final class AnnotateScreenColorPicker: NSWindowController {
  private static var active: AnnotateScreenColorPicker?

  private var completion: ((RGBAColor?) -> Void)?
  private var timer: Timer?
  private weak var pickerView: AnnotateScreenColorPickerView?
  private var currentColor: RGBAColor?
  private var hidesCursor = false

  /// Запускает выбор цвета. Без разрешения на запись экрана снимок содержит только
  /// обои и свои окна, тогда работает системный NSColorSampler.
  static func pick(completion: @escaping (RGBAColor?) -> Void) {
    active?.finish(with: nil)
    guard CGPreflightScreenCaptureAccess() else {
      NSColorSampler().show { picked in
        let rgba = picked?.usingColorSpace(.sRGB).map {
          RGBAColor(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent, alpha: 1)
        }
        DispatchQueue.main.async { completion(rgba) }
      }
      return
    }
    let picker = AnnotateScreenColorPicker(completion: completion)
    active = picker
    picker.start()
  }

  private init(completion: @escaping (RGBAColor?) -> Void) {
    self.completion = completion
    let window = AnnotateScreenColorPickerWindow(
      contentRect: CGRect(origin: .zero, size: AnnotateScreenColorPickerGeometry.windowSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    super.init(window: window)
    let view = AnnotateScreenColorPickerView(frame: CGRect(origin: .zero, size: AnnotateScreenColorPickerGeometry.windowSize))
    view.onPick = { [weak self] in self?.finish(with: self?.currentColor) }
    view.onCancel = { [weak self] in self?.finish(with: nil) }
    window.contentView = view
    window.initialFirstResponder = view
    window.onCancel = { [weak self] in self?.finish(with: nil) }
    pickerView = view
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func start() {
    guard let window else { return }
    update()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(pickerView)
    NSCursor.hide()
    hidesCursor = true
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.update() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  /// Ход таймера: окно за курсором, снимок пикселей под ним без самой лупы.
  private func update() {
    guard let window else { return }
    let cursor = NSEvent.mouseLocation
    window.setFrame(AnnotateScreenColorPickerGeometry.windowFrame(cursor: cursor), display: false)
    let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
    let primaryHeight = NSScreen.screens.first?.frame.height ?? screen?.frame.height ?? 0
    let rect = AnnotateScreenColorPickerGeometry.captureRect(
      cursor: cursor,
      primaryScreenHeight: primaryHeight,
      backingScale: screen?.backingScaleFactor ?? 1
    )
    let windowID = CGWindowID(window.windowNumber)
    let image = windowID > 0
      ? CGWindowListCreateImage(rect, .optionOnScreenBelowWindow, windowID, .bestResolution)
      : nil
    let pixels = image.flatMap(AnnotateScreenColorPickerGeometry.pixels(of:))
    currentColor = pixels.flatMap(AnnotateScreenColorPickerGeometry.centerColor(of:))
    pickerView?.update(pixels: pixels, color: currentColor)
  }

  private func finish(with color: RGBAColor?) {
    guard let completion else { return }
    self.completion = nil
    timer?.invalidate()
    timer = nil
    if hidesCursor {
      NSCursor.unhide()
      hidesCursor = false
    }
    (window as? AnnotateScreenColorPickerWindow)?.onCancel = nil
    window?.orderOut(nil)
    if Self.active === self { Self.active = nil }
    completion(color)
  }
}

/// PickerWindow эталона: панель поверх всего, принимает клавиши и отменяет выбор,
/// когда перестаёт быть ключевой.
final class AnnotateScreenColorPickerWindow: NSPanel {
  var onCancel: (() -> Void)?

  override init(
    contentRect: NSRect,
    styleMask style: NSWindow.StyleMask,
    backing backingStoreType: NSWindow.BackingStoreType,
    defer flag: Bool
  ) {
    super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
    level = .screenSaver
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    setAccessibilityLabel(L10n.AnnotateScreenColorPicker.loupe)
  }

  override var canBecomeKey: Bool { true }

  override func cancelOperation(_ sender: Any?) {
    onCancel?()
  }

  override func resignKey() {
    super.resignKey()
    onCancel?()
  }
}

/// PickerView эталона: увеличенная сетка пикселей, центральная ячейка, подпись и образец.
final class AnnotateScreenColorPickerView: NSView {
  var onPick: (() -> Void)?
  var onCancel: (() -> Void)?
  private var pixels: [RGBAColor]?
  private var currentColor: RGBAColor?

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  func update(pixels: [RGBAColor]?, color: RGBAColor?) {
    self.pixels = pixels
    currentColor = color
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    onPick?()
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 53: onCancel?() // Escape
    case 36, 76: onPick?() // Return, Enter
    default: super.keyDown(with: event)
    }
  }

  override func cancelOperation(_ sender: Any?) {
    onCancel?()
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let geometry = AnnotateScreenColorPickerGeometry.self
    let diameter = geometry.loupeDiameter
    let loupe = CGRect(x: (bounds.width - diameter) / 2, y: bounds.height - diameter, width: diameter, height: diameter)
    let side = geometry.gridSize
    let cell = geometry.magnification

    context.saveGState()
    context.addEllipse(in: loupe)
    context.clip()
    NSColor.black.setFill()
    context.fill(loupe)
    if let pixels, pixels.count == side * side {
      for row in 0..<side {
        for column in 0..<side {
          let color = pixels[row * side + column]
          context.setFillColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
          // Строка 0 – верх снимка, в невёрнутом NSView верх – большие y.
          context.fill(CGRect(
            x: loupe.minX + CGFloat(column) * cell,
            y: loupe.maxY - CGFloat(row + 1) * cell,
            width: cell,
            height: cell
          ))
        }
      }
    }
    // Сетка пикселей.
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    context.setLineWidth(0.5)
    for index in 1..<side {
      let offset = CGFloat(index) * cell
      context.move(to: CGPoint(x: loupe.minX + offset, y: loupe.minY))
      context.addLine(to: CGPoint(x: loupe.minX + offset, y: loupe.maxY))
      context.move(to: CGPoint(x: loupe.minX, y: loupe.minY + offset))
      context.addLine(to: CGPoint(x: loupe.maxX, y: loupe.minY + offset))
    }
    context.strokePath()
    // Центральная ячейка – выбираемый пиксель.
    let center = CGRect(
      x: loupe.minX + CGFloat(side / 2) * cell,
      y: loupe.minY + CGFloat(side / 2) * cell,
      width: cell,
      height: cell
    )
    context.setStrokeColor(NSColor.black.cgColor)
    context.setLineWidth(2)
    context.stroke(center.insetBy(dx: -1, dy: -1))
    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(1)
    context.stroke(center)
    context.restoreGState()

    // Обводка лупы.
    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(3)
    context.strokeEllipse(in: loupe.insetBy(dx: 1.5, dy: 1.5))
    context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
    context.setLineWidth(1)
    context.strokeEllipse(in: loupe.insetBy(dx: 0.5, dy: 0.5))

    drawLabel(in: context)
  }

  private func drawLabel(in context: CGContext) {
    let geometry = AnnotateScreenColorPickerGeometry.self
    let labelRect = CGRect(
      x: (bounds.width - geometry.labelWidth) / 2,
      y: 0,
      width: geometry.labelWidth,
      height: geometry.labelHeight
    )
    let background = NSBezierPath(roundedRect: labelRect, xRadius: geometry.labelHeight / 2, yRadius: geometry.labelHeight / 2)
    NSColor.black.withAlphaComponent(0.75).setFill()
    background.fill()

    guard let color = currentColor else { return }
    let swatch = CGRect(x: labelRect.minX + 8, y: labelRect.midY - 5, width: 10, height: 10)
    context.setFillColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
    context.fillEllipse(in: swatch)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
    context.setLineWidth(1)
    context.strokeEllipse(in: swatch)

    let text = geometry.hexString(color) as NSString
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
      .foregroundColor: NSColor.white,
    ]
    let size = text.size(withAttributes: attributes)
    text.draw(
      at: CGPoint(x: swatch.maxX + 6, y: labelRect.midY - size.height / 2),
      withAttributes: attributes
    )
  }
}

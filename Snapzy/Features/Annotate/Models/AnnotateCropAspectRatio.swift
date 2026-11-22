//
//  CropAspectRatio.swift
//  Snapzy
//
//  Aspect ratio options for crop tool
//

import Foundation

/// Predefined aspect ratio options for crop tool
enum CropAspectRatio: String, CaseIterable, Identifiable {
  case free = "Free"
  case square = "1:1"
  case ratio5x4 = "5:4"
  case ratio7x5 = "7:5"
  case ratio4x3 = "4:3"
  case ratio3x2 = "3:2"
  case ratio16x9 = "16:9"
  case ratio21x9 = "21:9"

  var id: String { rawValue }

  /// The numeric ratio (width / height)
  var ratio: CGFloat {
    switch self {
    case .free: return 0  // No constraint
    case .square: return 1.0
    case .ratio5x4: return 5.0 / 4.0
    case .ratio7x5: return 7.0 / 5.0
    case .ratio4x3: return 4.0 / 3.0
    case .ratio3x2: return 3.0 / 2.0
    case .ratio16x9: return 16.0 / 9.0
    case .ratio21x9: return 21.0 / 9.0
    }
  }

  /// Effective ratio accounting for portrait orientation.
  func effectiveRatio(isPortrait: Bool) -> CGFloat {
    let r = ratio
    guard r > 0 else { return 0 }
    return isPortrait ? 1.0 / r : r
  }

  /// Display name for UI
  var displayName: String {
    switch self {
    case .free:
      return L10n.Common.free
    default:
      return rawValue
    }
  }

  /// Effective display name accounting for portrait orientation.
  func effectiveDisplayName(isPortrait: Bool) -> String {
    switch self {
    case .free:
      return L10n.Common.free
    case .square:
      return rawValue
    case .ratio5x4:
      return isPortrait ? "4:5" : rawValue
    case .ratio7x5:
      return isPortrait ? "5:7" : rawValue
    case .ratio4x3:
      return isPortrait ? "3:4" : rawValue
    case .ratio3x2:
      return isPortrait ? "2:3" : rawValue
    case .ratio16x9:
      return isPortrait ? "9:16" : rawValue
    case .ratio21x9:
      return isPortrait ? "9:21" : rawValue
    }
  }

  /// Icon for the aspect ratio
  var icon: String {
    switch self {
    case .free: return "arrow.up.left.and.arrow.down.right"
    case .square: return "square"
    case .ratio5x4, .ratio7x5: return "rectangle"
    case .ratio4x3: return "rectangle"
    case .ratio3x2: return "rectangle"
    case .ratio16x9: return "rectangle.ratio.16.to.9"
    case .ratio21x9: return "rectangle"
    }
  }
}

/// Размер загруженного исходника до поворотов и других преобразований.
nonisolated struct OriginalCropSourceSize: Codable, Equatable {
  let logicalSize: CGSize
  let backingSize: CGSize?

  var ratio: CGFloat? {
    guard logicalSize.width.isFinite, logicalSize.width > 0,
          logicalSize.height.isFinite, logicalSize.height > 0 else { return nil }
    let ratio = logicalSize.width / logicalSize.height
    return ratio.isFinite && ratio > 0 ? ratio : nil
  }

  var components: (width: Int, height: Int)? {
    CropRatioFieldValues.reducedComponents(of: logicalSize)
      ?? backingSize.flatMap(CropRatioFieldValues.reducedComponents(of:))
  }
}

/// Поля отношения в панели Crop эталона (widthRatioTextField/heightRatioTextField):
/// показывают части текущего отношения, во Freeform пустые.
nonisolated enum CropRatioFieldValues {
  static func title(width: Int, height: Int) -> String {
    "\(width) : \(height)"
  }

  static func reducedComponents(of size: CGSize) -> (width: Int, height: Int)? {
    guard let width = Int(exactly: size.width), let height = Int(exactly: size.height),
          width > 0, height > 0 else { return nil }
    var divisor = width
    var remainder = height
    while remainder != 0 {
      (divisor, remainder) = (remainder, divisor % remainder)
    }
    return (width / divisor, height / divisor)
  }

  /// Части отношения из подписи «7 : 5» или «16:9».
  static func components(fromTitle title: String) -> (width: Int, height: Int)? {
    let parts = title.split(separator: ":", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 2,
          let width = AnnotateIntegerInput.positiveInteger(from: parts[0]),
          let height = AnnotateIntegerInput.positiveInteger(from: parts[1]) else { return nil }
    return (width, height)
  }
}

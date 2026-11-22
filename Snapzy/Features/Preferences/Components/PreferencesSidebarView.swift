// OwnShot settings navigation. Upstream reusable icon helpers retained below.
import AppKit
import SwiftUI

struct PreferencesSidebarView: View {
  @ObservedObject var navigationState: PreferencesNavigationState
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.colorScheme) private var colorScheme

  private var isActive: Bool { controlActiveState != .inactive }
  private var isDark: Bool { colorScheme == .dark }

  var body: some View {
    VStack(spacing: 0) {
      Button { navigationState.select(.cloud) } label: {
        HStack(spacing: 10) {
          Image(systemName: "person.crop.circle.fill")
            .resizable().scaledToFit().frame(width: 35, height: 35)
            .foregroundStyle(.secondary)
            .opacity(PreferencesSidebarChrome.iconOpacity(isActive: isActive))
          VStack(alignment: .leading, spacing: 2) {
            Text("Cloud").font(.system(size: 14, weight: .semibold))
              .foregroundStyle(PreferencesSidebarChrome.labelColor(isDark: isDark, isActive: isActive))
            Text("Coming later").font(.system(size: 12)).foregroundStyle(.secondary)
              .opacity(PreferencesSidebarChrome.iconOpacity(isActive: isActive))
          }
          Spacer()
        }
        .padding(.horizontal, 16).frame(height: 74)
      }.buttonStyle(.plain)
      .padding(.bottom, 5)
      ScrollView {
        VStack(spacing: 4) {
          ForEach(PreferencesTab.sidebarOrder.filter { $0 != .about }) { tab in row(tab) }
        }.padding(.horizontal, 10)
      }
      Spacer(minLength: 8)
      row(.about).padding(.horizontal, 10).padding(.bottom, 12)
    }
    .padding(.top, 40)
    // Сайдбар эталона почти непрозрачный (замер 15.11.2026), поэтому вместо материала – сплошной цвет темы.
    // В неактивном окне светлый сайдбар светлеет до #F3F2F1 (R06).
    .background(PreferencesSidebarBackground.color(isActive: isActive).ignoresSafeArea())
  }

  private func row(_ tab: PreferencesTab) -> some View {
    let isSelected = navigationState.selectedTab == tab
    return Button { navigationState.select(tab) } label: {
      HStack(spacing: 9.5) {
        PreferencesSidebarIcon(tab: tab, size: 24)
          .opacity(PreferencesSidebarChrome.iconOpacity(isActive: isActive))
        Text(tab.title).font(.system(size: 13)).lineLimit(1)
          .foregroundStyle(PreferencesSidebarChrome.labelColor(isDark: isDark, isActive: isActive))
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 6).frame(height: 36)
      // Выбор нейтральный и непрозрачный, без акцента (R17)
      .background(
        PreferencesSidebarChrome.selectionColor(isDark: isDark, isActive: isActive).opacity(isSelected ? 1 : 0),
        in: RoundedRectangle(cornerRadius: 12)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// Цвета сайдбара Settings по кадрам spec-050-visual/*/settings-general-on-*.png (активное окно)
/// и spec-051-pairs/reference-*/settings-general-inactive-on-000000.png (неактивное).
enum PreferencesSidebarChrome {
  /// R17: выбранная строка 200×36 pt. Light #DCDCDC на #EDEDEC, Dark #3D3A39 на #2D2A29.
  /// В неактивном окне выбор бледнеет: Light #EAE9E8 на #F3F2F1, Dark #333130 на #2C2928.
  static func selectionHex(isDark: Bool, isActive: Bool) -> UInt32 {
    switch (isDark, isActive) {
    case (false, true): 0xDCDCDC
    case (false, false): 0xEAE9E8
    case (true, true): 0x3D3A39
    case (true, false): 0x333130
    }
  }

  /// R16: подписи. Light чёрный 0.77 → 0.35 (#3A3A39 на #ECECEB → #9D9D9C на #F3F2F1),
  /// Dark белый 0.92 → 0.45 (#EAEAEA → #8B8A89 на #2C2928).
  static func labelOpacity(isDark: Bool, isActive: Bool) -> Double {
    switch (isDark, isActive) {
    case (false, true): 0.77
    case (false, false): 0.35
    case (true, true): 0.92
    case (true, false): 0.45
    }
  }

  /// R16: значки в неактивном окне ровно 50 %
  static func iconOpacity(isActive: Bool) -> Double {
    isActive ? 1 : 0.5
  }

  static func selectionColor(isDark: Bool, isActive: Bool) -> Color {
    let rgb = selectionHex(isDark: isDark, isActive: isActive)
    return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                 green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
  }

  static func labelColor(isDark: Bool, isActive: Bool) -> Color {
    (isDark ? Color.white : Color.black).opacity(labelOpacity(isDark: isDark, isActive: isActive))
  }
}

/// Фон сайдбара Settings: сплошной цвет темы вместо материала .sidebar.
enum PreferencesSidebarBackground {
  /// Эталон в светлой теме: (236,236,235) на чёрном и (237,237,236) на белом фоне.
  static let lightHex: UInt32 = 0xECECEB
  /// Светлая тема, неактивное окно: материал становится непрозрачным #F3F2F1 (R06,
  /// spec-051-pairs/reference-light/settings-general-inactive-on-000000.png)
  static let lightInactiveHex: UInt32 = 0xF3F2F1
  /// Эталон в тёмной теме: (44,41,40) на чёрном и (46,43,42) на белом фоне; в неактивном тот же.
  static let darkHex: UInt32 = 0x2C2928

  static func hex(isDark: Bool, isActive: Bool = true) -> UInt32 {
    if isDark { return darkHex }
    return isActive ? lightHex : lightInactiveHex
  }

  static func hex(for appearance: NSAppearance, isActive: Bool = true) -> UInt32 {
    let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantDark, .vibrantLight])
    return hex(isDark: match == .darkAqua || match == .vibrantDark, isActive: isActive)
  }

  static let nsColor = makeColor(isActive: true)
  static let inactiveNSColor = makeColor(isActive: false)

  private static func makeColor(isActive: Bool) -> NSColor {
    let name = isActive ? "OwnShotPreferencesSidebarBackground" : "OwnShotPreferencesSidebarBackgroundInactive"
    return NSColor(name: NSColor.Name(name)) { appearance in
      let rgb = hex(for: appearance, isActive: isActive)
      return NSColor(
        srgbRed: CGFloat((rgb >> 16) & 255) / 255,
        green: CGFloat((rgb >> 8) & 255) / 255,
        blue: CGFloat(rgb & 255) / 255,
        alpha: 1
      )
    }
  }

  static let color = Color(nsColor: nsColor)
  static let inactiveColor = Color(nsColor: inactiveNSColor)

  static func color(isActive: Bool) -> Color {
    isActive ? color : inactiveColor
  }
}

struct PreferencesIconTint: Equatable {
  /// Hue in degrees on the color wheel.
  var hue: Double
  var saturation: Double = 0.6

  static let blue = PreferencesIconTint(hue: 214)
  static let periwinkle = PreferencesIconTint(hue: 238)
  static let graphite = PreferencesIconTint(hue: 225, saturation: 0.07)

  /// Near-white silver for the primary layer of a duotone glyph, so the tint reads as an accent.
  static var silver: LinearGradient {
    LinearGradient(
      colors: [Color(white: 0.98), Color(white: 0.76)],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  var gradient: LinearGradient {
    LinearGradient(
      colors: [
        Color(hue: wrapped(hue - 3), saturation: saturation * 0.55, brightness: 1),
        Color(hue: wrapped(hue + 3), saturation: saturation, brightness: 0.86),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  private func wrapped(_ degrees: Double) -> Double {
    (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
  }
}

extension PreferencesTab {
  /// Each page's glyph color, picked to match what the glyph depicts; neighbours within a
  /// sidebar group never share a hue family.
  var iconTint: PreferencesIconTint {
    switch self {
    case .general: return .graphite
    case .wallpaper: return PreferencesIconTint(hue: 190)
    case .recording: return PreferencesIconTint(hue: 350)
    case .capture: return .blue
    case .quickAccess: return PreferencesIconTint(hue: 155)
    case .shortcuts: return .graphite
    case .annotate: return PreferencesIconTint(hue: 30)
    case .history: return PreferencesIconTint(hue: 40, saturation: 0.66)
    case .menuBar: return PreferencesIconTint(hue: 174)
    case .cloud: return PreferencesIconTint(hue: 198)
    case .permissions: return PreferencesIconTint(hue: 18, saturation: 0.64)
    case .commandLine: return PreferencesIconTint(hue: 305, saturation: 0.5)
    case .advanced: return PreferencesIconTint(hue: 265)
    case .about: return .blue
    }
  }
}

/// System Settings-style squircle: one near-black tile for every page, each glyph tinted in
/// its page's color. About uses the menu bar brand mark on the same tile. `duotone` (page
/// heroes) draws the glyph silver with the page color as its accent layer.
struct PreferencesSidebarIcon: View {
  let tab: PreferencesTab
  var size: CGFloat = 22
  var duotone = false

  var body: some View {
    if let resourceName {
      OwnShotIcons.image(resourceName)
        .resizable()
        .frame(width: size, height: size)
    } else {
      Image(systemName: tab.symbol)
        .font(.system(size: size * 0.65, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(sidebarGradient, in: RoundedRectangle(cornerRadius: size * 0.26))
    }
  }

  private var resourceName: String? {
    switch tab {
    case .general: "prefGeneral"
    case .capture: "prefScreenshots"
    case .recording: "prefScreenRecording"
    case .quickAccess: "prefQuickAccess"
    case .wallpaper: "prefWallpaper"
    case .annotate: "prefAnnotate"
    case .shortcuts: "prefShortcuts"
    case .advanced: "prefAdvanced"
    case .about: "prefAbout"
    case .cloud: "prefCloud"
    default: nil
    }
  }

  private var sidebarGradient: LinearGradient {
    let colors: (UInt32, UInt32)
    switch tab {
    case .general, .shortcuts, .about: colors = (0x929292, 0x555555)
    case .quickAccess: colors = (0x16A974, 0x078050)
    case .wallpaper: colors = (0x83CDDA, 0x5DAFC9)
    case .capture: colors = (0x1D99FD, 0x0A68FF)
    case .recording: colors = (0xDB3F65, 0xCA2844)
    case .annotate: colors = (0xF39B24, 0xED6E17)
    case .cloud: colors = (0x35AEF3, 0x2286EC)
    case .advanced: colors = (0x8950CE, 0x512FAD)
    default: colors = (0x438DF5, 0x336DF3)
    }
    return LinearGradient(
      colors: [color(colors.0), color(colors.1)],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  private func color(_ rgb: UInt32) -> Color {
    Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
          green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
  }
}

/// A bold rounded SF Symbol on the near-black settings tile. Duotone renders the symbol's
/// layers as a palette: silver body, tinted accent.
struct PreferencesSymbolTile: View {
  let symbol: String
  var size: CGFloat = 22
  var tint: PreferencesIconTint = .blue
  var duotone = false

  var body: some View {
    PreferencesIconTile(size: size, tint: tint, duotone: duotone) {
      Image(systemName: symbol)
        .symbolRenderingMode(duotone ? .palette : .monochrome)
        .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
    }
  }
}

/// Near-black glossy tile (Droppy-style): deep falloff toward the bottom, with a rim that
/// catches light at the top edge and fades out, so it reads like a tiny app icon.
/// Corner scales with `size`, so the same tile works from sidebar rows up to page heroes.
/// No drop shadow at any size; large tiles take an Icon Composer-style specular rim.
struct PreferencesIconTile<Glyph: View>: View {
  var size: CGFloat
  var tint: PreferencesIconTint = .blue
  var duotone = false
  @ViewBuilder let glyph: () -> Glyph

  private var isLarge: Bool { size > 36 }

  var body: some View {
    let shape = isLarge ? Radius.rect(size * 0.24) : Radius.controlRect(forHeight: size)
    styledGlyph
      .frame(width: size, height: size)
      .background {
        shape.fill(LinearGradient(
          colors: [Color(white: 0.18), Color(white: 0.05)],
          startPoint: .top,
          endPoint: .bottom
        ))
      }
      .overlay {
        if isLarge {
          specularRim(shape)
        } else {
          shape.strokeBorder(
            LinearGradient(
              colors: [Color.white.opacity(0.24), Color.white.opacity(0.04)],
              startPoint: .top,
              endPoint: .bottom
            ),
            lineWidth: 0.5
          )
        }
      }
  }

  @ViewBuilder
  private var styledGlyph: some View {
    if duotone {
      glyph().foregroundStyle(PreferencesIconTint.silver, tint.gradient)
    } else {
      glyph().foregroundStyle(tint.gradient)
    }
  }

  /// Light hits the top-left edge and glints again at the bottom-right, like the glass edge
  /// Icon Composer renders on macOS 26 icons; a dark inner hairline keeps the rim off the fill.
  private func specularRim(_ shape: RoundedRectangle) -> some View {
    let rimWidth = size * 0.022
    return ZStack {
      shape.strokeBorder(
        LinearGradient(
          stops: [
            .init(color: Color.white.opacity(0.55), location: 0),
            .init(color: Color.white.opacity(0.16), location: 0.3),
            .init(color: Color.white.opacity(0.05), location: 0.55),
            .init(color: Color.white.opacity(0.32), location: 1),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ),
        lineWidth: rimWidth
      )
      shape
        .inset(by: rimWidth)
        .strokeBorder(Color.black.opacity(0.55), lineWidth: 0.75)
    }
  }
}

struct PreferencesAppIconImage: View {
  var size: CGFloat

  var body: some View {
    Image(nsImage: NSApp.applicationIconImage)
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
  }
}

// MARK: - Focus Effect Disabled Modifier (macOS 13 compat)

private struct SidebarFocusEffectDisabledModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 14.0, *) {
      content.focusEffectDisabled()
    } else {
      content
    }
  }
}

//
//  PreferencesView.swift
//  Snapzy
//
//  Root preferences window: NavigationSplitView with the tiled sidebar and grouped-form detail.
//

import SwiftUI

struct PreferencesView: View {
  @ObservedObject private var themeManager = ThemeManager.shared
  @ObservedObject private var navigationState = PreferencesNavigationState.shared

  /// Fixed sidebar width prevents divider dragging and accidental collapsing.
  private static let fixedSidebarWidth: CGFloat = 220

  var body: some View {
    NavigationSplitView(columnVisibility: columnVisibilityBinding) {
      sidebar.ignoresSafeArea(.container, edges: .top)
    } detail: {
      detail.navigationTitle(navigationState.selectedTab.title)
        .toolbarBackground(.regularMaterial, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
          if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
              PreferencesWindowTitle(title: navigationState.selectedTab.title)
            }
            .sharedBackgroundVisibility(.hidden)
          } else {
            ToolbarItem(placement: .navigation) {
              PreferencesWindowTitle(title: navigationState.selectedTab.title)
            }
          }
        }
    }
    .navigationSplitViewStyle(.balanced)
    // Акцент только у тумблеров: popup и кнопки эталона системного вида.
    .toggleStyle(PreferencesAccentToggleStyle())
    .preferredColorScheme(themeManager.systemAppearance)
    .frame(minWidth: PreferencesWindowController.minimumContentSize.width,
           minHeight: PreferencesWindowController.minimumContentSize.height)
    .background(NonCollapsibleSplitViewModifier())
  }

  /// Lock column visibility to .all so the sidebar cannot be collapsed.
  private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: { .all },
      set: { _ in }
    )
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    PreferencesSidebarView(navigationState: navigationState)
      .modifier(SidebarToggleRemovalModifier())
      .navigationSplitViewColumnWidth(
        min: Self.fixedSidebarWidth,
        ideal: Self.fixedSidebarWidth,
        max: Self.fixedSidebarWidth
      )
      .accessibilityElement(children: .contain)
      .accessibilityLabel(L10n.PreferencesGeneral.sidebarAccessibilityLabel)
  }

  // MARK: - Detail

  private var detail: some View {
    ScrollViewReader { proxy in
      page
        .environment(\.preferencesHighlightedSetting, navigationState.highlightedSetting)
        .onChange(of: navigationState.revealRequest) { request in
          guard let request else { return }
          // Let the newly selected page lay out before scrolling into it.
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if request.scrolls {
              withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(request.title, anchor: .center)
              }
            }
            navigationState.didReveal(request)
          }
        }
    }
  }

  private var page: some View {
    Group {
      switch navigationState.selectedTab {
      case .general:
        LazyView(GeneralSettingsView())
      case .menuBar:
        LazyView(MenuBarSettingsView())
      case .capture:
        LazyView(OwnShotScreenshotSettingsView())
      case .wallpaper:
        LazyView(OwnShotWallpaperSettingsView())
      case .recording:
        LazyView(OwnShotRecordingSettingsView())
      case .annotate:
        LazyView(OwnShotAnnotateSettingsView())
      case .quickAccess:
        LazyView(QuickAccessSettingsView())
      case .history:
        LazyView(HistorySettingsView())
      case .shortcuts:
        LazyView(ShortcutsSettingsView())
      case .permissions:
        LazyView(PermissionsSettingsView())
      case .commandLine:
        LazyView(CommandLineSettingsView())
      case .cloud:
        OwnShotFeaturePlaceholder(feature: .cloud)
      case .advanced:
        LazyView(OwnShotAdvancedSettingsView())
      case .about:
        LazyView(AboutSettingsView())
      }
    }
    .id(navigationState.selectedTab)
    .transition(.opacity)
    .animation(.easeOut(duration: 0.12), value: navigationState.selectedTab)
  }
}

struct PreferencesWindowTitle: View {
  /// 0.7 от чёрного даёт #4D4D4D.
  static let textOpacity: Double = 0.7
  /// Заголовок эталона в тёмной теме: сплошной #E9E9E9 (spec-050, settings-recording-on-000000).
  static let darkTextWhite: Double = 233.0 / 255.0

  /// Яркость и непрозрачность текста заголовка: светлая тема приглушена до #4D4D4D, тёмная – почти белая.
  static func textTone(for colorScheme: ColorScheme) -> (white: Double, opacity: Double) {
    colorScheme == .dark ? (darkTextWhite, 1) : (0, textOpacity)
  }

  let title: String
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let tone = PreferencesWindowTitle.textTone(for: colorScheme)
    Text(title)
      .font(.system(size: 15, weight: .semibold))
      // Цвет заголовка зависит от темы: #4D4D4D в светлой, #E9E9E9 в тёмной, как у эталона.
      .foregroundStyle(Color(white: tone.white).opacity(tone.opacity))
      .lineLimit(1)
      // Без фиксированного размера тулбар обрезает длинные заголовки до «Quick A…».
      .fixedSize()
      .padding(.leading, 11.5)
      .opacity(controlActiveState == .inactive ? 0.35 : 1)
  }
}

// Материал повторяет реакцию системных панелей на фон и активность окна.
struct PreferencesWindowMaterial: NSViewRepresentable {
  let material: NSVisualEffectView.Material

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
    view.material = material
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.material = material
  }
}

// MARK: - Sidebar Toggle Modifier

private struct SidebarToggleRemovalModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 14.0, *) {
      content.toolbar(removing: .sidebarToggle)
    } else {
      content
    }
  }
}

// MARK: - Non-Collapsible Split View Modifier

/// Enforces non-collapsible behavior on the underlying AppKit `NSSplitViewItem`
/// for the sidebar column, preventing collapsing via shortcuts (⌘⌥S),
/// divider dragging, or divider double-clicking.
private struct NonCollapsibleSplitViewModifier: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      configure(from: view)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      configure(from: nsView)
    }
  }

  private func configure(from view: NSView) {
    guard let window = view.window else { return }
    guard let splitView = window.contentView?.firstDescendant(ofType: NSSplitView.self),
          let splitViewController = splitView.delegate as? NSSplitViewController,
          let sidebarItem = splitViewController.splitViewItems.first else {
      return
    }

    if sidebarItem.canCollapse {
      sidebarItem.canCollapse = false
    }
    if sidebarItem.isCollapsed {
      sidebarItem.isCollapsed = false
    }
  }
}

#Preview {
  PreferencesView()
}

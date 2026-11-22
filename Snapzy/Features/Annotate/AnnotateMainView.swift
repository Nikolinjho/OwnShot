//
//  AnnotateMainView.swift
//  Snapzy
//
//  Main container view for annotation window
//

import SwiftUI

/// Main container for annotation window layout
struct AnnotateMainView: View {
  @StateObject var state: AnnotateState
  let eventRouter: AnnotateWindowEventRouter
  @ObservedObject private var themeManager = ThemeManager.shared
  @Environment(\.controlActiveState) private var controlActiveState

  var body: some View {
    VStack(spacing: 0) {
      // Hide toolbar in preview mode
      if state.editorMode != .preview {
        AnnotateToolbarView(state: state)
          .padding(.top, 0) // Add top padding for traffic lights

        editorDivider(barEdge: .top)
      }

      HStack(spacing: 0) {
        // Hide sidebar in preview mode
        if state.showSidebar && state.editorMode != .preview {
          AnnotateSidebarView(state: state)
            .equatable()
            .frame(width: AnnotateSidebarMetrics.width)
            .transition(.move(edge: .leading))

          Divider()
            .background(Color.white.opacity(0.1))
        }

        AnnotateCanvasView(state: state, eventRouter: eventRouter)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle()) // Constrain hit-test area to frame bounds
          .clipped() // Prevent canvas content from overlapping toolbar/bottombar
      }
      // Окно прозрачное ради панелей, поэтому сайдбар и холст получают фон окна здесь.
      .background(Color(nsColor: .windowBackgroundColor))

      editorDivider(barEdge: .bottom)

      AnnotateBottomBarView(state: state, eventRouter: eventRouter)
    }
    .preferredColorScheme(themeManager.systemAppearance)
    .ignoresSafeArea(.all, edges: .top) // Extend background behind title bar
    .animation(.easeInOut(duration: 0.14), value: state.showsQuickPropertiesBar)
  }

  /// Разделитель панели и холста: в тёмной теме #4C4A49 и полупрозрачная половина
  /// со стороны активной панели вместо прежней #676665 (spec-066 R11).
  private func editorDivider(barEdge: AnnotateEditorDivider.BarEdge) -> some View {
    AnnotateEditorDivider(
      barEdge: barEdge,
      isActive: controlActiveState != .inactive,
      colorScheme: themeManager.systemAppearance
    )
  }
}

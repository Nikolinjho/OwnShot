//
//  SandboxFileAccessing.swift
//  Snapzy
//
//  Protocol extracted from SandboxFileAccessManager for DI.
//

import Foundation

protocol SandboxFileAccessing {
  func resolvedExportDirectoryURL() -> URL
  func beginAccessingURL(_ targetURL: URL) -> SandboxFileAccessManager.ScopedAccess
}

extension SandboxFileAccessManager: SandboxFileAccessing {}

extension SandboxFileAccessing {
  func withScopedAccess<T>(to targetURL: URL, _ operation: () throws -> T) rethrows -> T {
    let access = beginAccessingURL(targetURL)
    defer { access.stop() }
    return try operation()
  }
}

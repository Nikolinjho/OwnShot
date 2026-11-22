#!/usr/bin/env python3
"""Проверяет настоящую функцию допуска к headless capture без запуска GUI.

Изолируется только checkReadiness из исходника сервиса. Заглушки предоставляют
состояние разрешения и блокировки, а выполняются реальные проверки сервиса.
"""
from pathlib import Path
import subprocess
import tempfile

project = Path(__file__).resolve().parents[1]
s=(project / 'Snapzy/Services/Capture/HeadlessCapture/HeadlessCaptureService.swift').read_text()
a=s.index('  private func checkReadiness() async throws {');b=s.index('\n  private func invocation',a)
method=s[a:b].replace('private func','func',1)
support='''import Foundation

enum ScreenRecordingPermissionStatus { case granted, notGranted, grantedButUnavailableDueToAppIdentity(String) }
enum HeadlessCaptureError: Error { case onboardingIncomplete, screenLocked, permissionDenied, permissionUnavailable(String) }
enum OnboardingFlowView { static let hasCompletedOnboarding = false }
final class FakeCaptureManager {
  var permissionStatus: ScreenRecordingPermissionStatus = .granted
  var requiresRelaunchToActivate = false
  func checkPermission() async {}
}
final class Harness {
  static var isScreenLocked = false
  let captureManager = FakeCaptureManager()
'''
end='''
}
@main struct Run {
  static func main() async {
    let fresh = Harness()
    do {
      try await fresh.checkReadiness()
      print("PASS: fresh OwnShot with no tutorial flag and real permission is capture-ready")
    } catch { print("FAIL: fresh permitted OwnShot blocked: \\(error)"); exit(1) }
    fresh.captureManager.permissionStatus = .notGranted
    do { try await fresh.checkReadiness(); print("FAIL: denied permission allowed"); exit(1) }
    catch HeadlessCaptureError.permissionDenied { print("PASS: denied permission rejected") }
    catch { print("FAIL: wrong denied error: \\(error)"); exit(1) }
    fresh.captureManager.permissionStatus = .granted
    fresh.captureManager.requiresRelaunchToActivate = true
    do { try await fresh.checkReadiness(); print("FAIL: pending relaunch allowed"); exit(1) }
    catch HeadlessCaptureError.permissionUnavailable { print("PASS: pending relaunch rejected") }
    catch { print("FAIL: wrong unavailable error: \\(error)"); exit(1) }
    Harness.isScreenLocked = true
    do { try await fresh.checkReadiness(); print("FAIL: locked screen allowed"); exit(1) }
    catch HeadlessCaptureError.screenLocked { print("PASS: locked screen rejected") }
    catch { print("FAIL: wrong locked error: \\(error)"); exit(1) }
  }
}
'''
with tempfile.TemporaryDirectory(prefix="ownshot-readiness-") as directory:
    fixture = Path(directory) / "ReadinessCheck.swift"
    executable = Path(directory) / "check"
    fixture.write_text(support + method + end)
    subprocess.run(["swiftc", "-parse-as-library", str(fixture), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)

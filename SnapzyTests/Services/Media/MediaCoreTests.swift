//
//  MediaCoreTests.swift
//  SnapzyTests
//
//  Unit tests for OCR benchmark math and QR clipboard payload logic.
//

import CoreGraphics
import XCTest
@testable import Snapzy

final class MediaCoreTests: XCTestCase {

  func testQRPayloadClassifier_trimsAndClassifiesWebURLs() {
    let classification = QRPayloadClassifier.classify("  HTTPS://Example.COM/path?q=1  ")

    XCTAssertEqual(classification, .webURL(scheme: "https", host: "example.com"))
    XCTAssertEqual(classification.diagnosticName, "web-url-https")
  }

  func testQRPayloadClassifier_distinguishesPlainTextAndCustomSchemes() {
    XCTAssertEqual(QRPayloadClassifier.classify("hello world"), .plainText)
    XCTAssertEqual(QRPayloadClassifier.classify("mailto:hello@example.com"), .urlScheme("mailto"))
    XCTAssertEqual(QRPayloadClassifier.classify("snapzy://capture/area"), .urlScheme("snapzy"))
  }

  func testQRCodeDetectionResult_hasCopyablePayloadsOnlyWhenDetectionsExist() {
    XCTAssertFalse(QRCodeDetectionResult.empty.hasCopyablePayloads)

    let result = QRCodeDetectionResult(
      detections: [makeDetection("https://example.com")],
      unsupportedPayloadCount: 2
    )

    XCTAssertTrue(result.hasCopyablePayloads)
    XCTAssertEqual(result.unsupportedPayloadCount, 2)
  }

  func testCaptureOCROutcomeReportsProviderFailuresWithoutProviderContent() throws {
    let errors: [RemoteOCRError] = [
      .unauthorized,
      .unreachable(URLError(.timedOut)),
      .httpStatus(502, "private provider response")
    ]
    for error in errors {
      let outcome = try OCRQRPayloadComposer.captureOutcome(
        recognition: .failure(error),
        qrResult: .empty,
        qrSectionTitle: "QR Codes"
      )
      guard case .failed(let description) = outcome else {
        XCTFail("Provider errors should produce OCR failure feedback")
        continue
      }
      XCTAssertEqual(description, L10n.OCR.notificationFailedBody)
    }
  }

  func testCaptureOCROutcomeStillCopiesQRPayloadWhenProviderFails() throws {
    let qrResult = QRCodeDetectionResult(detections: [makeDetection("local fixture")], unsupportedPayloadCount: 0)
    let outcome = try OCRQRPayloadComposer.captureOutcome(
      recognition: .failure(RemoteOCRError.unauthorized),
      qrResult: qrResult,
      qrSectionTitle: "QR Codes"
    )
    guard case .copied(let text) = outcome else {
      return XCTFail("A successful QR detection should still provide its payload")
    }
    XCTAssertEqual(text, "local fixture")
  }

  func testCaptureOCROutcomeKeepsBlankAndUnsupportedQRFeedback() throws {
    let blank = try OCRQRPayloadComposer.captureOutcome(
      recognition: .failure(OCRError.noTextFound),
      qrResult: .empty,
      qrSectionTitle: "QR Codes"
    )
    guard case .noText = blank else { return XCTFail("Expected no text feedback") }

    let unsupported = try OCRQRPayloadComposer.captureOutcome(
      recognition: .failure(OCRError.noTextFound),
      qrResult: QRCodeDetectionResult(detections: [], unsupportedPayloadCount: 1),
      qrSectionTitle: "QR Codes"
    )
    guard case .qrTextOnlyUnsupported = unsupported else {
      return XCTFail("Expected unsupported QR feedback")
    }
  }

  func testCaptureOCROutcomePropagatesCancellationBeforeUsingQRPayload() async throws {
    let qrResult = QRCodeDetectionResult(detections: [makeDetection("local fixture")], unsupportedPayloadCount: 0)
    XCTAssertThrowsError(try OCRQRPayloadComposer.captureOutcome(
      recognition: .failure(CancellationError()),
      qrResult: qrResult,
      qrSectionTitle: "QR Codes"
    )) { error in
      XCTAssertTrue(error is CancellationError)
    }

    let cancelledTaskThrows = await Task { @MainActor in
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        _ = try OCRQRPayloadComposer.captureOutcome(
          recognition: .success("completed alongside cancellation"),
          qrResult: qrResult,
          qrSectionTitle: "QR Codes"
        )
        return false
      } catch {
        return error is CancellationError
      }
    }.value
    XCTAssertTrue(cancelledTaskThrows)
  }

  func testOCRQRPayloadComposer_returnsNilForEmptyInputs() {
    XCTAssertNil(OCRQRPayloadComposer.compose(
      recognizedText: " \n ",
      qrDetections: [],
      qrSectionTitle: "QR Codes"
    ))
  }

  func testOCRQRPayloadComposer_deduplicatesAndFiltersPayloadsAlreadyInText() {
    let text = "Open https://example.com for details"
    let output = OCRQRPayloadComposer.compose(
      recognizedText: text,
      qrDetections: [
        makeDetection("https://example.com"),
        makeDetection("WIFI:T:WPA;S:Office;P:secret;;"),
        makeDetection("WIFI:T:WPA;S:Office;P:secret;;"),
        makeDetection("   "),
        makeDetection("mailto:team@example.com"),
      ],
      qrSectionTitle: "QR Codes"
    )

    XCTAssertEqual(
      output,
      """
      Open https://example.com for details

      QR Codes:
      WIFI:T:WPA;S:Office;P:secret;;
      mailto:team@example.com
      """
    )
  }

  func testOCRQRPayloadComposer_returnsSingleQRPayloadWithoutSectionWhenNoOCRText() {
    let output = OCRQRPayloadComposer.compose(
      recognizedText: nil,
      qrDetections: [makeDetection("https://example.com")],
      qrSectionTitle: "QR Codes"
    )

    XCTAssertEqual(output, "https://example.com")
  }

  func testOCRBenchmarkMetrics_normalizesLineEndingsAndWhitespace() {
    XCTAssertEqual(
      OCRBenchmarkMetrics.normalized(" \r\nHello\rWorld\n "),
      "Hello\nWorld"
    )
  }

  func testOCRBenchmarkMetrics_accuracyHandlesEmptyExpectedText() {
    XCTAssertEqual(OCRBenchmarkMetrics.normalizedAccuracy(expected: "", recognized: ""), 1)
    XCTAssertEqual(OCRBenchmarkMetrics.normalizedAccuracy(expected: "", recognized: "extra"), 0)
  }

  func testOCRBenchmarkMetrics_summarizeGroupsLanguagesAndComputesRates() throws {
    let summaries = OCRBenchmarkMetrics.summarize([
      OCRBenchmarkSample(
        languageIdentifier: "vi",
        expectedText: "Xin chao",
        recognizedText: "Xin chao",
        confidence: 0.9,
        latencyMs: 20
      ),
      OCRBenchmarkSample(
        languageIdentifier: "en",
        expectedText: "Hello",
        recognizedText: "Hella",
        confidence: 0.8,
        latencyMs: 10
      ),
      OCRBenchmarkSample(
        languageIdentifier: "en",
        expectedText: "World",
        recognizedText: "",
        confidence: 0.2,
        latencyMs: 30
      ),
    ])

    XCTAssertEqual(summaries.map(\.languageIdentifier), ["en", "vi"])

    let english = try XCTUnwrap(summaries.first { $0.languageIdentifier == "en" })
    XCTAssertEqual(english.sampleCount, 2)
    XCTAssertEqual(english.exactMatchRate, 0)
    XCTAssertEqual(english.noOutputRate, 0.5)
    XCTAssertEqual(english.averageConfidence, 0.5, accuracy: 0.0001)
    XCTAssertEqual(english.averageLatencyMs, 20, accuracy: 0.0001)
    XCTAssertEqual(english.averageCharacterAccuracy, 0.4, accuracy: 0.0001)

    let vietnamese = try XCTUnwrap(summaries.first { $0.languageIdentifier == "vi" })
    XCTAssertEqual(vietnamese.exactMatchRate, 1)
    XCTAssertEqual(vietnamese.noOutputRate, 0)
    XCTAssertEqual(vietnamese.averageCharacterAccuracy, 1, accuracy: 0.0001)
  }

  private func makeDetection(_ payload: String) -> QRCodeDetection {
    QRCodeDetection(
      payload: payload,
      boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
      classification: QRPayloadClassifier.classify(payload)
    )
  }
}

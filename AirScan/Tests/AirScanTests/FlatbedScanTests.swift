import Foundation
import XCTest
@testable import AirScan

@MainActor
final class FlatbedScanTests: XCTestCase {
  private func capabilities() -> ScannerCapabilities {
    ScannerCapabilities(
      makeAndModel: "Test scanner",
      blankPageDetection: nil,
      blankPageDetectionAndRemoval: nil,
      inputs: [
        .init(
          source: .platen,
          minWidth: 32,
          maxWidth: 2550,
          minHeight: 32,
          maxHeight: 3508,
          profiles: [
            .init(
              colorModes: ["RGB24"],
              contentTypes: [],
              documentFormats: ["image/jpeg", "application/pdf"],
              resolutions: [.init(x: 150, y: 150)]
            )
          ],
          supportedIntents: []
        )
      ],
      adjustments: [:]
    )
  }

  private func settings() -> ScanSettings {
    ScanSettings(
      source: .platen,
      colorMode: .color,
      documentFormat: .jpeg,
      resolution: 150,
      width: 2480,
      height: 3508
    )
  }

  private func client(_ transport: FlatbedStub) throws -> ScanJobClient {
    let endpoint = try ScannerEndpoint(
      resourceRoot: XCTUnwrap(URL(string: "http://scanner.local/eSCL/"))
    )
    return ScanJobClient(endpoint: endpoint, transport: transport)
  }

  func testDeletesJobAfterSuccessfulDocument() async throws {
    let transport = FlatbedStub()
    let result = try await FlatbedScan.run(
      client: client(transport),
      settings: settings(),
      capabilities: capabilities()
    )

    XCTAssertEqual(result.document.data, Data([1, 2, 3]))
    XCTAssertNil(result.cleanupWarning)

    let methods = await transport.methods
    XCTAssertEqual(methods, ["POST", "GET", "DELETE"])
  }

  func testDeletesJobAfterReadFailure() async throws {
    let transport = FlatbedStub(readFailure: .timedOut)

    do {
      _ = try await FlatbedScan.run(
        client: client(transport),
        settings: settings(),
        capabilities: capabilities()
      )
      XCTFail("Expected timeout")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .timedOut)
    }

    let methods = await transport.methods
    XCTAssertEqual(methods, ["POST", "GET", "DELETE"])
  }

  func testPreservesDocumentWhenCleanupFails() async throws {
    let transport = FlatbedStub(deleteStatus: 503)

    let result = try await FlatbedScan.run(
      client: client(transport),
      settings: settings(),
      capabilities: capabilities()
    )

    XCTAssertEqual(result.document.data, Data([1, 2, 3]))
    XCTAssertNotNil(result.cleanupWarning)
  }

  func testReportsBothReadAndCleanupFailures() async throws {
    let transport = FlatbedStub(
      readFailure: .timedOut,
      deleteStatus: 503
    )

    do {
      _ = try await FlatbedScan.run(
        client: client(transport),
        settings: settings(),
        capabilities: capabilities()
      )
      XCTFail("Expected combined error")
    } catch let error as FlatbedScanError {
      guard case .scanAndCleanupFailed(let scan, let cleanup) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertFalse(scan.isEmpty)
      XCTAssertFalse(cleanup.isEmpty)
    }
  }
}

private actor FlatbedStub: ScanJobTransport {
  let readFailure: URLError.Code?
  let deleteStatus: Int
  private(set) var methods: [String] = []
  private(set) var recordedRequests: [URLRequest] = []

  init(
    readFailure: URLError.Code? = nil,
    deleteStatus: Int = 200
  ) {
    self.readFailure = readFailure
    self.deleteStatus = deleteStatus
  }

  func send(_ request: URLRequest) async throws -> ScanJobHTTPResponse {
    let method = request.httpMethod ?? ""
    methods.append(method)
    recordedRequests.append(request)

    switch method {
    case "POST":
      return .init(
        statusCode: 201,
        location: "/eSCL/ScanJobs/test-job"
      )
    case "GET":
      if let readFailure {
        throw URLError(readFailure)
      }
      return .init(
        statusCode: 200,
        body: Data([1, 2, 3]),
        contentType: "image/jpeg"
      )
    case "DELETE":
      return .init(statusCode: deleteStatus)
    default:
      throw URLError(.badServerResponse)
    }
  }
}


extension FlatbedScanTests {
  func testRequestsPDFAndCleansUp() async throws {
    let transport = FlatbedStub()
    let pdfSettings = ScanSettings(
      source: .platen,
      colorMode: .color,
      documentFormat: .pdf,
      resolution: 150,
      width: 2480,
      height: 3508
    )

    _ = try await FlatbedScan.run(
      client: client(transport),
      settings: pdfSettings,
      capabilities: capabilities()
    )

    let requests = await transport.recordedRequests
    let creation = try XCTUnwrap(requests.first)
    let body = try XCTUnwrap(creation.httpBody)
    let xml = try XCTUnwrap(String(data: body, encoding: .utf8))

    XCTAssertTrue(
      xml.contains("<pwg:DocumentFormat>application/pdf</pwg:DocumentFormat>")
    )

    let methods = await transport.methods
    XCTAssertEqual(methods, ["POST", "GET", "DELETE"])
  }
}

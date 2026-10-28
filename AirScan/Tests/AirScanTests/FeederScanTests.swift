import Foundation
import XCTest
@testable import AirScan

@MainActor
final class FeederScanTests: XCTestCase {
  private func capabilities() -> ScannerCapabilities {
    ScannerCapabilities(
      makeAndModel: "Test scanner",
      blankPageDetection: nil,
      blankPageDetectionAndRemoval: nil,
      inputs: [
        .init(
          source: .feederSimplex,
          minWidth: 32,
          maxWidth: 2551,
          minHeight: 32,
          maxHeight: 4200,
          profiles: [
            .init(
              colorModes: ["RGB24"],
              contentTypes: [],
              documentFormats: ["image/jpeg"],
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
      source: .feederSimplex,
      colorMode: .color,
      documentFormat: .jpeg,
      resolution: 150,
      width: 2551,
      height: 3508
    )
  }

  private func run(
    pages: Int,
    expected: Int,
    sink: FeederTestSink,
    transport: FeederTestTransport
  ) async throws -> FeederScanResult {
    let endpoint = try ScannerEndpoint(
      resourceRoot: XCTUnwrap(URL(string: "http://scanner.local/eSCL/"))
    )
    let client = ScanJobClient(endpoint: endpoint, transport: transport)

    return try await FeederScan.run(
      client: client,
      settings: settings(),
      capabilities: capabilities(),
      expectedPages: expected
    ) { _, index in
      await sink.append(index)
    }
  }

  func testReceivesAllPagesAndDeletesJob() async throws {
    let sink = FeederTestSink()
    let transport = FeederTestTransport(pages: 3)

    let result = try await run(
      pages: 3, expected: 3, sink: sink, transport: transport
    )

    XCTAssertEqual(result.pageCount, 3)
    XCTAssertNil(result.cleanupWarning)

    let indices = await sink.indices
    let methods = await transport.methods
    XCTAssertEqual(indices, [1, 2, 3])
    XCTAssertEqual(methods, ["POST", "GET", "GET", "GET", "GET", "DELETE"])
  }

  func testPreservesPagesWhenEndArrivesTooEarly() async throws {
    let sink = FeederTestSink()
    let transport = FeederTestTransport(pages: 2)

    do {
      _ = try await run(
        pages: 2, expected: 3, sink: sink, transport: transport
      )
      XCTFail("Expected page-count error")
    } catch let error as FeederScanError {
      XCTAssertEqual(
        error,
        .unexpectedPageCount(expected: 3, received: 2)
      )
    }

    let indices = await sink.indices
    let methods = await transport.methods
    XCTAssertEqual(indices, [1, 2])
    XCTAssertEqual(methods.last, "DELETE")
  }

  func testPreservesUnexpectedExtraPageBeforeStopping() async throws {
    let sink = FeederTestSink()
    let transport = FeederTestTransport(pages: 4)

    do {
      _ = try await run(
        pages: 4, expected: 3, sink: sink, transport: transport
      )
      XCTFail("Expected extra-page error")
    } catch let error as FeederScanError {
      XCTAssertEqual(
        error,
        .unexpectedPageCount(expected: 3, received: 4)
      )
    }

    let indices = await sink.indices
    let methods = await transport.methods
    XCTAssertEqual(indices, [1, 2, 3, 4])
    XCTAssertEqual(methods.last, "DELETE")
  }

  func testPreservesPagesAndCleansUpAfterReadFailure() async throws {
    let sink = FeederTestSink()
    let transport = FeederTestTransport(pages: 3, failAt: 2)

    do {
      _ = try await run(
        pages: 3, expected: 3, sink: sink, transport: transport
      )
      XCTFail("Expected read failure")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .timedOut)
    }

    let indices = await sink.indices
    let methods = await transport.methods
    XCTAssertEqual(indices, [1])
    XCTAssertEqual(methods.last, "DELETE")
  }
}

private actor FeederTestSink {
  private(set) var indices: [Int] = []

  func append(_ index: Int) {
    indices.append(index)
  }
}

private actor FeederTestTransport: ScanJobTransport {
  let pages: Int
  let failAt: Int?
  private var reads = 0
  private(set) var methods: [String] = []

  init(pages: Int, failAt: Int? = nil) {
    self.pages = pages
    self.failAt = failAt
  }

  func send(_ request: URLRequest) async throws -> ScanJobHTTPResponse {
    let method = request.httpMethod ?? ""
    methods.append(method)

    switch method {
    case "POST":
      return .init(
        statusCode: 201,
        location: "/eSCL/ScanJobs/feeder-test"
      )
    case "GET":
      reads += 1

      if reads == failAt {
        throw URLError(.timedOut)
      }
      if reads > pages {
        return .init(statusCode: 404)
      }
      return .init(
        statusCode: 200,
        body: Data([1, 2, 3]),
        contentType: "image/jpeg"
      )
    case "DELETE":
      return .init(statusCode: 200)
    default:
      throw URLError(.badServerResponse)
    }
  }
}

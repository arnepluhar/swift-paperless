import Foundation
import XCTest
@testable import AirScan

@MainActor
final class CapabilitiesClientTests: XCTestCase {
  private func endpoint() throws -> ScannerEndpoint {
    try ScannerEndpoint(
      resourceRoot: XCTUnwrap(
        URL(string: "http://scanner.local:8080/custom/eSCL/")
      )
    )
  }

  func testFetchesCapabilitiesAtAdvertisedPath() async throws {
    let xml = Data("""
      <s:ScannerCapabilities xmlns:s="http://schemas.hp.com/imaging/escl/2011/05/03"
        xmlns:p="http://www.pwg.org/schemas/2010/12/sm">
        <p:MakeAndModel>Mock Canon</p:MakeAndModel>
      </s:ScannerCapabilities>
      """.utf8)
    let transport = StubScannerTransport(status: 200, body: xml)
    let caps = try await CapabilitiesClient(transport: transport)
      .fetch(from: endpoint())

    XCTAssertEqual(caps.makeAndModel, "Mock Canon")
    let requests = await transport.requestedURLs
    XCTAssertEqual(requests.map(\.absoluteString), [
      "http://scanner.local:8080/custom/eSCL/ScannerCapabilities"
    ])
  }

  func testRejectsHTTPFailuresIncludingRedirects() async throws {
    for status in [204, 301, 302, 401, 403, 404, 503] {
      let transport = StubScannerTransport(
        status: status,
        body: Data("not XML".utf8)
      )
      do {
        _ = try await CapabilitiesClient(transport: transport)
          .fetch(from: endpoint())
        XCTFail("Expected HTTP error for \(status)")
      } catch let error as CapabilitiesClientError {
        XCTAssertEqual(error, .httpStatus(status))
      }
    }
  }

  func testRejectsOversizedResponseFromCustomTransport() async throws {
    let transport = StubScannerTransport(
      status: 200,
      body: Data(
        repeating: 32,
        count: CapabilitiesClient.maximumResponseBytes + 1
      )
    )
    do {
      _ = try await CapabilitiesClient(transport: transport)
        .fetch(from: endpoint())
      XCTFail("Expected size limit error")
    } catch let error as CapabilitiesClientError {
      XCTAssertEqual(error, .responseTooLarge)
    }
  }

  func testPropagatesParsingFailure() async throws {
    let transport = StubScannerTransport(
      status: 200,
      body: Data("<broken>".utf8)
    )
    do {
      _ = try await CapabilitiesClient(transport: transport)
        .fetch(from: endpoint())
      XCTFail("Expected malformed XML error")
    } catch let error as CapabilitiesParsingError {
      XCTAssertEqual(error, .malformedXML)
    }
  }

  func testPropagatesTransportFailure() async throws {
    let transport = StubScannerTransport(
      status: 200,
      body: Data(),
      failure: .timedOut
    )
    do {
      _ = try await CapabilitiesClient(transport: transport)
        .fetch(from: endpoint())
      XCTFail("Expected timeout")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .timedOut)
    }
  }

  func testCancelledTaskDoesNotSendRequest() async throws {
    let transport = StubScannerTransport(status: 200, body: Data())
    let client = CapabilitiesClient(transport: transport)
    let address = try endpoint()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await client.fetch(from: address)
    }
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      let requests = await transport.requestedURLs
      XCTAssertTrue(requests.isEmpty)
    }
  }
}

private actor StubScannerTransport: ScannerHTTPTransport {
  let status: Int
  let body: Data
  let failure: URLError.Code?
  private(set) var requestedURLs: [URL] = []

  init(status: Int, body: Data, failure: URLError.Code? = nil) {
    self.status = status
    self.body = body
    self.failure = failure
  }

  func get(_ url: URL) async throws -> ScannerHTTPResponse {
    requestedURLs.append(url)
    if let failure { throw URLError(failure) }
    return ScannerHTTPResponse(statusCode: status, body: body)
  }
}

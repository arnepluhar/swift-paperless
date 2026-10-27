import Foundation

public struct ScannerHTTPResponse: Sendable {
  public let statusCode: Int
  public let body: Data

  public init(statusCode: Int, body: Data) {
    self.statusCode = statusCode
    self.body = body
  }
}

public protocol ScannerHTTPTransport: Sendable {
  func get(_ url: URL) async throws -> ScannerHTTPResponse
}

public enum CapabilitiesClientError: Error, Equatable, Sendable {
  case nonHTTPResponse
  case httpStatus(Int)
  case responseTooLarge
}

public struct CapabilitiesClient: Sendable {
  public static let maximumResponseBytes = 2_000_000
  private let transport: any ScannerHTTPTransport

  public init(transport: any ScannerHTTPTransport = URLSessionScannerTransport()) {
    self.transport = transport
  }

  public func fetch(from endpoint: ScannerEndpoint) async throws -> ScannerCapabilities {
    try Task.checkCancellation()
    let response = try await transport.get(endpoint.capabilitiesURL)
    try Task.checkCancellation()
    guard response.statusCode == 200 else {
      throw CapabilitiesClientError.httpStatus(response.statusCode)
    }
    guard response.body.count <= Self.maximumResponseBytes else {
      throw CapabilitiesClientError.responseTooLarge
    }
    return try CapabilitiesParser.parse(response.body)
  }
}

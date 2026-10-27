import Foundation

public enum ScanJobTransportError: Error, Equatable, Sendable {
  case nonHTTPResponse
  case responseTooLarge
  case unsupportedMethod
}

public struct URLSessionScanJobTransport: ScanJobTransport {
  public init() {}

  public func send(_ original: URLRequest) async throws -> ScanJobHTTPResponse {
    try Task.checkCancellation()

    let method = original.httpMethod ?? "GET"
    guard ["GET", "POST", "DELETE"].contains(method) else {
      throw ScanJobTransportError.unsupportedMethod
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.waitsForConnectivity = false

    // Cleanup must not wait as long as a document transfer.
    configuration.timeoutIntervalForRequest = method == "GET" ? 90 : 15
    configuration.timeoutIntervalForResource = method == "GET" ? 120 : 30

    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    var request = original
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = configuration.timeoutIntervalForRequest

    let (bytes, response) = try await session.bytes(
      for: request,
      delegate: ScanJobNoRedirectDelegate()
    )

    guard let http = response as? HTTPURLResponse else {
      throw ScanJobTransportError.nonHTTPResponse
    }

    // This first implementation buffers one page, never an entire ADF job.
    let limit = method == "GET" && http.statusCode == 200
      ? 64 * 1024 * 1024
      : 64 * 1024

    if response.expectedContentLength > Int64(limit) {
      throw ScanJobTransportError.responseTooLarge
    }

    var body = Data()

    for try await byte in bytes {
      try Task.checkCancellation()
      guard body.count < limit else {
        throw ScanJobTransportError.responseTooLarge
      }
      body.append(byte)
    }

    try Task.checkCancellation()

    return ScanJobHTTPResponse(
      statusCode: http.statusCode,
      body: body,
      location: http.value(forHTTPHeaderField: "Location"),
      contentType: http.value(forHTTPHeaderField: "Content-Type")
    )
  }
}

private final class ScanJobNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

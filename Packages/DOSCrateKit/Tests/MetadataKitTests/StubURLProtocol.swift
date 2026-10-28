import AppKit
import Foundation

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct ResponseSpec: Sendable {
        var statusCode: Int
        var data: Data
        var delayNanoseconds: UInt64 = 0
    }

    typealias Handler = @Sendable (URLRequest) async throws -> ResponseSpec

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func makeSession(handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        lock.lock()
        handlers[id] = handler
        lock.unlock()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Stub-ID": id]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    private struct Box: @unchecked Sendable {
        weak var proto: StubURLProtocol?
    }

    private var taskHandle: Task<Void, Never>?

    override func startLoading() {
        let req = request
        let stubID = req.value(forHTTPHeaderField: "X-Stub-ID")
        let handler: Handler? = {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            guard let stubID else { return nil }
            return Self.handlers[stubID]
        }()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let box = Box(proto: self)
        taskHandle = Task {
            do {
                let spec = try await handler(req)
                try Task.checkCancellation()
                if spec.delayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: spec.delayNanoseconds)
                }
                try Task.checkCancellation()
                guard let proto = box.proto else { return }
                let url = req.url ?? URL(string: "https://example.com")!
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: spec.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "\(spec.data.count)"]
                )!
                proto.client?.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !spec.data.isEmpty {
                    let mid = spec.data.count / 2
                    if mid > 0 {
                        proto.client?.urlProtocol(proto, didLoad: spec.data.prefix(mid))
                        proto.client?.urlProtocol(proto, didLoad: spec.data.suffix(from: mid))
                    } else {
                        proto.client?.urlProtocol(proto, didLoad: spec.data)
                    }
                }
                proto.client?.urlProtocolDidFinishLoading(proto)
            } catch is CancellationError {
                if let proto = box.proto {
                    proto.client?.urlProtocol(proto, didFailWithError: URLError(.cancelled))
                }
            } catch {
                if let proto = box.proto {
                    proto.client?.urlProtocol(proto, didFailWithError: error)
                }
            }
        }
    }

    override func stopLoading() {
        taskHandle?.cancel()
        taskHandle = nil
    }

    static func makeOnePixelPNG() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }
}

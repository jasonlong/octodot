import Foundation
@testable import Octodot

actor StubNetworkSession: NetworkSession {
    private var results: [Result<(Data, HTTPURLResponse), Error>]
    private var requests: [URLRequest] = []

    init(results: [Result<(Data, HTTPURLResponse), Error>]) {
        self.results = results
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !results.isEmpty else {
            throw StubError.missingResponse
        }

        let result = results.removeFirst()
        switch result {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    enum StubError: Error {
        case missingResponse
    }
}

actor DelayedStubNetworkSession: NetworkSession {
    enum ResultEnvelope {
        case success(payload: Data, response: HTTPURLResponse, delayNanoseconds: UInt64)
        case failure(error: Error, delayNanoseconds: UInt64)
    }

    private var results: [ResultEnvelope]

    init(results: [ResultEnvelope]) {
        self.results = results
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard !results.isEmpty else {
            throw StubNetworkSession.StubError.missingResponse
        }

        let result = results.removeFirst()
        switch result {
        case .success(let payload, let response, let delayNanoseconds):
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            return (payload, response)
        case .failure(let error, let delayNanoseconds):
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            throw error
        }
    }
}

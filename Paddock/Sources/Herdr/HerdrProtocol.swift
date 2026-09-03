import Foundation

/// The herdr API protocol version Paddock was written against
/// (`herdr api schema --json` reports `"protocol": 19` for herdr 0.8.0).
///
/// The socket has no handshake, so the version is only learned from `ping`.
/// A mismatch is a warning, not a hard failure: the shapes Paddock reads are
/// a small, stable subset, so it keeps working and only reports the mismatch.
enum HerdrProtocol {
    static let supported = 19
}

/// Params for the methods that take none. herdr requires `params` on every
/// request and rejects a missing one with `invalid_request`, so `{}` has to be
/// on the wire; an empty `Encodable` struct encodes to exactly that.
struct EmptyParams: Encodable, Sendable {}

/// One NDJSON request line: `{"id","method","params"}`.
///
/// The id is echoed in the response. Paddock opens a fresh connection per
/// request (herdr answers exactly one request per connection), so the id is
/// only used to sanity-check the reply, never to match against a pending map.
struct HerdrRequest<Params: Encodable & Sendable>: Encodable, Sendable {
    let id: String
    let method: HerdrMethod
    let params: Params

    init(id: String = UUID().uuidString, method: HerdrMethod, params: Params) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// The request as a newline-terminated line ready for the socket.
    func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }
}

extension HerdrRequest where Params == EmptyParams {
    init(id: String = UUID().uuidString, method: HerdrMethod) {
        self.init(id: id, method: method, params: EmptyParams())
    }
}

/// The `error` body of a failed request. `code` is a string in the schema
/// (for example `invalid_request`), not a JSON-RPC integer.
struct HerdrRPCError: Error, Decodable, Hashable, Sendable {
    let code: String
    let message: String
}

/// One NDJSON response line: `{"id","result"}` or `{"id","error":{code,message}}`.
///
/// The result is kept as the raw line rather than a decoded tree: every method
/// answers with a differently shaped `result`, and the caller is the only one
/// that knows which. `decodeResult(_:)` then decodes straight from the
/// original bytes, so no value is round-tripped through an intermediate
/// representation.
///
/// herdr answers a request it could not even parse with `"id": ""` (observed
/// for malformed JSON, a missing `id` and an unknown method), so a response is
/// never rejected for carrying an id that does not match the request.
struct HerdrResponse: Sendable {
    let id: String
    let error: HerdrRPCError?

    private let line: Data

    init(line: Data) throws {
        let envelope = try JSONDecoder().decode(Envelope.self, from: line)
        id = envelope.id ?? ""
        error = envelope.error
        self.line = line
    }

    /// The typed `result` payload, or the server's error thrown as
    /// `HerdrRPCError`.
    func decodeResult<R: Decodable>(_ type: R.Type = R.self) throws -> R {
        if let error { throw error }
        return try JSONDecoder().decode(ResultEnvelope<R>.self, from: line).result
    }

    private struct Envelope: Decodable {
        let id: String?
        let error: HerdrRPCError?
    }

    private struct ResultEnvelope<R: Decodable>: Decodable {
        let result: R
    }
}

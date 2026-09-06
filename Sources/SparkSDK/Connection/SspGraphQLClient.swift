import Foundation

/// `Sendable` wrapper around an unstructured GraphQL JSON response.
///
/// `[String: Any]` is not `Sendable` because `Any` cannot be checked for thread safety
/// at compile time. The underlying value here is produced by `JSONSerialization` from
/// an immutable `Data` buffer, so it is effectively safe to share across actors —
/// hence `@unchecked Sendable`.
struct GraphQLResponse: @unchecked Sendable {
    let data: [String: Any]

    subscript(key: String) -> Any? { data[key] }
}

final class SspGraphQLClient: Sendable {
    private let session: URLSession
    private let sspURL: String
    private let getToken: @Sendable () async throws -> String
    private let invalidateToken: @Sendable () async -> Void

    init(
        session: URLSession,
        sspURL: String,
        getToken: @escaping @Sendable () async throws -> String,
        invalidateToken: @escaping @Sendable () async -> Void = {}
    ) {
        self.session = session
        self.sspURL = sspURL
        self.getToken = getToken
        self.invalidateToken = invalidateToken
    }

    func executeRaw(
        query: String,
        variables: [String: any Sendable]? = nil
    ) async throws -> [String: Any] {
        do {
            return try await execute(query: query, variables: variables)
        } catch let error as SparkError where Self.isAuthFailure(error) {
            // The SSP no longer honours the cached session (it stays "valid" by its own
            // `valid_until` for hours): drop it and retry ONCE with a fresh one, instead of
            // failing every SSP call — fee quotes, coop exits, invoices — until the process restarts.
            await invalidateToken()
            return try await execute(query: query, variables: variables)
        }
    }

    private func execute(query: String, variables: [String: any Sendable]?) async throws -> [String: Any] {
        let token = try await getToken()
        return try await executeGraphQL(
            session: session,
            url: sspURL,
            token: token,
            query: query,
            variables: variables
        ).data
    }

    /// An HTTP 401/403, or a GraphQL error that names authentication. A false positive only
    /// costs one re-authentication and one retry.
    static func isAuthFailure(_ error: SparkError) -> Bool {
        guard case .graphqlError(let message) = error else { return false }
        let m = message.lowercased()
        return ["http 401", "http 403", "unauthenticated", "unauthorized", "not authorized",
                "authentication", "invalid token", "expired token", "token expired"]
            .contains { m.contains($0) }
    }
}

func executeGraphQL(
    session: URLSession,
    url: String,
    token: String?,
    query: String,
    variables: [String: any Sendable]?
) async throws -> GraphQLResponse {
    guard let requestURL = URL(string: url) else {
        throw SparkError.graphqlError("Invalid URL: \(url)")
    }

    var request = URLRequest(url: requestURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    var body: [String: Any] = ["query": query]
    if let variables {
        body["variables"] = variables
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode) else {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        throw SparkError.graphqlError("HTTP \(statusCode)")
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SparkError.graphqlError("Invalid JSON response")
    }

    if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
        let messages = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
        throw SparkError.graphqlError(messages)
    }

    guard let resultData = json["data"] as? [String: Any] else {
        throw SparkError.graphqlError("No data in response")
    }

    return GraphQLResponse(data: resultData)
}

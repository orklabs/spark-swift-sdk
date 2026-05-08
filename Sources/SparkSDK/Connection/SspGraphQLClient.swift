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

    init(
        session: URLSession,
        sspURL: String,
        getToken: @escaping @Sendable () async throws -> String
    ) {
        self.session = session
        self.sspURL = sspURL
        self.getToken = getToken
    }

    func executeRaw(
        query: String,
        variables: [String: any Sendable]? = nil
    ) async throws -> [String: Any] {
        let token = try await getToken()
        return try await executeGraphQL(
            session: session,
            url: sspURL,
            token: token,
            query: query,
            variables: variables
        ).data
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

import Foundation

/// Manages Gemini CachedContent resources so the static policy block can be
/// stored server-side and referenced by name in the WebSocket setup message.
///
/// **Current status:** The Gemini Live API (`BidiGenerateContent`) does not yet
/// accept a `cachedContent` field in the setup message. This service is wired up
/// with a graceful fallback — when caching is unavailable the full prompt is sent
/// inline as before. Once Google ships Live API cache support, flip
/// `isCachingEnabled` to `true`.
final class GeminiCacheService {

    static let shared = GeminiCacheService()

    /// Master toggle. Set to `true` once the Live API supports `cachedContent`.
    var isCachingEnabled = false

    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/cachedContents"
    private let defaultTTLSeconds = 3600

    private var cachedResourceName: String?
    private var cacheExpiry: Date?
    private var cachedPolicyHash: Int?

    private init() {}

    // MARK: - Public API

    /// Create (or reuse) a server-side cache for the given policy text.
    /// Returns the cache resource name on success, or `nil` if caching is
    /// unavailable / disabled.
    func ensureCache(
        policyText: String,
        model: String,
        apiKey: String
    ) async -> String? {
        guard isCachingEnabled else { return nil }

        let hash = policyText.hashValue
        if let name = cachedResourceName,
           let expiry = cacheExpiry,
           expiry > Date(),
           cachedPolicyHash == hash {
            return name
        }

        do {
            let name = try await createCache(policyText: policyText, model: model, apiKey: apiKey)
            cachedResourceName = name
            cacheExpiry = Date().addingTimeInterval(TimeInterval(defaultTTLSeconds - 60))
            cachedPolicyHash = hash
            print("[GeminiCache] Created cache: \(name)")
            return name
        } catch {
            print("[GeminiCache] Cache creation failed (falling back to inline): \(error.localizedDescription)")
            return nil
        }
    }

    /// Delete the current cache if one exists (call on session end).
    func invalidate(apiKey: String) {
        guard let name = cachedResourceName else { return }
        cachedResourceName = nil
        cacheExpiry = nil
        cachedPolicyHash = nil

        Task {
            do {
                try await deleteCache(name: name, apiKey: apiKey)
                print("[GeminiCache] Deleted cache: \(name)")
            } catch {
                print("[GeminiCache] Cache deletion failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - REST Calls

    private func createCache(policyText: String, model: String, apiKey: String) async throws -> String {
        guard var components = URLComponents(string: baseURL) else {
            throw CacheError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw CacheError.invalidURL
        }

        let body: [String: Any] = [
            "model": "models/\(model)",
            "systemInstruction": [
                "parts": [["text": policyText]]
            ] as [String: Any],
            "ttl": "\(defaultTTLSeconds)s"
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw CacheError.createFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(detail)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else {
            throw CacheError.createFailed("Missing 'name' in response")
        }
        return name
    }

    private func deleteCache(name: String, apiKey: String) async throws {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/\(name)"
        guard var components = URLComponents(string: urlString) else { return }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let _ = try await URLSession.shared.data(for: request)
    }

    // MARK: - Errors

    enum CacheError: LocalizedError {
        case invalidURL
        case createFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid cache API URL"
            case .createFailed(let d): return "Cache creation failed: \(d)"
            }
        }
    }
}

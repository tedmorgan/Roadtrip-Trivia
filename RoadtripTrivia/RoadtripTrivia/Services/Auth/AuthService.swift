import Foundation
import AuthenticationServices
import SafariServices

/// Manages authentication via Supabase Auth.
/// Per PRD AUTH-01: Sign in with Apple, email magic link, email/password, Google, Facebook.
/// Per PRD CP-AUTH-01: CarPlay NEVER displays auth UI.
/// Per PRD AUTH-02: Persistent login with secure token storage.
class AuthService: NSObject, ObservableObject {

    static let shared = AuthService()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentUserID: String?

    /// Bearer token for Supabase Edge Function API calls
    private(set) var currentToken: String?

    // Supabase project config
    private let supabaseURL = "https://kakhzbcuudkrrktkobjs.supabase.co"

    /// The anon key is safe to embed in the app — Row Level Security enforces data access.
    /// Get this from: Supabase Dashboard → Settings → API → anon/public key
    private let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imtha2h6YmN1dWRrcnJrdGtvYmpzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzIzMDgzNzQsImV4cCI6MjA4Nzg4NDM3NH0.0AN73dPhhqOrRxPcOIODO58fanDKbPvJfUkqiovk4GQ"

    private let keychainService = "com.nagrom.roadtrip.auth"
    private let urlSession: URLSession

    private override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.urlSession = URLSession(configuration: config)
        super.init()

        #if DEBUG
        // For development testing: auto-authenticate without real auth
        currentUserID = "test-user-dev"
        currentToken = "test-token-dev"
        isAuthenticated = true
        print("[Auth] DEBUG mode — auto-authenticated")
        #else
        restoreSession()
        #endif
    }

    // MARK: - Sign in with Apple (AUTH-01, primary method)

    /// Exchange Apple ID credential for a Supabase session.
    /// Supabase Auth verifies the Apple identity token server-side.
    func signInWithApple(
        credential: ASAuthorizationAppleIDCredential,
        completion: @escaping (Bool) -> Void
    ) {
        guard let identityToken = credential.identityToken,
              let idTokenString = String(data: identityToken, encoding: .utf8) else {
            print("[Auth] No identity token from Apple")
            completion(false)
            return
        }

        let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=id_token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        var body: [String: Any] = [
            "provider": "apple",
            "id_token": idTokenString,
        ]

        // Include name on first sign-in (Apple only provides it once)
        if let fullName = credential.fullName {
            let name = [fullName.givenName, fullName.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            if !name.isEmpty {
                body["options"] = ["data": ["full_name": name]]
            }
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, let data,
                      let http = response as? HTTPURLResponse,
                      http.statusCode == 200 else {
                    print("[Auth] Apple sign-in failed: \(error?.localizedDescription ?? "HTTP error")")
                    completion(false)
                    return
                }
                self.handleAuthResponse(data: data, completion: completion)
            }
        }.resume()
    }

    // MARK: - Email/Password (AUTH-01)

    func signUpWithEmail(email: String, password: String, completion: @escaping (Bool, String?) -> Void) {
        let url = URL(string: "\(supabaseURL)/auth/v1/signup")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "password": password])

        print("[Auth] signUp request → \(url.absoluteString)")
        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, let data, let http = response as? HTTPURLResponse else {
                    print("[Auth] signUp network error: \(error?.localizedDescription ?? "nil")")
                    completion(false, error?.localizedDescription)
                    return
                }
                print("[Auth] signUp response: HTTP \(http.statusCode)")
                if let body = String(data: data, encoding: .utf8) {
                    print("[Auth] signUp body: \(body.prefix(500))")
                }
                if http.statusCode == 200 || http.statusCode == 201 {
                    // Supabase returns tokens only when email confirmation is disabled.
                    // When confirmation is enabled, the response has the user object but no tokens.
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       json["access_token"] != nil {
                        // Tokens present — sign in immediately
                        self.handleAuthResponse(data: data) { ok in completion(ok, ok ? nil : "Sign up failed") }
                    } else {
                        // No tokens — email confirmation required. Auto sign-in with credentials.
                        print("[Auth] signUp succeeded, no tokens — auto signing in")
                        self.signInWithEmail(email: email, password: password, completion: completion)
                    }
                } else {
                    completion(false, self.parseError(data: data) ?? "Sign up failed (HTTP \(http.statusCode))")
                }
            }
        }.resume()
    }

    func signInWithEmail(email: String, password: String, completion: @escaping (Bool, String?) -> Void) {
        let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=password")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "password": password])

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, let data, let http = response as? HTTPURLResponse else {
                    completion(false, error?.localizedDescription)
                    return
                }
                if http.statusCode == 200 {
                    self.handleAuthResponse(data: data) { ok in completion(ok, ok ? nil : "Sign in failed") }
                } else {
                    completion(false, self.parseError(data: data) ?? "Invalid email or password")
                }
            }
        }.resume()
    }

    // MARK: - Magic Link (AUTH-01)

    func sendMagicLink(email: String, completion: @escaping (Bool, String?) -> Void) {
        let url = URL(string: "\(supabaseURL)/auth/v1/magiclink")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email])

        urlSession.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                completion(ok, ok ? nil : "Failed to send magic link")
            }
        }.resume()
    }

    // MARK: - Google Sign-In (AUTH-01, OAuth via Supabase)

    /// Google Sign-In using Supabase OAuth flow.
    /// Opens an in-app browser for Google authentication, then exchanges the
    /// callback token with Supabase.
    func signInWithGoogle(presentingViewController: UIViewController, completion: @escaping (Bool, String?) -> Void) {
        let redirectURL = "\(supabaseURL)/auth/v1/callback"
        guard let url = URL(string: "\(supabaseURL)/auth/v1/authorize?provider=google&redirect_to=\(redirectURL)") else {
            completion(false, "Invalid URL")
            return
        }

        let safariVC = SFSafariViewController(url: url)
        safariVC.modalPresentationStyle = .formSheet
        presentingViewController.present(safariVC, animated: true)

        googleSignInCompletion = completion
        googleSafariVC = safariVC
    }

    private var googleSignInCompletion: ((Bool, String?) -> Void)?
    private weak var googleSafariVC: SFSafariViewController?

    /// Handle the OAuth callback URL from Google Sign-In.
    /// Call this from your SceneDelegate/AppDelegate URL handler.
    func handleGoogleCallback(url: URL) {
        googleSafariVC?.dismiss(animated: true)

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = components.fragment else {
            googleSignInCompletion?(false, "Invalid callback URL")
            googleSignInCompletion = nil
            return
        }

        let params = fragment.split(separator: "&").reduce(into: [String: String]()) { result, pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                result[String(parts[0])] = String(parts[1])
            }
        }

        guard let accessToken = params["access_token"],
              let refreshToken = params["refresh_token"] else {
            googleSignInCompletion?(false, "Missing tokens in callback")
            googleSignInCompletion = nil
            return
        }

        saveToKeychain(key: "accessToken", value: accessToken)
        saveToKeychain(key: "refreshToken", value: refreshToken)

        currentToken = accessToken
        currentUserID = decodeUserIdFromJWT(accessToken)
        if let userId = currentUserID {
            saveToKeychain(key: "userId", value: userId)
        }
        isAuthenticated = true
        print("[Auth] Google sign-in successful — user: \(currentUserID ?? "unknown")")
        googleSignInCompletion?(true, nil)
        googleSignInCompletion = nil
    }

    // MARK: - Silent Token Refresh (AUTH-02, UC-32)

    /// Refresh session using stored refresh token.
    /// Per PRD: user should never see a re-login prompt.
    func silentReauthenticate(completion: @escaping (Bool) -> Void) {
        guard let refreshToken = loadFromKeychain(key: "refreshToken") else {
            // Try legacy Apple ID check as fallback
            legacyAppleReauth(completion: completion)
            return
        }

        let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=refresh_token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, let data,
                      let http = response as? HTTPURLResponse,
                      http.statusCode == 200 else {
                    print("[Auth] Token refresh failed — user needs to sign in again")
                    completion(false)
                    return
                }
                self.handleAuthResponse(data: data, completion: completion)
            }
        }.resume()
    }

    // MARK: - Sign Out (UC-33)

    func signOut() {
        // Revoke token server-side (fire and forget)
        if let token = currentToken {
            let url = URL(string: "\(supabaseURL)/auth/v1/logout")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
            urlSession.dataTask(with: request).resume()
        }
        clearLocalAuth()
    }

    // MARK: - Account Deletion (AUTH-05, UC-35)

    /// Per App Store guidelines and PRD: remove all server-side data.
    func deleteAccount(completion: @escaping (Bool) -> Void) {
        guard let token = currentToken, let userId = currentUserID else {
            completion(false)
            return
        }

        // Call server-side function to delete all user data
        let url = URL(string: "\(supabaseURL)/rest/v1/rpc/delete_user_data")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["p_user_id": userId])

        urlSession.dataTask(with: request) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                self?.clearLocalAuth()
                SessionPersistenceService.shared.clearAllData()
                completion(true)
            }
        }.resume()
    }

    // MARK: - CarPlay Auth Guard (CP-AUTH-01)

    var canPlayOnCarPlay: Bool { isAuthenticated }

    // MARK: - Private Helpers

    private func restoreSession() {
        silentReauthenticate { success in
            print("[Auth] Session restore: \(success ? "success" : "no session")")
        }
    }

    private func handleAuthResponse(data: Data, completion: @escaping (Bool) -> Void) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            print("[Auth] Invalid auth response")
            completion(false)
            return
        }

        let userId: String? = {
            if let user = json["user"] as? [String: Any] { return user["id"] as? String }
            return decodeUserIdFromJWT(accessToken)
        }()

        // Persist tokens in Keychain (AUTH-02)
        saveToKeychain(key: "accessToken", value: accessToken)
        saveToKeychain(key: "refreshToken", value: refreshToken)
        if let userId { saveToKeychain(key: "userId", value: userId) }

        currentToken = accessToken
        currentUserID = userId
        isAuthenticated = true
        print("[Auth] Authenticated — user: \(userId ?? "unknown")")
        completion(true)
    }

    private func clearLocalAuth() {
        for key in ["accessToken", "refreshToken", "userId", "appleIDToken", "appleUserID"] {
            deleteFromKeychain(key: key)
        }
        currentToken = nil
        currentUserID = nil
        isAuthenticated = false
    }

    /// Legacy fallback for users who signed in before Supabase migration
    private func legacyAppleReauth(completion: @escaping (Bool) -> Void) {
        guard let appleUserID = loadFromKeychain(key: "appleUserID") else {
            completion(false)
            return
        }
        let provider = ASAuthorizationAppleIDProvider()
        provider.getCredentialState(forUserID: appleUserID) { [weak self] state, _ in
            DispatchQueue.main.async {
                if state == .authorized {
                    self?.currentUserID = appleUserID
                    self?.currentToken = self?.loadFromKeychain(key: "appleIDToken")
                    self?.isAuthenticated = true
                    completion(true)
                } else {
                    completion(false)
                }
            }
        }
    }

    private func decodeUserIdFromJWT(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["sub"] as? String
    }

    private func parseError(data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["error_description"] as? String ?? json["msg"] as? String ?? json["message"] as? String
    }

    // MARK: - Keychain

    private func saveToKeychain(key: String, value: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

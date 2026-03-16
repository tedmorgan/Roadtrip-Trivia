import Foundation
import AuthenticationServices
import SafariServices
import CommonCrypto

/// Manages authentication via Supabase Auth.
/// Per PRD AUTH-01: Sign in with Apple, email magic link, email/password, Google, Facebook.
/// Per PRD CP-AUTH-01: CarPlay NEVER displays auth UI.
/// Per PRD AUTH-02: Persistent login with secure token storage.
class AuthService: NSObject, ObservableObject {

    static let shared = AuthService()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentUserID: String?
    @Published private(set) var currentEmail: String?

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

    /// Raw nonce stored between Apple sign-in request and callback.
    private var currentAppleNonce: String?

    /// Generate a cryptographically-secure random nonce for Apple Sign-In.
    private func generateNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let charset = "0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._"
        return bytes.map { charset[charset.index(charset.startIndex, offsetBy: Int($0) % charset.count)] }
            .map { String($0) }.joined()
    }

    /// SHA256 hash of the nonce — Apple embeds this in the id_token.
    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Prepare an Apple Sign-In request with a nonce for Supabase verification.
    func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = generateNonce()
        currentAppleNonce = nonce
        request.nonce = sha256(nonce)
    }

    /// Exchange Apple ID credential for a Supabase session.
    /// Exchange Apple ID credential for a Supabase session.
    /// Tries the Supabase id_token exchange first; if Apple is not configured
    /// as a Supabase provider, falls back to accepting the Apple credential
    /// directly so the user can still play.
    func signInWithApple(
        credential: ASAuthorizationAppleIDCredential,
        completion: @escaping (Bool) -> Void
    ) {
        guard let identityToken = credential.identityToken,
              let idTokenString = String(data: identityToken, encoding: .utf8) else {
            print("[Auth] No identity token from Apple — using local credential fallback")
            acceptAppleCredentialLocally(credential: credential, completion: completion)
            return
        }

        let nonce = currentAppleNonce
        currentAppleNonce = nil

        let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=id_token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        var body: [String: Any] = [
            "provider": "apple",
            "id_token": idTokenString,
        ]
        if let nonce { body["nonce"] = nonce }

        if let fullName = credential.fullName {
            let name = [fullName.givenName, fullName.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            if !name.isEmpty {
                body["options"] = ["data": ["full_name": name]]
            }
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        print("[Auth] Apple sign-in: sending id_token to Supabase (nonce: \(nonce != nil ? "yes" : "no"))")
        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { completion(false); return }
                if let data,
                   let http = response as? HTTPURLResponse,
                   http.statusCode == 200 {
                    print("[Auth] Apple sign-in: Supabase accepted id_token")
                    self.handleAuthResponse(data: data, completion: completion)
                } else {
                    let respBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    print("[Auth] Supabase Apple id_token failed — \(respBody.prefix(300))")
                    print("[Auth] Falling back to local Apple credential")
                    self.acceptAppleCredentialLocally(credential: credential, completion: completion)
                }
            }
        }.resume()
    }

    /// Accept the Apple credential directly without Supabase.
    /// Stores the Apple user ID and token so `legacyAppleReauth` can
    /// restore the session on next launch.
    private func acceptAppleCredentialLocally(
        credential: ASAuthorizationAppleIDCredential,
        completion: @escaping (Bool) -> Void
    ) {
        let userId = credential.user

        var email: String? = credential.email
        if email == nil, let token = credential.identityToken,
           let tokenStr = String(data: token, encoding: .utf8) {
            email = decodeEmailFromJWT(tokenStr)
        }

        saveToKeychain(key: "appleUserID", value: userId)
        if let token = credential.identityToken,
           let tokenStr = String(data: token, encoding: .utf8) {
            saveToKeychain(key: "appleIDToken", value: tokenStr)
        }
        if let email {
            saveToKeychain(key: "userEmail", value: email)
        }

        currentUserID = userId
        currentToken = credential.identityToken.flatMap { String(data: $0, encoding: .utf8) }
        currentEmail = email
        isAuthenticated = true

        print("[Auth] Apple sign-in succeeded (local) — user: \(userId), email: \(email ?? "hidden")")
        completion(true)
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

    // MARK: - Password Reset

    func sendPasswordReset(email: String, completion: @escaping (Bool, String?) -> Void) {
        let url = URL(string: "\(supabaseURL)/auth/v1/recover")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email])

        urlSession.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                completion(ok, ok ? nil : "Failed to send password reset email")
            }
        }.resume()
    }

    // MARK: - User Profile

    func fetchUserProfile(completion: @escaping (String?) -> Void) {
        guard let token = currentToken else {
            completion(nil)
            return
        }
        let url = URL(string: "\(supabaseURL)/auth/v1/user")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let data,
                      let http = response as? HTTPURLResponse,
                      http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let email = json["email"] as? String else {
                    completion(nil)
                    return
                }
                self?.currentEmail = email
                self?.saveToKeychain(key: "userEmail", value: email)
                completion(email)
            }
        }.resume()
    }

    // MARK: - Google Sign-In (AUTH-01, OAuth via Supabase)

    /// Google Sign-In using Supabase OAuth flow.
    /// Opens an in-app browser for Google authentication, then exchanges the
    /// callback token with Supabase.
    func signInWithGoogle(presentingViewController: UIViewController, completion: @escaping (Bool, String?) -> Void) {
        let redirectURL = "roadtriptrivia://auth/callback"
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
        currentEmail = decodeEmailFromJWT(accessToken)
        if let userId = currentUserID {
            saveToKeychain(key: "userId", value: userId)
        }
        if let email = currentEmail {
            saveToKeychain(key: "userEmail", value: email)
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

        let userEmail: String? = {
            if let user = json["user"] as? [String: Any] { return user["email"] as? String }
            return decodeEmailFromJWT(accessToken)
        }()

        // Persist tokens in Keychain (AUTH-02)
        saveToKeychain(key: "accessToken", value: accessToken)
        saveToKeychain(key: "refreshToken", value: refreshToken)
        if let userId { saveToKeychain(key: "userId", value: userId) }
        if let userEmail { saveToKeychain(key: "userEmail", value: userEmail) }

        currentToken = accessToken
        currentUserID = userId
        currentEmail = userEmail
        isAuthenticated = true
        print("[Auth] Authenticated — user: \(userId ?? "unknown")")
        completion(true)
    }

    private func clearLocalAuth() {
        for key in ["accessToken", "refreshToken", "userId", "userEmail", "appleIDToken", "appleUserID"] {
            deleteFromKeychain(key: key)
        }
        currentToken = nil
        currentUserID = nil
        currentEmail = nil
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
                    self?.currentEmail = self?.loadFromKeychain(key: "userEmail")
                    self?.isAuthenticated = true
                    completion(true)
                } else {
                    completion(false)
                }
            }
        }
    }

    private func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func decodeUserIdFromJWT(_ token: String) -> String? {
        decodeJWTPayload(token)?["sub"] as? String
    }

    private func decodeEmailFromJWT(_ token: String) -> String? {
        decodeJWTPayload(token)?["email"] as? String
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

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
    @Published private(set) var currentUsername: String?

    /// Bearer token for Supabase Edge Function API calls
    private(set) var currentToken: String?

    private var refreshInFlight: Task<String?, Never>?

    // Supabase project config
    private let supabaseURL = "https://kakhzbcuudkrrktkobjs.supabase.co"

    /// The anon key is safe to embed in the app — Row Level Security enforces data access.
    /// Get this from: Supabase Dashboard → Settings → API → anon/public key
    private let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imtha2h6YmN1dWRrcnJrdGtvYmpzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzIzMDgzNzQsImV4cCI6MjA4Nzg4NDM3NH0.0AN73dPhhqOrRxPcOIODO58fanDKbPvJfUkqiovk4GQ"

    // Expose read-only access for other services
    var supabaseApiBaseURL: URL { URL(string: supabaseURL)! }
    var supabaseApiKey: String { supabaseAnonKey }

    private let keychainService = "com.nagrom.roadtrip.auth"
    private let urlSession: URLSession

    private override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.urlSession = URLSession(configuration: config)
        super.init()

        // Debug device builds must use a real Supabase session too. The old
        // `test-token-dev` bypass cannot authenticate secure Edge Functions
        // and made CarPlay appear to hang before Gemini produced any audio.
        restoreSession()
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
                    print("[Auth] Supabase Apple id_token failed")
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

        print("[Auth] Apple sign-in succeeded (local)")
        completion(true)
    }

    // MARK: - Email/Password (AUTH-01)

    func signUpWithEmail(
        email: String,
        password: String,
        username: String? = nil,
        completion: @escaping (Bool, String?) -> Void
    ) {
        let validation = AuthAccountPolicy.validateCreateAccount(
            .init(username: username ?? "", email: email, password: password)
        )
        guard validation.isValid else {
            completion(false, validation.message)
            return
        }

        let url = URL(string: "\(supabaseURL)/auth/v1/signup")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        var payload: [String: Any] = ["email": email, "password": password]
        if let username {
            payload["data"] = ["username": username]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

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
                    print("[Auth] signUp failed — see status code above")
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

    func signInWithIdentifier(identifier: String, password: String, completion: @escaping (Bool, String?) -> Void) {
        let validation = AuthAccountPolicy.validateSignIn(.init(identifier: identifier, password: password))
        guard validation.isValid else {
            completion(false, validation.message)
            return
        }
        if AuthAccountPolicy.classifyIdentifier(identifier) == .email {
            signInWithEmail(email: identifier, password: password, completion: completion)
            return
        }
        invokeAccountRecovery(
            action: "sign_in",
            fields: ["identifier": identifier, "password": password]
        ) { [weak self] ok, data, message in
            guard let self, ok, let data else {
                completion(false, message ?? "Invalid email or password")
                return
            }
            self.handleAuthResponse(data: data) { success in
                completion(success, success ? nil : "Sign in failed")
            }
        }
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
        let validation = AuthAccountPolicy.validateMagicLink(email: email)
        guard validation.isValid else {
            completion(false, validation.message)
            return
        }
        invokeAccountRecovery(action: "magic_link", fields: ["email": email]) { ok, _, message in
            completion(
                ok,
                ok
                    ? AuthAccountPolicy.recoveryAcknowledgement(for: .magicLink)
                    : (message ?? "Failed to send sign-in link")
            )
        }
    }

    // MARK: - Password Reset / Username Recovery

    func sendPasswordReset(email: String, completion: @escaping (Bool, String?) -> Void) {
        requestPasswordReset(identifier: email, completion: completion)
    }

    func requestPasswordReset(identifier: String, completion: @escaping (Bool, String?) -> Void) {
        let validation = AuthAccountPolicy.validateForgotPassword(identifier: identifier)
        guard validation.isValid else {
            completion(false, validation.message)
            return
        }
        invokeAccountRecovery(action: "forgot_password", fields: ["identifier": identifier]) { ok, _, message in
            completion(
                ok,
                ok
                    ? AuthAccountPolicy.recoveryAcknowledgement(for: .forgotPassword)
                    : (message ?? "Failed to send password reset")
            )
        }
    }

    func requestUsernameReminder(email: String, completion: @escaping (Bool, String?) -> Void) {
        let validation = AuthAccountPolicy.validateForgotUsername(email: email)
        guard validation.isValid else {
            completion(false, validation.message)
            return
        }
        invokeAccountRecovery(action: "forgot_username", fields: ["email": email]) { ok, _, message in
            completion(
                ok,
                ok
                    ? AuthAccountPolicy.recoveryAcknowledgement(for: .forgotUsername)
                    : (message ?? "Failed to send username reminder")
            )
        }
    }

    func setUsername(_ username: String, completion: @escaping (Bool, String?) -> Void) {
        let validation = AuthAccountPolicy.validateUsername(username)
        guard validation.isValid else {
            completion(false, validation.message)
            return
        }
        guard let token = currentToken, let userId = currentUserID,
              let normalized = AuthAccountPolicy.normalizedUsername(username) else {
            completion(false, "Sign in to set a username")
            return
        }
        let url = URL(string: "\(supabaseURL)/rest/v1/profiles?id=eq.\(userId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "username": username,
            "username_normalized": normalized,
        ])
        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let msg = data.flatMap { self?.parseError(data: $0) }
                        ?? "That username is taken"
                    completion(false, msg)
                    return
                }
                self?.currentUsername = username
                self?.saveToKeychain(key: "username", value: username)
                completion(true, nil)
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
        fetchProfileAndEntitlements()
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

    static let passwordRecoveryNotification = Notification.Name("RoadtripTriviaPasswordRecovery")

    /// Handle an auth callback from Google, a magic link, or a password reset.
    /// Call this from your SceneDelegate/AppDelegate URL handler.
    func handleGoogleCallback(url: URL) {
        googleSafariVC?.dismiss(animated: true)

        guard url.scheme == "roadtriptrivia" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            googleSignInCompletion?(false, "Invalid callback URL")
            googleSignInCompletion = nil
            return
        }

        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { params[item.name] = value.removingPercentEncoding ?? value }
        }
        let fragment = components.fragment ?? ""
        for pair in fragment.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0])
                let raw = String(parts[1])
                params[key] = raw.removingPercentEncoding ?? raw
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
        print("[Auth] Auth callback successful — type: \(params["type"] ?? "oauth")")
        fetchProfileAndEntitlements()
        googleSignInCompletion?(true, nil)
        googleSignInCompletion = nil
        if params["type"] == "recovery" {
            NotificationCenter.default.post(name: Self.passwordRecoveryNotification, object: nil)
        }
    }

    func updatePassword(_ password: String, completion: @escaping (Bool, String?) -> Void) {
        let validation = AuthAccountPolicy.validatePassword(password)
        guard validation.isValid else {
            completion(false, validation.message)
            return
        }
        guard let token = currentToken else {
            completion(false, "Open the reset link again, then choose a password")
            return
        }
        let url = URL(string: "\(supabaseURL)/auth/v1/user")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["password": password])
        urlSession.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let message = data.flatMap { self?.parseError(data: $0) } ?? "Could not update the password"
                    completion(false, message)
                    return
                }
                completion(true, nil)
            }
        }.resume()
    }

    // MARK: - Silent Token Refresh (AUTH-02, UC-32)

    /// Access token for an Edge Function call. Refreshes when the stored
    /// token is missing or within a minute of expiry, so a session left
    /// open overnight is not sent to Auth as an expired JWT.
    func accessTokenForRequests() async -> String? {
        if let token = currentToken, !Self.jwtExpires(within: 60, token: token) {
            return token
        }
        if let refreshInFlight {
            return await refreshInFlight.value
        }
        let task = Task { () -> String? in
            await withCheckedContinuation { continuation in
                self.silentReauthenticate { success in
                    continuation.resume(returning: success ? self.currentToken : nil)
                }
            }
        }
        refreshInFlight = task
        let token = await task.value
        refreshInFlight = nil
        return token
    }

    private static func jwtExpires(within seconds: TimeInterval, token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return true }
        var b64 = String(parts[1])
        while b64.count % 4 != 0 { b64.append("=") }
        b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
        let exp: TimeInterval
        if let value = json["exp"] as? TimeInterval {
            exp = value
        } else if let value = json["exp"] as? Int {
            exp = TimeInterval(value)
        } else if let value = json["exp"] as? NSNumber {
            exp = value.doubleValue
        } else {
            return true
        }
        return Date().timeIntervalSince1970 > exp - seconds
    }

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
        RoundTracker.shared.clearAccountCompensation()
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

        // Local data is cleared only once the server confirms. Reporting
        // success on a failed call would leave the account live on the
        // server while the phone looks signed out, which is the opposite
        // of what Delete Account promises.
        urlSession.dataTask(with: request) { [weak self] _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let deleted = error == nil && (200...299).contains(code)
            DispatchQueue.main.async {
                guard deleted else {
                    print("[Auth] \(ISO8601DateFormatter().string(from: Date())) account deletion failed \(code)")
                    completion(false)
                    return
                }
                self?.clearLocalAuth()
                RoundTracker.shared.clearAccountCompensation()
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

        let username: String? = {
            if let user = json["user"] as? [String: Any],
               let meta = user["user_metadata"] as? [String: Any] {
                return meta["username"] as? String
            }
            return loadFromKeychain(key: "username")
        }()

        // Persist tokens in Keychain (AUTH-02)
        saveToKeychain(key: "accessToken", value: accessToken)
        saveToKeychain(key: "refreshToken", value: refreshToken)
        if let userId { saveToKeychain(key: "userId", value: userId) }
        if let userEmail { saveToKeychain(key: "userEmail", value: userEmail) }
        if let username { saveToKeychain(key: "username", value: username) }

        currentToken = accessToken
        currentUserID = userId
        currentEmail = userEmail
        currentUsername = username
        isAuthenticated = true
        print("[Auth] Authenticated")
        fetchProfileAndEntitlements()
        completion(true)
    }

    private func invokeAccountRecovery(
        action: String,
        fields: [String: String],
        completion: @escaping (Bool, Data?, String?) -> Void
    ) {
        let url = URL(string: "\(supabaseURL)/functions/v1/account-recovery")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        var payload: [String: String] = ["action": action]
        fields.forEach { payload[$0.key] = $0.value }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        urlSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard let data, let http = response as? HTTPURLResponse else {
                    completion(false, nil, error?.localizedDescription ?? "Network error")
                    return
                }
                if (200...299).contains(http.statusCode) {
                    completion(true, data, nil)
                    return
                }
                completion(false, data, self.parseError(data: data) ?? "Request failed")
            }
        }.resume()
    }

    private func fetchProfileAndEntitlements() {
        guard let token = currentToken, let userId = currentUserID else { return }

        var profileRequest = URLRequest(url: URL(string: "\(supabaseURL)/rest/v1/profiles?id=eq.\(userId)&select=username,email,display_name")!)
        profileRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        profileRequest.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        urlSession.dataTask(with: profileRequest) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self,
                      let data,
                      let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      let row = rows.first else { return }
                if let username = row["username"] as? String, !username.isEmpty {
                    self.currentUsername = username
                    self.saveToKeychain(key: "username", value: username)
                }
                if let email = row["email"] as? String, !email.isEmpty {
                    self.currentEmail = email
                    self.saveToKeychain(key: "userEmail", value: email)
                }
            }
        }.resume()

        var subRequest = URLRequest(url: URL(string: "\(supabaseURL)/rest/v1/subscriptions?user_id=eq.\(userId)&select=support_rounds_granted,support_rounds_clawed_back")!)
        subRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        subRequest.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        urlSession.dataTask(with: subRequest) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let data,
                   let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let row = rows.first {
                    let granted = Self.jsonInt(row["support_rounds_granted"])
                    let clawed = Self.jsonInt(row["support_rounds_clawed_back"])
                    RoundTracker.shared.syncCompensationRounds(
                        userId: userId,
                        granted: granted,
                        clawedBack: clawed
                    )
                } else {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    print("[Auth] \(ISO8601DateFormatter().string(from: Date())) subscription read \(code)")
                }
                self?.syncRoundLedger()
            }
        }.resume()
    }

    /// Write the phone's playable balance to Supabase so support sees the same number.
    func syncRoundLedger() {
        guard let token = currentToken, let userId = currentUserID else { return }
        let tracker = RoundTracker.shared
        let store = StoreService.shared
        let payload: [String: Any] = [
            "purchased_rounds": tracker.purchasedRoundsRemaining,
            "free_round_used": !tracker.hasFreeRound,
            "subscription_rounds_used": tracker.subscriptionRoundsUsed,
            "status": store.isSubscribed ? "active" : "none",
            "product_id": store.activeSubscription ?? NSNull(),
        ]
        let url = URL(string: "\(supabaseURL)/rest/v1/subscriptions?user_id=eq.\(userId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        urlSession.dataTask(with: request) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200...299).contains(code) {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                print("[Auth] \(ISO8601DateFormatter().string(from: Date())) round ledger sync failed \(code)")
            }
        }.resume()
    }

    private func clearLocalAuth() {
        for key in ["accessToken", "refreshToken", "userId", "userEmail", "appleIDToken", "appleUserID", "username"] {
            deleteFromKeychain(key: key)
        }
        currentToken = nil
        currentUserID = nil
        currentEmail = nil
        currentUsername = nil
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
                    self?.currentUsername = self?.loadFromKeychain(key: "username")
                    self?.isAuthenticated = true
                    completion(true)
                } else {
                    completion(false)
                }
            }
        }
    }

    private static func jsonInt(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return 0
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
        return json["error_description"] as? String
            ?? json["msg"] as? String
            ?? json["message"] as? String
            ?? json["error"] as? String
    }

    // MARK: - Keychain

    private func saveToKeychain(key: String, value: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            // Tokens stay on this device and are unreadable while locked,
            // so an unlocked-backup restore cannot carry a session over.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
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

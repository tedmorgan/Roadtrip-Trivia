import Foundation

/// Account, login, recovery, and customer-support rules used by the iPhone
/// account sheet and the Supabase admin console.
///
/// Kept here (not in `AuthService`) so `swift test` can lock every login
/// option without Keychain, StoreKit, or the network.
public enum AuthAccountPolicy {

    public static let minimumPasswordLength = 6
    public static let minimumUsernameLength = 3
    public static let maximumUsernameLength = 20

    public static let reservedUsernames: Set<String> = [
        "admin", "administrator", "support", "help", "root", "system",
        "roadtrip", "trivia", "official", "staff", "cs", "customer",
        "username", "password", "null", "undefined",
    ]

    /// Every way a player can authenticate. Tests assert this list so a
    /// removed provider cannot silently disappear from the account sheet.
    public enum LoginMethod: String, CaseIterable, Equatable {
        case apple
        case google
        case emailPassword
        case usernamePassword
        case magicLink
    }

    public enum IdentifierKind: Equatable {
        case email
        case username
    }

    public enum RecoveryKind: String, Equatable {
        case forgotPassword
        case forgotUsername
        case magicLink
    }

    public enum SupportAction: String, CaseIterable, Equatable {
        case lookup
        case sendPasswordReset
        case sendUsernameReminder
        case creditRounds
        case recordRefund
    }

    public struct ValidationResult: Equatable {
        public let isValid: Bool
        public let message: String?

        public static let ok = ValidationResult(isValid: true, message: nil)

        public static func rejected(_ message: String) -> ValidationResult {
            ValidationResult(isValid: false, message: message)
        }
    }

    public struct CreateAccountInput: Equatable {
        public var username: String
        public var email: String
        public var password: String

        public init(username: String, email: String, password: String) {
            self.username = username
            self.email = email
            self.password = password
        }
    }

    public struct SignInInput: Equatable {
        public var identifier: String
        public var password: String

        public init(identifier: String, password: String) {
            self.identifier = identifier
            self.password = password
        }
    }

    public struct SupportActionInput: Equatable {
        public var action: SupportAction
        public var query: String
        public var rounds: Int
        public var note: String
        public var appleTransactionID: String

        public init(
            action: SupportAction,
            query: String,
            rounds: Int = 0,
            note: String = "",
            appleTransactionID: String = ""
        ) {
            self.action = action
            self.query = query
            self.rounds = rounds
            self.note = note
            self.appleTransactionID = appleTransactionID
        }
    }

    // MARK: - Login catalog

    public static let supportedLoginMethods: [LoginMethod] = LoginMethod.allCases

    public static func isSupported(_ method: LoginMethod) -> Bool {
        supportedLoginMethods.contains(method)
    }

    // MARK: - Identifiers

    public static func trimmed(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func classifyIdentifier(_ raw: String) -> IdentifierKind? {
        let value = trimmed(raw)
        guard !value.isEmpty else { return nil }
        return value.contains("@") ? .email : .username
    }

    public static func normalizedEmail(_ raw: String) -> String? {
        let value = trimmed(raw).lowercased()
        guard value.contains("@"),
              let at = value.firstIndex(of: "@"),
              at > value.startIndex,
              value[value.index(after: at)...].contains(".") else {
            return nil
        }
        return value
    }

    public static func normalizedUsername(_ raw: String) -> String? {
        let value = trimmed(raw).lowercased()
        guard (minimumUsernameLength...maximumUsernameLength).contains(value.count) else {
            return nil
        }
        guard value.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil else {
            return nil
        }
        guard !reservedUsernames.contains(value) else { return nil }
        return value
    }

    public static func validateUsername(_ raw: String) -> ValidationResult {
        let value = trimmed(raw)
        if value.isEmpty {
            return .rejected("Choose a username")
        }
        if value.count < minimumUsernameLength {
            return .rejected("Username must be at least \(minimumUsernameLength) characters")
        }
        if value.count > maximumUsernameLength {
            return .rejected("Username must be \(maximumUsernameLength) characters or fewer")
        }
        if value.range(of: "^[A-Za-z][A-Za-z0-9_]*$", options: .regularExpression) == nil {
            return .rejected("Username must start with a letter and use only letters, numbers, or underscores")
        }
        if reservedUsernames.contains(value.lowercased()) {
            return .rejected("That username is reserved")
        }
        return .ok
    }

    public static func validateEmail(_ raw: String) -> ValidationResult {
        if normalizedEmail(raw) == nil {
            return .rejected("Enter a valid email address")
        }
        return .ok
    }

    public static func validatePassword(_ raw: String) -> ValidationResult {
        if raw.count < minimumPasswordLength {
            return .rejected("Password must be at least \(minimumPasswordLength) characters")
        }
        return .ok
    }

    // MARK: - Create account / sign in

    public static func validateCreateAccount(_ input: CreateAccountInput) -> ValidationResult {
        let username = validateUsername(input.username)
        if !username.isValid { return username }
        let email = validateEmail(input.email)
        if !email.isValid { return email }
        return validatePassword(input.password)
    }

    public static func validateSignIn(_ input: SignInInput) -> ValidationResult {
        let identifier = trimmed(input.identifier)
        if identifier.isEmpty {
            return .rejected("Enter your email or username")
        }
        if input.password.isEmpty {
            return .rejected("Enter your password")
        }
        switch classifyIdentifier(identifier) {
        case .email:
            return validateEmail(identifier)
        case .username:
            return validateUsername(identifier)
        case nil:
            return .rejected("Enter your email or username")
        }
    }

    public static func loginMethod(forSignIn input: SignInInput) -> LoginMethod? {
        guard validateSignIn(input).isValid else { return nil }
        switch classifyIdentifier(input.identifier) {
        case .email: return .emailPassword
        case .username: return .usernamePassword
        case nil: return nil
        }
    }

    // MARK: - Recovery

    /// Same copy whether or not the account exists, so the UI cannot be used
    /// to probe emails or usernames.
    public static func recoveryAcknowledgement(for kind: RecoveryKind) -> String {
        switch kind {
        case .forgotPassword:
            return "If an account exists for that email or username, we sent a password reset link."
        case .forgotUsername:
            return "If an account exists for that email, we sent a username reminder and a sign-in link."
        case .magicLink:
            return "If an account exists for that email, we sent a sign-in link."
        }
    }

    public static func validateForgotPassword(identifier: String) -> ValidationResult {
        let value = trimmed(identifier)
        if value.isEmpty {
            return .rejected("Enter the email or username on the account")
        }
        switch classifyIdentifier(value) {
        case .email:
            return validateEmail(value)
        case .username:
            return validateUsername(value)
        case nil:
            return .rejected("Enter the email or username on the account")
        }
    }

    public static func validateForgotUsername(email: String) -> ValidationResult {
        validateEmail(email)
    }

    public static func validateMagicLink(email: String) -> ValidationResult {
        validateEmail(email)
    }

    // MARK: - Customer support (admin console)

    public static let maximumSupportCreditPerAction = 50

    public static func validateSupportAction(_ input: SupportActionInput) -> ValidationResult {
        let query = trimmed(input.query)
        if query.isEmpty {
            return .rejected("Search by email, username, or account ID")
        }
        switch input.action {
        case .lookup, .sendPasswordReset, .sendUsernameReminder:
            return .ok
        case .creditRounds:
            if input.rounds < 1 || input.rounds > maximumSupportCreditPerAction {
                return .rejected("Credit 1–\(maximumSupportCreditPerAction) rounds")
            }
            if trimmed(input.note).isEmpty {
                return .rejected("Add a reason for the credit")
            }
            return .ok
        case .recordRefund:
            if trimmed(input.note).isEmpty {
                return .rejected("Add a refund note for the audit log")
            }
            if input.rounds < 0 || input.rounds > maximumSupportCreditPerAction {
                return .rejected("Claw back 0–\(maximumSupportCreditPerAction) rounds")
            }
            return .ok
        }
    }

    public static func compensationNet(granted: Int, clawedBack: Int) -> Int {
        max(0, granted - max(0, clawedBack))
    }

    /// Weekly pass grants 5 rounds a period; monthly grants 10.
    public static func roundsPerPeriod(for productID: String?) -> Int {
        switch productID {
        case "com.nagrom.roadtrip.weekly": return 5
        case "com.nagrom.roadtrip.monthly": return 10
        default: return 0
        }
    }

    /// Same total the iPhone badge shows: unused free round, subscription
    /// rounds left this period, and round packs still on the device.
    /// Support credits are already inside `purchasedRounds` once applied.
    public static func playableRounds(
        freeRoundUsed: Bool,
        purchasedRounds: Int,
        subscriptionProductID: String?,
        subscriptionRoundsUsed: Int
    ) -> Int {
        let allowance = roundsPerPeriod(for: subscriptionProductID)
        let subscriptionLeft = allowance > 0
            ? max(0, allowance - max(0, subscriptionRoundsUsed))
            : 0
        return (freeRoundUsed ? 0 : 1) + subscriptionLeft + max(0, purchasedRounds)
    }
}

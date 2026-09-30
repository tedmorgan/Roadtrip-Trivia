import XCTest
@testable import RoadtripTriviaLogic

/// Confirms every login, create-account, and recovery option the account
/// sheet advertises, plus the admin-console support actions.
final class AuthAccountPolicyTests: XCTestCase {

    // MARK: - Login catalog

    func test_allLoginMethods_areSupported() {
        let expected: [AuthAccountPolicy.LoginMethod] = [
            .apple, .google, .emailPassword, .usernamePassword, .magicLink,
        ]
        XCTAssertEqual(AuthAccountPolicy.LoginMethod.allCases, expected)
        for method in expected {
            XCTAssertTrue(AuthAccountPolicy.isSupported(method), "\(method) must stay enabled")
        }
        XCTAssertEqual(AuthAccountPolicy.supportedLoginMethods.count, 5)
    }

    func test_emailSignIn_routesToEmailPassword() {
        let input = AuthAccountPolicy.SignInInput(
            identifier: " ted@example.com ",
            password: "secret1"
        )
        XCTAssertEqual(AuthAccountPolicy.validateSignIn(input), .ok)
        XCTAssertEqual(AuthAccountPolicy.loginMethod(forSignIn: input), .emailPassword)
        XCTAssertEqual(AuthAccountPolicy.classifyIdentifier(input.identifier), .email)
    }

    func test_usernameSignIn_routesToUsernamePassword() {
        let input = AuthAccountPolicy.SignInInput(
            identifier: "RoadWarrior",
            password: "secret1"
        )
        XCTAssertEqual(AuthAccountPolicy.validateSignIn(input), .ok)
        XCTAssertEqual(AuthAccountPolicy.loginMethod(forSignIn: input), .usernamePassword)
        XCTAssertEqual(AuthAccountPolicy.normalizedUsername(input.identifier), "roadwarrior")
    }

    func test_signIn_rejectsEmptyFields() {
        XCTAssertEqual(
            AuthAccountPolicy.validateSignIn(.init(identifier: "", password: "secret1")).message,
            "Enter your email or username"
        )
        XCTAssertEqual(
            AuthAccountPolicy.validateSignIn(.init(identifier: "ted@example.com", password: "")).message,
            "Enter your password"
        )
        XCTAssertNil(
            AuthAccountPolicy.loginMethod(forSignIn: .init(identifier: "", password: "x"))
        )
    }

    func test_signIn_rejectsMalformedEmail() {
        let result = AuthAccountPolicy.validateSignIn(
            .init(identifier: "not-an-email@", password: "secret1")
        )
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.message, "Enter a valid email address")
    }

    // MARK: - Create account

    func test_createAccount_requiresUsernameEmailAndPassword() {
        let ok = AuthAccountPolicy.CreateAccountInput(
            username: "roadwarrior",
            email: "ted@example.com",
            password: "secret1"
        )
        XCTAssertEqual(AuthAccountPolicy.validateCreateAccount(ok), .ok)
    }

    func test_createAccount_rejectsShortPassword() {
        let result = AuthAccountPolicy.validateCreateAccount(
            .init(username: "roadwarrior", email: "ted@example.com", password: "12345")
        )
        XCTAssertEqual(result.message, "Password must be at least 6 characters")
    }

    func test_createAccount_rejectsInvalidUsername() {
        XCTAssertEqual(
            AuthAccountPolicy.validateUsername("").message,
            "Choose a username"
        )
        XCTAssertEqual(
            AuthAccountPolicy.validateUsername("ab").message,
            "Username must be at least 3 characters"
        )
        XCTAssertEqual(
            AuthAccountPolicy.validateUsername(String(repeating: "a", count: 21)).message,
            "Username must be 20 characters or fewer"
        )
        XCTAssertEqual(
            AuthAccountPolicy.validateUsername("1roadie").message,
            "Username must start with a letter and use only letters, numbers, or underscores"
        )
        XCTAssertEqual(
            AuthAccountPolicy.validateUsername("road-warrior").message,
            "Username must start with a letter and use only letters, numbers, or underscores"
        )
        XCTAssertEqual(
            AuthAccountPolicy.validateUsername("Admin").message,
            "That username is reserved"
        )
        XCTAssertNil(AuthAccountPolicy.normalizedUsername("support"))
    }

    func test_createAccount_rejectsInvalidEmail() {
        let result = AuthAccountPolicy.validateCreateAccount(
            .init(username: "roadwarrior", email: "nope", password: "secret1")
        )
        XCTAssertEqual(result.message, "Enter a valid email address")
    }

    // MARK: - Recovery

    func test_forgotPassword_acceptsEmailOrUsername() {
        XCTAssertEqual(
            AuthAccountPolicy.validateForgotPassword(identifier: "ted@example.com"),
            .ok
        )
        XCTAssertEqual(
            AuthAccountPolicy.validateForgotPassword(identifier: "roadwarrior"),
            .ok
        )
        XCTAssertEqual(
            AuthAccountPolicy.validateForgotPassword(identifier: "").message,
            "Enter the email or username on the account"
        )
    }

    func test_forgotUsername_requiresEmail() {
        XCTAssertEqual(
            AuthAccountPolicy.validateForgotUsername(email: "ted@example.com"),
            .ok
        )
        XCTAssertEqual(
            AuthAccountPolicy.validateForgotUsername(email: "roadwarrior").message,
            "Enter a valid email address"
        )
    }

    func test_magicLink_requiresEmail() {
        XCTAssertEqual(AuthAccountPolicy.validateMagicLink(email: "ted@example.com"), .ok)
        XCTAssertFalse(AuthAccountPolicy.validateMagicLink(email: "roadwarrior").isValid)
    }

    func test_recoveryAcknowledgements_doNotRevealWhetherAccountExists() {
        XCTAssertTrue(
            AuthAccountPolicy.recoveryAcknowledgement(for: .forgotPassword)
                .contains("If an account exists")
        )
        XCTAssertTrue(
            AuthAccountPolicy.recoveryAcknowledgement(for: .forgotUsername)
                .contains("If an account exists")
        )
        XCTAssertTrue(
            AuthAccountPolicy.recoveryAcknowledgement(for: .magicLink)
                .contains("If an account exists")
        )
    }

    // MARK: - Social providers (catalog lock)

    func test_appleAndGoogle_remainPrimarySocialOptions() {
        XCTAssertTrue(AuthAccountPolicy.isSupported(.apple))
        XCTAssertTrue(AuthAccountPolicy.isSupported(.google))
        XCTAssertFalse(AuthAccountPolicy.LoginMethod.allCases.contains { $0.rawValue == "facebook" })
    }

    // MARK: - Admin / customer support

    func test_adminLookup_requiresASearchQuery() {
        let empty = AuthAccountPolicy.SupportActionInput(action: .lookup, query: "  ")
        XCTAssertEqual(AuthAccountPolicy.validateSupportAction(empty).message, "Search by email, username, or account ID")
        XCTAssertEqual(
            AuthAccountPolicy.validateSupportAction(.init(action: .lookup, query: "ted@example.com")),
            .ok
        )
    }

    func test_adminPasswordResetAndUsernameReminder_useTheSameLookup() {
        XCTAssertEqual(
            AuthAccountPolicy.validateSupportAction(.init(action: .sendPasswordReset, query: "roadwarrior")),
            .ok
        )
        XCTAssertEqual(
            AuthAccountPolicy.validateSupportAction(.init(action: .sendUsernameReminder, query: "ted@example.com")),
            .ok
        )
    }

    func test_adminCreditRounds_requiresPositiveCountAndReason() {
        XCTAssertEqual(
            AuthAccountPolicy.validateSupportAction(
                .init(action: .creditRounds, query: "ted@example.com", rounds: 3, note: "goodwill")
            ),
            .ok
        )
        XCTAssertEqual(
            AuthAccountPolicy.validateSupportAction(
                .init(action: .creditRounds, query: "ted@example.com", rounds: 0, note: "goodwill")
            ).message,
            "Credit 1–50 rounds"
        )
        XCTAssertEqual(
            AuthAccountPolicy.validateSupportAction(
                .init(action: .creditRounds, query: "ted@example.com", rounds: 3, note: "")
            ).message,
            "Add a reason for the credit"
        )
    }

    func test_adminRefund_requiresNoteAndNonNegativeClawback() {
        XCTAssertEqual(
            AuthAccountPolicy.validateSupportAction(
                .init(
                    action: .recordRefund,
                    query: "ted@example.com",
                    rounds: 3,
                    note: "App Store refund 18 Sep",
                    appleTransactionID: "100000123"
                )
            ),
            .ok
        )
        XCTAssertEqual(
            AuthAccountPolicy.validateSupportAction(
                .init(action: .recordRefund, query: "ted@example.com", rounds: 0, note: "")
            ).message,
            "Add a refund note for the audit log"
        )
        XCTAssertEqual(
            AuthAccountPolicy.validateSupportAction(
                .init(action: .recordRefund, query: "ted@example.com", rounds: -1, note: "refund")
            ).message,
            "Claw back 0–50 rounds"
        )
    }

    func test_adminActions_coverCustomerServiceQueries() {
        let actions = Set(AuthAccountPolicy.SupportAction.allCases)
        XCTAssertEqual(actions, [
            .lookup, .sendPasswordReset, .sendUsernameReminder, .creditRounds, .recordRefund,
        ])
    }

    func test_playableRounds_matchThePhoneBadge() {
        // ted@nagrom.com on 25 Sep 2026: monthly pass, 6 used, 1 pack left, free round used.
        XCTAssertEqual(
            AuthAccountPolicy.playableRounds(
                freeRoundUsed: true,
                purchasedRounds: 1,
                subscriptionProductID: "com.nagrom.roadtrip.monthly",
                subscriptionRoundsUsed: 6
            ),
            5
        )
        XCTAssertEqual(
            AuthAccountPolicy.playableRounds(
                freeRoundUsed: false,
                purchasedRounds: 0,
                subscriptionProductID: nil,
                subscriptionRoundsUsed: 0
            ),
            1
        )
        XCTAssertEqual(
            AuthAccountPolicy.playableRounds(
                freeRoundUsed: true,
                purchasedRounds: 0,
                subscriptionProductID: "com.nagrom.roadtrip.weekly",
                subscriptionRoundsUsed: 5
            ),
            0
        )
    }

    func test_compensationNet_neverGoesNegative() {
        XCTAssertEqual(AuthAccountPolicy.compensationNet(granted: 5, clawedBack: 2), 3)
        XCTAssertEqual(AuthAccountPolicy.compensationNet(granted: 2, clawedBack: 9), 0)
        XCTAssertEqual(AuthAccountPolicy.compensationNet(granted: 0, clawedBack: 0), 0)
    }
}

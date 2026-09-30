import XCTest
@testable import RoadtripTriviaLogic

final class DiagnosticLogTests: XCTestCase {

    // MARK: - The switch

    func test_releaseBuildDoesNotLogByDefault() {
        XCTAssertFalse(DiagnosticLog.shouldLog(isDebugBuild: false, testerOverride: nil))
    }

    func test_debugBuildLogsByDefault() {
        XCTAssertTrue(DiagnosticLog.shouldLog(isDebugBuild: true, testerOverride: nil))
    }

    func test_testerCanReEnableLoggingInARelaseBuild() {
        XCTAssertTrue(DiagnosticLog.shouldLog(isDebugBuild: false, testerOverride: true))
    }

    func test_testerCanSilenceLoggingInADebugBuild() {
        XCTAssertFalse(DiagnosticLog.shouldLog(isDebugBuild: true, testerOverride: false))
    }

    // MARK: - Redaction

    func test_redactKeepsLengthButNotContent() {
        let redacted = DiagnosticLog.redact("the answer is Jupiter")
        XCTAssertFalse(redacted.contains("Jupiter"))
        XCTAssertTrue(redacted.contains("21"))
    }

    func test_redactMarksEmptyValues() {
        XCTAssertEqual(DiagnosticLog.redact(nil), "<empty>")
        XCTAssertEqual(DiagnosticLog.redact(""), "<empty>")
    }

    func test_sensitiveKeysAreRedactedAndDiagnosticKeysSurvive() {
        let output = DiagnosticLog.redactingSensitiveKeys([
            "transcript": "we think it is Saturn",
            "playerAnswer": "Saturn",
            "round": 3,
            "elapsedMs": 1200,
        ])
        XCTAssertFalse("\(output)".contains("Saturn"))
        XCTAssertEqual(output["round"] as? Int, 3)
        XCTAssertEqual(output["elapsedMs"] as? Int, 1200)
    }

    func test_redactionReachesNestedPayloads() {
        let output = DiagnosticLog.redactingSensitiveKeys([
            "usage": ["team": "The Morgans", "totalTokens": 900],
        ])
        let nested = output["usage"] as? [String: Any]
        XCTAssertFalse("\(output)".contains("The Morgans"))
        XCTAssertEqual(nested?["totalTokens"] as? Int, 900)
    }

    func test_pseudonymizeShortensTheAccountId() {
        XCTAssertEqual(
            DiagnosticLog.pseudonymize("11111111-2222-3333-4444-555555555555"),
            "11111111"
        )
        XCTAssertNil(DiagnosticLog.pseudonymize(nil))
        XCTAssertNil(DiagnosticLog.pseudonymize(""))
    }

    // MARK: - Stored override

    func test_absentSettingMeansUseTheBuildDefault() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        XCTAssertNil(DiagnosticLog.storedOverride(in: defaults))
    }

    func test_storedSettingIsReadBack() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(true, forKey: DiagnosticLog.defaultsKey)
        XCTAssertEqual(DiagnosticLog.storedOverride(in: defaults), true)
        defaults.set(false, forKey: DiagnosticLog.defaultsKey)
        XCTAssertEqual(DiagnosticLog.storedOverride(in: defaults), false)
    }
}

import XCTest
@testable import RoadtripTriviaLogic

final class FarewellScriptTests: XCTestCase {

    // MARK: - Chain shape

    func test_makeNoRoundsChain_returnsThreeChunks() {
        let chain = FarewellScript.makeNoRoundsChain(
            finalScore: 10,
            roundsPlayed: 3,
            context: "round_limit_reached"
        )
        XCTAssertEqual(chain.count, 3,
                       "summary + purchase + goodbye — three distinct turns")
    }

    func test_makeNoRoundsChain_chunksAreNonEmpty() {
        let chain = FarewellScript.makeNoRoundsChain(
            finalScore: 5,
            roundsPlayed: 2,
            context: "round_limit_reached"
        )
        for (i, chunk) in chain.map({ $0.spokenText }).enumerated() {
            XCTAssertFalse(chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "chunk \(i) must not be empty")
        }
    }

    // MARK: - Score / round substitution

    func test_makeNoRoundsChain_summaryContainsExactScoreAndRoundCount() {
        let chain = FarewellScript.makeNoRoundsChain(
            finalScore: 14,
            roundsPlayed: 3,
            context: "round_limit_reached"
        )
        let summary = chain[0].spokenText
        XCTAssertTrue(summary.contains("14 points"),
                      "summary chunk must announce the literal final score")
        XCTAssertTrue(summary.contains("3 round"),
                      "summary chunk must announce the round count")
    }

    func test_makeNoRoundsChain_singularRoundUsesNoSWord() {
        let chain = FarewellScript.makeNoRoundsChain(
            finalScore: 4,
            roundsPlayed: 1,
            context: "round_limit_reached"
        )
        let summary = chain[0].spokenText
        XCTAssertTrue(summary.contains("1 round."),
                      "1 round must be singular (no plural 's')")
        XCTAssertFalse(summary.contains("1 rounds"),
                       "should not say '1 rounds'")
    }

    func test_makeNoRoundsChain_zeroRoundsOmitsRoundCount() {
        let chain = FarewellScript.makeNoRoundsChain(
            finalScore: 0,
            roundsPlayed: 0,
            context: "round_limit_reached"
        )
        let summary = chain[0].spokenText
        XCTAssertFalse(summary.contains("0 round"),
                       "do not announce '0 rounds'")
        XCTAssertTrue(summary.contains("0 points"))
    }

    // MARK: - Purchase guidance — the 8.log regression

    func test_purchaseChunkExplicitlyMentionsBuyingMoreRounds() {
        let chain = FarewellScript.makeNoRoundsChain(
            finalScore: 10,
            roundsPlayed: 3,
            context: "round_limit_reached"
        )
        let purchase = chain[1].spokenText.lowercased()
        XCTAssertTrue(
            purchase.contains("purchase") || purchase.contains("grab") || purchase.contains("get more") || purchase.contains("buy"),
            "purchase chunk must tell the player how to get more rounds"
        )
        XCTAssertTrue(purchase.contains("rounds") || purchase.contains("playing"),
                      "purchase chunk must mention rounds or keeping playing")
        XCTAssertTrue(purchase.contains("app"),
                      "purchase chunk must direct the player to the app")
    }

    // MARK: - Goodbye chunk

    func test_goodbyeChunkSignalsEndOfSession() {
        let chain = FarewellScript.makeNoRoundsChain(
            finalScore: 10,
            roundsPlayed: 3,
            context: "round_limit_reached"
        )
        let goodbye = chain[2].spokenText.lowercased()
        XCTAssertTrue(
            goodbye.contains("thank") || goodbye.contains("playing")
                || goodbye.contains("farewell") || goodbye.contains("goodbye")
                || goodbye.contains("bye") || goodbye.contains("come back"),
            "goodbye chunk must thank the player or wish them farewell"
        )
    }

    // MARK: - force_message payload is speakable (not LLM meta-instructions)

    func test_spokenTextIsPlainSpeech_notMetaInstructions() {
        let chain = FarewellScript.makeNoRoundsChain(
            finalScore: 10, roundsPlayed: 3, context: "round_limit_reached"
        )
        for (i, chunk) in chain.enumerated() {
            let lower = chunk.spokenText.lowercased()
            XCTAssertFalse(lower.contains("do not call"),
                           "chunk \(i) must be speakable text for force_message, not a prompt")
            XCTAssertFalse(lower.contains("one short"),
                           "chunk \(i) must be speakable text for force_message, not a prompt")
            XCTAssertEqual(chunk.spokenText, chunk.fallbackSpeech)
            XCTAssertEqual(chunk.spokenText, chunk.instruction)
        }
    }

    // MARK: - No template placeholders leak through

    func test_chainContainsNoUnsubstitutedPlaceholders() {
        let chain = FarewellScript.makeNoRoundsChain(
            finalScore: 7,
            roundsPlayed: 2,
            context: "round_limit_reached"
        )
        for (i, chunk) in chain.map({ $0.spokenText }).enumerated() {
            XCTAssertFalse(chunk.contains("\\("), "chunk \(i) leaks an interpolation marker")
            XCTAssertFalse(chunk.contains("{{"), "chunk \(i) leaks a template marker")
            XCTAssertFalse(chunk.contains("}}"), "chunk \(i) leaks a template marker")
        }
    }

    func test_fallbackPurchaseLineContainsCTA() {
        let chain = FarewellScript.makeNoRoundsChain(
            finalScore: 10, roundsPlayed: 3, context: "round_limit_reached"
        )
        let cta = chain[1].fallbackSpeech.lowercased()
        XCTAssertTrue(cta.contains("app"), "fallback CTA must direct the player to the app")
        XCTAssertTrue(cta.contains("rounds") || cta.contains("playing"))
    }

    func test_fallbackSummaryContainsScore() {
        let chain = FarewellScript.makeNoRoundsChain(
            finalScore: 14, roundsPlayed: 3, context: "round_limit_reached"
        )
        XCTAssertTrue(chain[0].fallbackSpeech.contains("14 points"))
    }
}

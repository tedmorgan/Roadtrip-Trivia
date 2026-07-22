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
        for (i, chunk) in chain.map({ $0.instruction }).enumerated() {
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
        let summary = chain[0].instruction
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
        let summary = chain[0].instruction
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
        let summary = chain[0].instruction
        XCTAssertFalse(summary.contains("0 round"),
                       "do not announce '0 rounds'")
        XCTAssertTrue(summary.contains("0 points"))
    }

    // MARK: - Purchase guidance — the 8.log regression

    func test_purchaseChunkExplicitlyMentionsBuyingMoreRounds() {
        // This is the exact bug from `mic_gating 8.log`: the purchase
        // guidance got cut off, leaving the player without instructions
        // for how to keep playing. The chunk MUST contain the explicit CTA.
        let chain = FarewellScript.makeNoRoundsChain(
            finalScore: 10,
            roundsPlayed: 3,
            context: "round_limit_reached"
        )
        let purchase = chain[1].instruction.lowercased()
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
        let goodbye = chain[2].instruction.lowercased()
        XCTAssertTrue(
            goodbye.contains("thank") || goodbye.contains("playing")
                || goodbye.contains("farewell") || goodbye.contains("goodbye")
                || goodbye.contains("bye") || goodbye.contains("warm"),
            "goodbye chunk must thank the player or wish them farewell"
        )
    }

    // MARK: - Anti-tool-call instructions

    func test_eachChunkExplicitlyForbidsToolCalls() {
        // Regression guard: previously the AI would call `end_game` or
        // `get_next_question` mid-farewell, breaking the chain. Every
        // chunk must include an explicit "do not call any tools".
        let chain = FarewellScript.makeNoRoundsChain(
            finalScore: 10,
            roundsPlayed: 3,
            context: "round_limit_reached"
        )
        for (i, chunk) in chain.map({ $0.instruction }).enumerated() {
            let lower = chunk.lowercased()
            XCTAssertTrue(
                lower.contains("do not call") || lower.contains("no tools"),
                "chunk \(i) must forbid tool calls; chunk text: \(chunk)"
            )
        }
    }

    // MARK: - No template placeholders leak through

    func test_chainContainsNoUnsubstitutedPlaceholders() {
        // Catches accidental "\(finalScore)"-style template leakage.
        let chain = FarewellScript.makeNoRoundsChain(
            finalScore: 7,
            roundsPlayed: 2,
            context: "round_limit_reached"
        )
        for (i, chunk) in chain.map({ $0.instruction }).enumerated() {
            XCTAssertFalse(chunk.contains("\\("), "chunk \(i) leaks an interpolation marker")
            XCTAssertFalse(chunk.contains("{{"), "chunk \(i) leaks a template marker")
            XCTAssertFalse(chunk.contains("}}"), "chunk \(i) leaks a template marker")
        }
    }

    // MARK: - Local TTS fallback lines

    func test_everyChunkHasNonEmptyFallbackSpeech() {
        // The fallback line is what the app itself speaks (AVSpeechSynthesizer)
        // when the model never produces audio for a chunk. It must always exist
        // so the farewell + purchase CTA can never be silently dropped.
        let chain = FarewellScript.makeNoRoundsChain(
            finalScore: 10, roundsPlayed: 3, context: "round_limit_reached"
        )
        for (i, chunk) in chain.enumerated() {
            XCTAssertFalse(chunk.fallbackSpeech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "chunk \(i) needs a fallback speech line")
        }
    }

    func test_fallbackSpeechIsPlainSpeech_notMetaInstructions() {
        let chain = FarewellScript.makeNoRoundsChain(
            finalScore: 10, roundsPlayed: 3, context: "round_limit_reached"
        )
        for (i, chunk) in chain.enumerated() {
            let lower = chunk.fallbackSpeech.lowercased()
            XCTAssertFalse(lower.contains("do not call"),
                           "chunk \(i) fallback must be speakable text, not prompt instructions")
            XCTAssertFalse(lower.contains("one short"),
                           "chunk \(i) fallback must be speakable text, not prompt instructions")
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

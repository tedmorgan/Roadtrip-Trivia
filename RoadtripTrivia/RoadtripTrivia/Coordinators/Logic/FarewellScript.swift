import Foundation

/// One step of the no-rounds-left farewell chain.
///
/// `instruction` is the `responseCreate` prompt asking the model to speak the
/// step. `fallbackSpeech` is the plain-text line the APP speaks itself (local
/// TTS via `ConnectionMonitor.speakOffline`) if the model produces no audio
/// for the step — guaranteeing the farewell and the purchase CTA are ALWAYS
/// delivered, even when the model goes silent or the turn is dropped.
struct FarewellChunk: Equatable {
    let instruction: String
    let fallbackSpeech: String
}

/// Pure builder for the no-rounds-left farewell chain.
///
/// Extracted from `RealtimeGameCoordinator.makeNoRoundsFarewellChain`
/// so the chain content can be unit-tested. The coordinator's job is
/// only to *deliver* these scripts; what they say is verified here.
///
/// Returns three explicit steps, one per AI turn:
///   1. Summary  — warm reaction + final score sentence
///   2. Purchase — explicit CTA to open the app and buy more rounds
///   3. Goodbye  — two-sentence farewell
///
/// We split into three because previously a single longer prompt was
/// cut off by the model after the first sentence, leaving the player
/// without the purchase guidance.
enum FarewellScript {

    static func makeNoRoundsChain(
        finalScore: Int,
        roundsPlayed: Int,
        context: String
    ) -> [FarewellChunk] {
        let summarySentence: String
        if roundsPlayed > 0 {
            summarySentence = "Your final score is \(finalScore) points across \(roundsPlayed) round\(roundsPlayed == 1 ? "" : "s")."
        } else {
            summarySentence = "Your final score is \(finalScore) points."
        }

        let summaryInstruction = """
        The player has just finished their LAST available round. In ONE short \
        uninterrupted turn, give a warm reaction and announce this exact final score: \
        "\(summarySentence)" Do NOT ask if they want to play again. Do NOT call any tools.
        """

        // Short, direct CTA — previous version was a 40-word "Say exactly"
        // block that the AI abbreviated to ~5s. This version is 18 words,
        // impossible to meaningfully shorten further.
        let purchaseSpoken = "You've used all your rounds — grab more in the Roadtrip Trivia app to keep playing!"
        let purchaseInstruction = """
        Say this in one sentence: "\(purchaseSpoken)" \
        Do NOT add anything else. Do NOT call any tools.
        """

        let goodbyeSpoken = "Thanks for playing Roadtrip Trivia! Come back soon."
        let goodbyeInstruction = """
        End with a short, warm goodbye. Thank them for playing and \
        invite them back. Two sentences max, then stop. \
        Do NOT call any tools. Do NOT ask any questions.
        """

        _ = context
        return [
            FarewellChunk(instruction: summaryInstruction,
                          fallbackSpeech: "Great game! \(summarySentence)"),
            FarewellChunk(instruction: purchaseInstruction,
                          fallbackSpeech: purchaseSpoken),
            FarewellChunk(instruction: goodbyeInstruction,
                          fallbackSpeech: goodbyeSpoken)
        ]
    }
}

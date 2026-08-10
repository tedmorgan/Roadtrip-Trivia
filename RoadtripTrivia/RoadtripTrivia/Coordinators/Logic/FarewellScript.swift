import Foundation

/// One step of the no-rounds-left farewell chain.
///
/// `spokenText` is the verbatim line delivered via xAI `force_message`
/// (and via local TTS if that turn produces no audio). The app owns the
/// farewell so purchase CTA / goodbye can never be truncated by the model.
struct FarewellChunk: Equatable {
    let spokenText: String

    /// Alias kept so existing coordinator / test call sites stay readable.
    var fallbackSpeech: String { spokenText }

    /// Alias for the spoken line (force_message has no LLM instruction prompt).
    var instruction: String { spokenText }
}

/// Pure builder for the no-rounds-left farewell chain.
///
/// Extracted from `RealtimeGameCoordinator.makeNoRoundsFarewellChain`
/// so the chain content can be unit-tested. The coordinator's job is
/// only to *deliver* these scripts; what they say is verified here.
///
/// Returns three explicit steps, one force_message turn each:
///   1. Summary  — warm reaction + final score sentence
///   2. Purchase — explicit CTA to open the app and buy more rounds
///   3. Goodbye  — short farewell
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

        let purchaseSpoken = "You've used all your rounds — grab more in the Roadtrip Trivia app to keep playing!"
        let goodbyeSpoken = "Thanks for playing Roadtrip Trivia! Come back soon."

        _ = context
        return [
            FarewellChunk(spokenText: "Great game! \(summarySentence)"),
            FarewellChunk(spokenText: purchaseSpoken),
            FarewellChunk(spokenText: goodbyeSpoken)
        ]
    }
}

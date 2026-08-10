// swift-tools-version:5.7
import PackageDescription

// Standalone Swift Package used solely to run unit tests against the
// app's pure-logic helpers (AnswerGrader, FarewellScript, ...) without
// having to bring up the full iOS app, WebSocket session, or audio
// stack.
//
// The package does NOT replace the Xcode project — those source files
// remain part of the iOS target. The package simply consumes them by
// `path:` so we can run `swift test` from the command line and from CI.
//
// Layout:
//   RoadtripTrivia/Coordinators/Logic/   <- pure source (compiled by both)
//   RoadtripTrivia/Services/Realtime/    <- Foundation-only protocol layer
//   Tests/RoadtripTriviaLogicTests/      <- XCTest cases
//   Tests/RoadtripTriviaRealtimeTests/   <- Grok wire-protocol XCTest cases
let package = Package(
    name: "RoadtripTriviaLogic",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(name: "RoadtripTriviaLogic", targets: ["RoadtripTriviaLogic"]),
        .library(name: "RoadtripTriviaRealtime", targets: ["RoadtripTriviaRealtime"]),
    ],
    targets: [
        .target(
            name: "RoadtripTriviaLogic",
            path: "RoadtripTrivia/Coordinators/Logic",
            sources: [
                "AnswerGrader.swift",
                "FarewellScript.swift",
                "PostScoreWatchdogPolicy.swift",
                "EndGamePolicy.swift",
                "PlayerIntentClassifier.swift",
                "FarewellAdvancer.swift",
                "QuestionReadWatchdogPolicy.swift",
                "ReportScoreActionPolicy.swift",
                "ReportScoreResultContract.swift",
                "FarewellEndGamePolicy.swift",
                "ScoreRevisionPolicy.swift",
                "BargeInPolicy.swift",
                "PreRollBuffer.swift",
                "TurnRecoveryGovernor.swift",
                "VerdictLineComposer.swift",
                "RoundIntroComposer.swift",
                "NoAnswerGuardPolicy.swift",
                "TranscriptionKeytermsBuilder.swift",
            ]
        ),
        .target(
            name: "RoadtripTriviaRealtime",
            path: "RoadtripTrivia/Services/Realtime",
            exclude: [
                "RealtimeSessionManager.swift",
                "SystemPromptBuilder.swift",
                "QuestionBatchService.swift",
                "AudioStreamingService.swift",
            ],
            sources: [
                "RealtimeModels.swift",
                "APIUsageLogger.swift",
            ]
        ),
        .testTarget(
            name: "RoadtripTriviaLogicTests",
            dependencies: ["RoadtripTriviaLogic"],
            path: "Tests/RoadtripTriviaLogicTests"
        ),
        .testTarget(
            name: "RoadtripTriviaRealtimeTests",
            dependencies: ["RoadtripTriviaRealtime"],
            path: "Tests/RoadtripTriviaRealtimeTests"
        ),
    ]
)

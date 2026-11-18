import Foundation
import AppIntents

enum WorkoutCommand { case pause, end }

/// The app installs a handler at launch. Live Activity intents run in the app's process,
/// so the widget extension only needs the intent types, not the workout logic.
enum WorkoutCommandBridge {
    @MainActor static var handler: ((WorkoutCommand) -> Void)?
}

struct PauseWorkoutIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause or resume workout"
    func perform() async throws -> some IntentResult {
        await MainActor.run { WorkoutCommandBridge.handler?(.pause) }
        return .result()
    }
}

struct EndWorkoutIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "End workout"
    func perform() async throws -> some IntentResult {
        await MainActor.run { WorkoutCommandBridge.handler?(.end) }
        return .result()
    }
}

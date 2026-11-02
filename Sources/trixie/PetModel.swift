import Foundation

/// What the pet is doing. The controller sets this; the drawing code reads it.
enum PetMood {
    case idle        // waiting, blinking, looking at your cursor
    case listening   // you are holding the hotkey
    case thinking    // you finished speaking, Claude is working it out
    case working     // Claude is reading your files
    case talking     // the voice is speaking
    case happy       // just finished answering
    case sleeping    // nothing happened for a while
}

/// Everything the drawing code needs for one frame.
struct PetSnapshot {
    var mood: PetMood
    var since: TimeInterval      // when the mood started
    var hopStart: TimeInterval   // when the last hop started
    var lookX: Int               // where the eyes look, -1...1
    var lookY: Int
}

@MainActor
final class PetModel {
    var mood: PetMood = .idle {
        didSet { if mood != oldValue { moodSince = Date.timeIntervalSinceReferenceDate } }
    }
    private(set) var moodSince = Date.timeIntervalSinceReferenceDate
    private var hopStart: TimeInterval = -1000
    var lookX = 0
    var lookY = 0

    func hop() { hopStart = Date.timeIntervalSinceReferenceDate }

    func snapshot() -> PetSnapshot {
        PetSnapshot(mood: mood, since: moodSince, hopStart: hopStart, lookX: lookX, lookY: lookY)
    }
}

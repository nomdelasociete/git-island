import AppKit

/// Plays event sounds and manages the user's imported ones. Imported files are
/// copied into Application Support so they survive without sandbox bookmarks.
@MainActor
final class IslandSoundPlayer {
    static let shared = IslandSoundPlayer()

    private let fileManager = FileManager.default
    /// NSSound stops when released; keep the current one alive while it plays.
    private var currentSound: NSSound?

    let systemSoundNames: [String]

    private init() {
        let directory = URL(fileURLWithPath: "/System/Library/Sounds")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        systemSoundNames = files
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    var customSoundsDirectory: URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support.appendingPathComponent("Sounds", isDirectory: true)
    }

    func customSoundFileNames() -> [String] {
        guard let directory = customSoundsDirectory,
              let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else {
            return []
        }

        return files
            .map(\.lastPathComponent)
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Copies the file in, replacing an earlier import with the same name.
    func importCustomSound(from source: URL) throws -> String {
        guard let directory = customSoundsDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        return destination.lastPathComponent
    }

    func deleteCustomSound(named fileName: String) {
        guard let directory = customSoundsDirectory else { return }
        try? fileManager.removeItem(at: directory.appendingPathComponent(fileName))
    }

    func play(_ choice: IslandSoundChoice) {
        let sound: NSSound?
        switch choice {
        case .none:
            sound = nil
        case .system(let name):
            sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound
        case .custom(let fileName):
            sound = customSoundsDirectory.flatMap {
                NSSound(contentsOf: $0.appendingPathComponent(fileName), byReference: true)
            }
        }

        guard let sound else { return }
        currentSound?.stop()
        currentSound = sound
        sound.play()
    }
}

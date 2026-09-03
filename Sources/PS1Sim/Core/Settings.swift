import Foundation

/// User preferences, persisted as JSON next to the library.
@MainActor
final class Settings: ObservableObject {
    @Published var smoothScaling: Bool { didSet { save() } }
    @Published var integerScaling: Bool { didSet { save() } }
    @Published var crtScanlines: Bool { didSet { save() } }
    @Published var showControlHints: Bool { didSet { save() } }
    @Published var resumeOnLaunch: Bool { didSet { save() } }
    @Published var buttonMap: [UInt16: PadButton] { didSet { save() } }
    @Published var axisMap: [UInt16: PadAxis] { didSet { save() } }

    private struct Stored: Codable {
        var smoothScaling: Bool
        var integerScaling: Bool
        var crtScanlines: Bool
        var showControlHints: Bool?
        var resumeOnLaunch: Bool?
        var buttonMap: [String: PadButton]
        var axisMap: [String: PadAxis]
    }

    init() {
        let stored = try? JSONDecoder().decode(Stored.self, from: Data(contentsOf: Paths.settingsFile))
        smoothScaling = stored?.smoothScaling ?? true
        integerScaling = stored?.integerScaling ?? false
        crtScanlines = stored?.crtScanlines ?? false
        showControlHints = stored?.showControlHints ?? true
        resumeOnLaunch = stored?.resumeOnLaunch ?? true
        if let map = stored?.buttonMap {
            buttonMap = Dictionary(uniqueKeysWithValues: map.compactMap { key, value in
                UInt16(key).map { ($0, value) }
            })
        } else {
            buttonMap = InputState.defaultButtonMap
        }
        if let map = stored?.axisMap {
            axisMap = Dictionary(uniqueKeysWithValues: map.compactMap { key, value in
                UInt16(key).map { ($0, value) }
            })
        } else {
            axisMap = InputState.defaultAxisMap
        }
    }

    func bind(key: UInt16, to button: PadButton) {
        buttonMap = buttonMap.filter { $0.value != button }
        axisMap.removeValue(forKey: key)
        buttonMap[key] = button
    }

    func bind(key: UInt16, to axis: PadAxis) {
        axisMap = axisMap.filter { $0.value != axis }
        buttonMap.removeValue(forKey: key)
        axisMap[key] = axis
    }

    func resetControls() {
        buttonMap = InputState.defaultButtonMap
        axisMap = InputState.defaultAxisMap
    }

    func key(for button: PadButton) -> UInt16? {
        buttonMap.first { $0.value == button }?.key
    }

    func key(for axis: PadAxis) -> UInt16? {
        axisMap.first { $0.value == axis }?.key
    }

    func apply(to input: InputState) {
        input.buttonMap = buttonMap
        input.axisMap = axisMap
    }

    private func save() {
        let stored = Stored(
            smoothScaling: smoothScaling,
            integerScaling: integerScaling,
            crtScanlines: crtScanlines,
            showControlHints: showControlHints,
            resumeOnLaunch: resumeOnLaunch,
            buttonMap: Dictionary(uniqueKeysWithValues: buttonMap.map { (String($0.key), $0.value) }),
            axisMap: Dictionary(uniqueKeysWithValues: axisMap.map { (String($0.key), $0.value) })
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? data.write(to: Paths.settingsFile, options: .atomic)
    }
}

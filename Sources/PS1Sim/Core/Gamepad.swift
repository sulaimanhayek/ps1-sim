import Foundation
import GameController

/// Bridges a physical controller into `InputState`. Entirely optional: if nothing
/// is connected, or the framework reports nothing, the keyboard path is unchanged.
///
/// Values arrive through GameController's own change handlers on a private queue
/// rather than being polled from the emulation thread, because reading a
/// `GCController` off its handler queue is not guaranteed safe.
@MainActor
final class GamepadBridge {

    /// Name of the connected controller, for the UI. nil when none is.
    private(set) var connected: String? {
        didSet { if connected != oldValue { onConnectionChange?(connected) } }
    }

    var onConnectionChange: ((String?) -> Void)?

    private let input: InputState
    private let queue = DispatchQueue(label: "PS1Sim.gamepad")
    private var observers: [NSObjectProtocol] = []

    init(input: InputState) {
        self.input = input
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil,
                                            queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.attach(note.object as? GCController) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAfterDisconnect() }
        })
        for controller in GCController.controllers() { attach(controller) }
        // Picks up a DualSense or Xbox pad that is paired but idle.
        GCController.startWirelessControllerDiscovery {}
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        input.clearGamepad()
        connected = nil
    }

    private func refreshAfterDisconnect() {
        input.clearGamepad()
        connected = GCController.controllers().first?.vendorName
    }

    private func attach(_ controller: GCController?) {
        guard let controller, let pad = controller.extendedGamepad else { return }
        connected = controller.vendorName ?? "Controller"
        controller.handlerQueue = queue
        pad.valueChangedHandler = { [input] pad, _ in
            input.setGamepad(buttons: GamepadBridge.buttons(of: pad),
                             axes: GamepadBridge.axes(of: pad))
        }
    }

    // MARK: - Mapping

    /// GameController already reports the bottom face button as `buttonA`, which is
    /// Cross on a DualSense and A on an Xbox pad — so this ordering is right for
    /// both without special-casing the vendor.
    private static func buttons(of pad: GCExtendedGamepad) -> Set<PadButton> {
        var held = Set<PadButton>()
        func add(_ button: GCControllerButtonInput?, _ mapped: PadButton) {
            if button?.isPressed == true { held.insert(mapped) }
        }
        add(pad.buttonA, .cross)
        add(pad.buttonB, .circle)
        add(pad.buttonX, .square)
        add(pad.buttonY, .triangle)
        add(pad.leftShoulder, .l1)
        add(pad.rightShoulder, .r1)
        add(pad.leftTrigger, .l2)
        add(pad.rightTrigger, .r2)
        add(pad.leftThumbstickButton, .l3)
        add(pad.rightThumbstickButton, .r3)
        add(pad.buttonMenu, .start)
        add(pad.buttonOptions, .select)
        add(pad.dpad.up, .up)
        add(pad.dpad.down, .down)
        add(pad.dpad.left, .left)
        add(pad.dpad.right, .right)
        return held
    }

    /// Keyed by libretro's (stick index, axis id). Y is inverted: GameController
    /// reports up as positive, libretro expects up to be negative.
    private static func axes(of pad: GCExtendedGamepad) -> [UInt32: Int16] {
        [InputState.axisKey(index: 0, axis: 0): scale(pad.leftThumbstick.xAxis.value),
         InputState.axisKey(index: 0, axis: 1): scale(-pad.leftThumbstick.yAxis.value),
         InputState.axisKey(index: 1, axis: 0): scale(pad.rightThumbstick.xAxis.value),
         InputState.axisKey(index: 1, axis: 1): scale(-pad.rightThumbstick.yAxis.value)]
    }

    private static func scale(_ value: Float) -> Int16 {
        // A small dead zone: analogue sticks rest a little off centre once worn,
        // and PS1 games read that as a constant drift.
        guard abs(value) > 0.12 else { return 0 }
        return Int16(max(-32767, min(32767, value * 32767)))
    }
}

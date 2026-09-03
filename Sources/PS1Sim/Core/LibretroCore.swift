import Foundation
import CLibretro

/// A frame handed up from the core, already converted to BGRA8.
struct VideoFrame {
    var width: Int
    var height: Int
    var aspect: Float
    var pixels: [UInt8]   // BGRA8888, width * height * 4
}

enum CoreError: LocalizedError {
    case missingCore(String)
    case dlopenFailed(String)
    case missingSymbol(String)
    case loadGameFailed(String)
    case notRunning

    var errorDescription: String? {
        switch self {
        case .missingCore(let path):
            return "No emulator core at \(path). Install one from Settings."
        case .dlopenFailed(let message):
            return "The core could not be loaded: \(message)"
        case .missingSymbol(let name):
            return "The core is missing the symbol \(name); it may not be a libretro core."
        case .loadGameFailed(let title):
            return "The core refused to load \(title). Check that a PS1 BIOS is installed and the disc image is intact."
        case .notRunning:
            return "No game is running."
        }
    }
}

/// Wraps one dlopen'd libretro core. All libretro entry points are called from
/// the emulation thread; `LibretroCore.active` routes the core's C callbacks back
/// into this instance.
final class LibretroCore: @unchecked Sendable {

    // MARK: libretro function pointer types

    private typealias FnVoid          = @convention(c) () -> Void
    private typealias FnSetEnv        = @convention(c) (@convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool) -> Void
    private typealias FnSetVideo      = @convention(c) (@convention(c) (UnsafeRawPointer?, UInt32, UInt32, Int) -> Void) -> Void
    private typealias FnSetAudioBatch = @convention(c) (@convention(c) (UnsafePointer<Int16>?, Int) -> Int) -> Void
    private typealias FnSetAudio      = @convention(c) (@convention(c) (Int16, Int16) -> Void) -> Void
    private typealias FnSetInputPoll  = @convention(c) (@convention(c) () -> Void) -> Void
    private typealias FnSetInputState = @convention(c) (@convention(c) (UInt32, UInt32, UInt32, UInt32) -> Int16) -> Void
    private typealias FnLoadGame      = @convention(c) (UnsafePointer<retro_game_info>?) -> Bool
    private typealias FnAVInfo        = @convention(c) (UnsafeMutablePointer<retro_system_av_info>?) -> Void
    private typealias FnSystemInfo    = @convention(c) (UnsafeMutablePointer<retro_system_info>?) -> Void
    private typealias FnSize          = @convention(c) () -> Int
    private typealias FnSerialize     = @convention(c) (UnsafeMutableRawPointer?, Int) -> Bool
    private typealias FnUnserialize   = @convention(c) (UnsafeRawPointer?, Int) -> Bool
    private typealias FnPortDevice    = @convention(c) (UInt32, UInt32) -> Void

    // MARK: State

    /// The core currently receiving C callbacks. Only one core is live at a time.
    nonisolated(unsafe) static var active: LibretroCore?

    private var handle: UnsafeMutableRawPointer?
    private var run_: FnVoid!
    private var deinit_: FnVoid!
    private var unloadGame_: FnVoid!
    private var reset_: FnVoid!
    private var serializeSize_: FnSize!
    private var serialize_: FnSerialize!
    private var unserialize_: FnUnserialize!

    private(set) var libraryName = "unknown"
    private(set) var libraryVersion = ""
    private(set) var fps: Double = 60.0
    private(set) var sampleRate: Double = 44100.0

    /// RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_ANALOG, 1) as reported by this core.
    static let dualShockDevice: UInt32 = 517

    /// 0 = RGB1555, 1 = XRGB8888, 2 = RGB565.
    private var pixelFormat: UInt32 = 0
    private var geometryAspect: Float = 4.0 / 3.0

    /// Core options we answer GET_VARIABLE with. Tuned for accuracy on a Mac.
    /// Core options we answer GET_VARIABLE with. Every key and value here is
    /// verified against the core with Tools/core-probe.c — an unknown key makes
    /// GET_VARIABLE return false, and an invalid value is silently ignored, so
    /// both fail quietly rather than erroring.
    private var variables: [String: String] = [
        // Memory cards. Written by the core itself as <SERIAL>_1.mcd in the save
        // directory, which is the layout DuckStation and ePSXe also read.
        "pcsx_rearmed_memcard1": "serial",
        "pcsx_rearmed_memcard2": "serial",

        "pcsx_rearmed_frameskip": "0",
        "pcsx_rearmed_region": "auto",
        "pcsx_rearmed_analog_axis_modifier": "circle",
        "pcsx_rearmed_vibration": "enabled",
        "pcsx_rearmed_dithering": "enabled",
        "pcsx_rearmed_display_internal_fps": "disabled",
        "pcsx_rearmed_show_bios_bootlogo": "disabled",
        "pcsx_rearmed_spu_reverb": "enabled",
        "pcsx_rearmed_spu_interpolation": "gaussian",
        "pcsx_rearmed_neon_enhancement_enable": "disabled",
        "pcsx_rearmed_gpu_slow_llists": "disabled",
    ]

    /// Called on the emulation thread with each converted frame.
    /// Called on the emulation thread with each converted frame.
    var onVideoFrame: ((VideoFrame) -> Void)?
    /// Called on the emulation thread with interleaved stereo Int16 samples.
    var onAudioSamples: ((UnsafePointer<Int16>, Int) -> Void)?
    var onInputPoll: (() -> Void)?
    /// (port, device, index, id) -> value.
    var onInputState: ((UInt32, UInt32, UInt32, UInt32) -> Int16)?
    var onLog: ((String) -> Void)?

    /// Scratch buffer reused every frame so we are not allocating at 60 Hz.
    private var conversionBuffer = [UInt8]()

    // MARK: - Lifecycle

    init(corePath: URL) throws {
        guard FileManager.default.fileExists(atPath: corePath.path) else {
            throw CoreError.missingCore(corePath.path)
        }
        guard let handle = dlopen(corePath.path, RTLD_LAZY | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            throw CoreError.dlopenFailed(reason)
        }
        self.handle = handle

        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw CoreError.missingSymbol(name) }
            return unsafeBitCast(pointer, to: type)
        }

        let setEnvironment   = try symbol("retro_set_environment", as: FnSetEnv.self)
        let setVideoRefresh  = try symbol("retro_set_video_refresh", as: FnSetVideo.self)
        let setAudioSample   = try symbol("retro_set_audio_sample", as: FnSetAudio.self)
        let setAudioBatch    = try symbol("retro_set_audio_sample_batch", as: FnSetAudioBatch.self)
        let setInputPoll     = try symbol("retro_set_input_poll", as: FnSetInputPoll.self)
        let setInputState    = try symbol("retro_set_input_state", as: FnSetInputState.self)
        let init_            = try symbol("retro_init", as: FnVoid.self)
        let getSystemInfo    = try symbol("retro_get_system_info", as: FnSystemInfo.self)

        run_           = try symbol("retro_run", as: FnVoid.self)
        deinit_        = try symbol("retro_deinit", as: FnVoid.self)
        unloadGame_    = try symbol("retro_unload_game", as: FnVoid.self)
        reset_         = try symbol("retro_reset", as: FnVoid.self)
        serializeSize_ = try symbol("retro_serialize_size", as: FnSize.self)
        serialize_     = try symbol("retro_serialize", as: FnSerialize.self)
        unserialize_   = try symbol("retro_unserialize", as: FnUnserialize.self)

        LibretroCore.active = self

        var info = retro_system_info()
        getSystemInfo(&info)
        if let name = info.library_name { libraryName = String(cString: name) }
        if let version = info.library_version { libraryVersion = String(cString: version) }

        ps1sim_set_log_sink { level, message in
            guard let message, level >= 1 else { return }
            LibretroCore.active?.onLog?(String(cString: message).trimmingCharacters(in: .newlines))
        }

        setEnvironment { cmd, data in LibretroCore.active?.handleEnvironment(cmd, data) ?? false }
        setVideoRefresh { data, width, height, pitch in
            LibretroCore.active?.handleVideo(data, Int(width), Int(height), pitch)
        }
        setAudioBatch { data, frames in
            if let data { LibretroCore.active?.onAudioSamples?(data, frames) }
            return frames
        }
        setAudioSample { left, right in
            var pair = (left, right)
            withUnsafePointer(to: &pair) { pointer in
                pointer.withMemoryRebound(to: Int16.self, capacity: 2) {
                    LibretroCore.active?.onAudioSamples?($0, 1)
                }
            }
        }
        setInputPoll { LibretroCore.active?.onInputPoll?() }
        setInputState { port, device, index, id in
            LibretroCore.active?.onInputState?(port, device, index, id) ?? 0
        }

        init_()
    }

    /// Loads a disc image. `path` must be a file the core can open directly.
    func loadGame(path: URL) throws {
        guard let handle,
              let loadPointer = dlsym(handle, "retro_load_game"),
              let avPointer = dlsym(handle, "retro_get_system_av_info") else {
            throw CoreError.missingSymbol("retro_load_game")
        }
        let loadGame = unsafeBitCast(loadPointer, to: FnLoadGame.self)
        let getAVInfo = unsafeBitCast(avPointer, to: FnAVInfo.self)

        let ok = path.path.withCString { cPath -> Bool in
            var info = retro_game_info(path: cPath, data: nil, size: 0, meta: nil)
            return loadGame(&info)
        }
        guard ok else { throw CoreError.loadGameFailed(path.lastPathComponent) }

        var av = retro_system_av_info()
        getAVInfo(&av)
        fps = av.timing.fps > 0 ? av.timing.fps : 60.0
        sampleRate = av.timing.sample_rate > 0 ? av.timing.sample_rate : 44100.0
        if av.geometry.aspect_ratio > 0 { geometryAspect = av.geometry.aspect_ratio }

        // Ask for a DualShock on both ports. 517 is the subclass id this core
        // advertises for "dualshock"; plain RETRO_DEVICE_JOYPAD (1) is the digital
        // pad and reports no analog sticks at all.
        if let devicePointer = dlsym(handle, "retro_set_controller_port_device") {
            let setDevice = unsafeBitCast(devicePointer, to: FnPortDevice.self)
            setDevice(0, LibretroCore.dualShockDevice)
            setDevice(1, LibretroCore.dualShockDevice)
        }
    }

    func run() { run_() }
    func reset() { reset_() }

    func shutdown() {
        unloadGame_()
        deinit_()
        if LibretroCore.active === self { LibretroCore.active = nil }
        if let handle { dlclose(handle) }
        handle = nil
    }

    // MARK: - Save states

    func serializeState() throws -> Data {
        let size = serializeSize_()
        guard size > 0 else { throw CoreError.notRunning }
        var data = Data(count: size)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return serialize_(base, size)
        }
        guard ok else { throw CoreError.notRunning }
        return data
    }

    func restoreState(_ data: Data) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return unserialize_(base, buffer.count)
        }
    }

    // MARK: - Environment

    private func handleEnvironment(_ rawCommand: UInt32, _ data: UnsafeMutableRawPointer?) -> Bool {
        // Strip the EXPERIMENTAL bit so both spellings of a command land here.
        let command = rawCommand & ~UInt32(0x10000)
        switch command {
        case 3: // GET_CAN_DUPE
            data?.assumingMemoryBound(to: Bool.self).pointee = true
            return true

        case 9: // GET_SYSTEM_DIRECTORY
            return writePath(Paths.system, to: data, cache: &systemPathCache)

        case 31: // GET_SAVE_DIRECTORY
            return writePath(Paths.saves, to: data, cache: &savePathCache)

        case 30: // GET_CORE_ASSETS_DIRECTORY
            return writePath(Paths.root, to: data, cache: &assetsPathCache)

        case 10: // SET_PIXEL_FORMAT
            guard let data else { return false }
            let format = data.assumingMemoryBound(to: UInt32.self).pointee
            guard format <= 2 else { return false }
            pixelFormat = format
            return true

        case 15: // GET_VARIABLE
            guard let data else { return false }
            let variable = data.assumingMemoryBound(to: retro_variable.self)
            guard let keyPointer = variable.pointee.key else { return false }
            let key = String(cString: keyPointer)
            guard let value = variables[key] else {
                // A key we do not answer leaves the core on its own default, which
                // is how the memory card silently went missing. Log it so the next
                // gap is visible rather than mysterious.
                if unansweredVariables.insert(key).inserted {
                    onLog?("no value supplied for core option \(key)")
                }
                return false
            }
            variable.pointee.value = cachedCString(for: value)
            return true

        case 17: // GET_VARIABLE_UPDATE — our options never change mid-run
            data?.assumingMemoryBound(to: Bool.self).pointee = false
            return true

        case 27: // GET_LOG_INTERFACE
            data?.assumingMemoryBound(to: retro_log_callback.self).pointee =
                retro_log_callback(log: ps1sim_log_function())
            return true

        case 52: // GET_CORE_OPTIONS_VERSION — 0 makes the core use plain SET_VARIABLES
            data?.assumingMemoryBound(to: UInt32.self).pointee = 0
            return true

        case 39: // GET_LANGUAGE — English
            data?.assumingMemoryBound(to: UInt32.self).pointee = 0
            return true

        case 51: // GET_INPUT_BITMASKS — we answer per-button instead
            return false

        case 37, 32: // SET_GEOMETRY / SET_SYSTEM_AV_INFO
            if command == 37, let data {
                let geometry = data.assumingMemoryBound(to: retro_game_geometry.self).pointee
                if geometry.aspect_ratio > 0 { geometryAspect = geometry.aspect_ratio }
            } else if command == 32, let data {
                let av = data.assumingMemoryBound(to: retro_system_av_info.self).pointee
                if av.geometry.aspect_ratio > 0 { geometryAspect = av.geometry.aspect_ratio }
                if av.timing.fps > 0 { fps = av.timing.fps }
            }
            return true

        case 6: // SET_MESSAGE
            if let data {
                let message = data.assumingMemoryBound(to: retro_message.self).pointee
                if let text = message.msg { onLog?(String(cString: text)) }
            }
            return true

        case 8, 11, 16, 18, 21, 35, 36, 55, 65, 66, 69, 70:
            // Performance level, input descriptors, variable declarations, subsystem
            // and controller info: accepted, nothing for us to do.
            return true

        default:
            return false
        }
    }

    // Environment string returns must stay alive after we return.
    private var systemPathCache: [CChar] = []
    private var savePathCache: [CChar] = []
    private var assetsPathCache: [CChar] = []
    private var variableCache: [String: [CChar]] = [:]
    private var unansweredVariables = Set<String>()

    private func writePath(_ url: URL, to data: UnsafeMutableRawPointer?, cache: inout [CChar]) -> Bool {
        guard let data else { return false }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if cache.isEmpty { cache = Array(url.path.utf8CString) }
        cache.withUnsafeBufferPointer { buffer in
            data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee = buffer.baseAddress
        }
        return true
    }

    private func cachedCString(for value: String) -> UnsafePointer<CChar>? {
        if variableCache[value] == nil { variableCache[value] = Array(value.utf8CString) }
        return variableCache[value]!.withUnsafeBufferPointer { $0.baseAddress }
    }

    // MARK: - Video conversion

    private func handleVideo(_ data: UnsafeRawPointer?, _ width: Int, _ height: Int, _ pitch: Int) {
        // A nil frame means "same as last time" (we advertised GET_CAN_DUPE).
        guard let data, width > 0, height > 0 else { return }
        let byteCount = width * height * 4
        if conversionBuffer.count != byteCount {
            conversionBuffer = [UInt8](repeating: 0, count: byteCount)
        }

        conversionBuffer.withUnsafeMutableBytes { destination in
            guard let out = destination.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
            switch pixelFormat {
            case 1: // XRGB8888 — already BGRA in little-endian byte order
                for row in 0..<height {
                    let source = data.advanced(by: row * pitch).assumingMemoryBound(to: UInt32.self)
                    let target = out.advanced(by: row * width)
                    for column in 0..<width { target[column] = source[column] | 0xFF00_0000 }
                }
            case 2: // RGB565
                for row in 0..<height {
                    let source = data.advanced(by: row * pitch).assumingMemoryBound(to: UInt16.self)
                    let target = out.advanced(by: row * width)
                    for column in 0..<width {
                        let pixel = source[column]
                        let r = UInt32((pixel >> 11) & 0x1F) * 255 / 31
                        let g = UInt32((pixel >> 5) & 0x3F) * 255 / 63
                        let b = UInt32(pixel & 0x1F) * 255 / 31
                        target[column] = 0xFF00_0000 | (r << 16) | (g << 8) | b
                    }
                }
            default: // RGB1555
                for row in 0..<height {
                    let source = data.advanced(by: row * pitch).assumingMemoryBound(to: UInt16.self)
                    let target = out.advanced(by: row * width)
                    for column in 0..<width {
                        let pixel = source[column]
                        let r = UInt32((pixel >> 10) & 0x1F) * 255 / 31
                        let g = UInt32((pixel >> 5) & 0x1F) * 255 / 31
                        let b = UInt32(pixel & 0x1F) * 255 / 31
                        target[column] = 0xFF00_0000 | (r << 16) | (g << 8) | b
                    }
                }
            }
        }

        onVideoFrame?(VideoFrame(width: width, height: height,
                                 aspect: geometryAspect, pixels: conversionBuffer))
    }
}

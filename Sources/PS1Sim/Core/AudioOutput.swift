import Foundation
import AVFoundation

/// Lock-free-ish ring buffer feeding AVAudioEngine from the emulation thread.
/// The core produces interleaved stereo Int16; CoreAudio wants deinterleaved Float32.
final class AudioOutput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    private let lock = NSLock()
    private var buffer: [Float]        // interleaved L,R
    private var writeIndex = 0
    private var readIndex = 0
    private var filled = 0
    private let capacity: Int

    private(set) var isRunning = false

    /// Roughly half a second of headroom at 44.1 kHz stereo.
    init(capacityFrames: Int = 22050) {
        capacity = capacityFrames * 2
        buffer = [Float](repeating: 0, count: capacity)
    }

    /// Fraction of the ring currently queued, used by the emulation thread to pace itself.
    var fillRatio: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(filled) / Double(capacity)
    }

    func start(sampleRate: Double) {
        guard !isRunning else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let self else {
                for buffer in ablPointer { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
                return noErr
            }
            let left = ablPointer[0].mData?.assumingMemoryBound(to: Float.self)
            let right = ablPointer.count > 1 ? ablPointer[1].mData?.assumingMemoryBound(to: Float.self) : left

            self.lock.lock()
            let available = min(Int(frameCount), self.filled / 2)
            for frame in 0..<available {
                left?[frame] = self.buffer[self.readIndex]
                right?[frame] = self.buffer[self.readIndex + 1]
                self.readIndex = (self.readIndex + 2) % self.capacity
            }
            self.filled -= available * 2
            self.lock.unlock()

            // Underrun: pad with silence rather than glitching.
            if available < Int(frameCount) {
                for frame in available..<Int(frameCount) {
                    left?[frame] = 0
                    right?[frame] = 0
                }
            }
            return noErr
        }

        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0
        do {
            try engine.start()
            isRunning = true
        } catch {
            NSLog("PS1Sim: audio engine failed to start: \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
        isRunning = false
        lock.lock(); filled = 0; readIndex = 0; writeIndex = 0; lock.unlock()
    }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    /// Called on the emulation thread. Drops the oldest samples if we overrun.
    func enqueue(_ samples: UnsafePointer<Int16>, frames: Int) {
        guard frames > 0 else { return }
        let scale: Float = 1.0 / 32768.0
        lock.lock()
        for index in 0..<(frames * 2) {
            buffer[writeIndex] = Float(samples[index]) * scale
            writeIndex = (writeIndex + 1) % capacity
            if filled < capacity {
                filled += 1
            } else {
                readIndex = (readIndex + 1) % capacity
            }
        }
        lock.unlock()
    }
}

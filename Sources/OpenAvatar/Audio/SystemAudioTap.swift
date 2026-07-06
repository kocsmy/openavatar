import Foundation
#if canImport(CoreAudio) && os(macOS)
import CoreAudio
import AudioToolbox

/// System-audio capture via CoreAudio process taps (macOS 14.4+, spec §4.1).
///
/// Creates a global mixdown tap (all processes' output), wraps it in a private
/// aggregate device, and reads audio via an IOProc. Requires the
/// NSAudioCaptureUsageDescription permission flow.
final class SystemAudioTap {
    typealias SampleHandler = @Sendable (_ samples: [Float], _ sampleRate: Double) -> Void

    private let onSamples: SampleHandler
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var sampleRate: Double = 48_000

    init(onSamples: @escaping SampleHandler) {
        self.onSamples = onSamples
    }

    func start() throws {
        // 1. Global mono mixdown tap of every process (excluding none).
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else {
            throw AppError.audio("AudioHardwareCreateProcessTap failed (\(status)). System-audio capture needs macOS 14.4+ and the Audio Recording permission.")
        }
        tapID = newTapID

        // 2. Read the tap's stream format for the sample rate.
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &format) == noErr {
            sampleRate = format.mSampleRate
        }

        // 3. Private aggregate device containing only the tap.
        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenAvatar Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString]
            ]
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw AppError.audio("AudioHardwareCreateAggregateDevice failed (\(status))")
        }
        aggregateID = newAggregateID

        // 4. IOProc pulls tapped audio.
        let handler = onSamples
        let rate = sampleRate
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inInputData, _, _, _ in
            let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            var mono: [Float] = []
            for buffer in bufferList {
                guard let base = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let floats = base.bindMemory(to: Float.self, capacity: count)
                let channels = max(1, Int(buffer.mNumberChannels))
                if channels == 1 {
                    mono.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
                } else {
                    let frames = count / channels
                    mono.reserveCapacity(mono.count + frames)
                    for f in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<channels { sum += floats[f * channels + c] }
                        mono.append(sum / Float(channels))
                    }
                }
            }
            if !mono.isEmpty { handler(mono, rate) }
        }
        guard status == noErr, let procID = ioProcID else {
            cleanup()
            throw AppError.audio("AudioDeviceCreateIOProcIDWithBlock failed (\(status))")
        }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            cleanup()
            throw AppError.audio("AudioDeviceStart failed (\(status))")
        }
    }

    func stop() {
        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        cleanup()
    }

    private func cleanup() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}
#else
/// Non-macOS placeholder so the target lints elsewhere.
final class SystemAudioTap {
    typealias SampleHandler = @Sendable (_ samples: [Float], _ sampleRate: Double) -> Void
    init(onSamples: @escaping SampleHandler) {}
    func start() throws { throw AppError.audio("System audio capture requires macOS 14.4+") }
    func stop() {}
}
#endif

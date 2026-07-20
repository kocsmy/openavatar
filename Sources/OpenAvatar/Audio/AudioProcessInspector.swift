import Foundation
#if canImport(CoreAudio)
import CoreAudio
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Asks CoreAudio which processes currently have the MICROPHONE open.
/// This is the ground truth for "which app is hosting the call": Zoom holds
/// the mic during Zoom calls, the browser during Meet calls, Slack only
/// during actual huddles — unlike "is the app running", which mislabeled
/// every call as Slack simply because Slack is always open.
/// Uses the same macOS 14.4 CoreAudio process-object API as our audio tap.
enum AudioProcessInspector {

    struct MicActiveApp {
        let bundleID: String
        let name: String
    }

    /// Processes with audio input running right now, excluding ourselves
    /// (we hold the mic whenever we're listening).
    static func micActiveApps() -> [MicActiveApp] {
#if canImport(CoreAudio) && canImport(AppKit)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var objects = [AudioObjectID](repeating: 0,
                                      count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &objects) == noErr else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var found: [MicActiveApp] = []
        for object in objects {
            guard processBool(object, selector: kAudioProcessPropertyIsRunningInput) else { continue }
            let pid = processPID(object)
            guard pid != ownPID else { continue }

            let running = NSRunningApplication(processIdentifier: pid_t(pid))
            let bundleID = running?.bundleIdentifier
                ?? processBundleID(object)
                ?? ""
            let name = running?.localizedName ?? bundleID
            guard !name.isEmpty else { continue }
            found.append(MicActiveApp(bundleID: bundleID, name: name))
        }
        return found
#else
        return []
#endif
    }

#if canImport(CoreAudio)
    private static func processBool(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private static func processPID(_ object: AudioObjectID) -> Int32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Int32 = -1
        var size = UInt32(MemoryLayout<Int32>.size)
        _ = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return value
    }

    private static func processBundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        let s = value as String
        return s.isEmpty ? nil : s
    }
#endif
}

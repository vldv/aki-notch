//
//  CallDetector.swift
//  aki-notch-ui
//
//  Detects whether the user is likely in a call by checking if the
//  system's audio input device (microphone) or camera is currently in use
//  by any application.
//
//  Uses CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere` for the
//  microphone and CoreMediaIO's `kCMIODevicePropertyDeviceIsRunningSomewhere`
//  for the camera. Both are read-only HAL queries that work in sandboxed
//  apps without special entitlements — they don't access media data, just
//  device state.
//

import CoreAudio
import CoreMediaIO
import Foundation
import os

private let logger = Logger(subsystem: "com.aki-notch-ui", category: "CallDetector")

/// Lightweight utility for detecting whether the user is likely on a call.
///
/// Two independent heuristics:
/// - **Microphone**: if the default input device is active, the user is
///   probably in an audio/video call.
/// - **Camera**: if *any* video capture device is active, the user is
///   probably in a video call.
///
/// Either signal alone is a strong indicator.  The caller decides which
/// combination to check (controlled by user settings).
enum CallDetector {

    // MARK: - Microphone

    /// Returns `true` when the default microphone is in use by any application.
    ///
    /// This catches Zoom, Teams, Meet, FaceTime, Slack huddles, Discord,
    /// and any other app that opens an audio input stream — without needing
    /// to maintain a list of bundle identifiers.
    ///
    /// Returns `false` if the device state cannot be queried (e.g. no input
    /// device available), so the caller can safely treat failures as "not in a call".
    static func isMicrophoneInUse() -> Bool {
        // 1. Get the default input device (microphone).
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            logger.warning("Could not get default input device (status: \(status))")
            return false
        }

        // 2. Ask the HAL if *any* process has an active I/O stream on this device.
        //    `kAudioDevicePropertyDeviceIsRunningSomewhere` returns a UInt32 (0 or 1).
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        address.mScope = kAudioObjectPropertyScopeGlobal
        address.mElement = kAudioObjectPropertyElementMain

        var isRunning: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)

        let runStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &isRunning
        )

        guard runStatus == noErr else {
            logger.warning(
                "Could not query isRunningSomewhere for audio device \(deviceID) (status: \(runStatus))"
            )
            return false
        }

        if isRunning != 0 {
            logger.debug("Microphone is in use (device \(deviceID))")
        }

        return isRunning != 0
    }

    // MARK: - Camera

    /// Returns `true` when *any* camera device is in use by any application.
    ///
    /// Enumerates all CoreMediaIO devices and checks each one for an active
    /// stream via `kCMIODevicePropertyDeviceIsRunningSomewhere`.  This mirrors
    /// the CoreAudio approach for the microphone.
    ///
    /// Returns `false` if no cameras are found or the state cannot be queried.
    static func isCameraInUse() -> Bool {
        // 1. Get all CMIODevice IDs.
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var dataSize: UInt32 = 0
        var status = CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )

        guard status == noErr, dataSize > 0 else {
            logger.warning("Could not get CMIO device list size (status: \(status))")
            return false
        }

        let deviceCount = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        guard deviceCount > 0 else { return false }

        var deviceIDs = [CMIODeviceID](repeating: 0, count: deviceCount)
        status = CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            dataSize,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else {
            logger.warning("Could not enumerate CMIO devices (status: \(status))")
            return false
        }

        // 2. Check each device for an active stream.
        for deviceID in deviceIDs {
            var runAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )

            var isRunning: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)

            let runStatus = CMIOObjectGetPropertyData(
                deviceID,
                &runAddress,
                0,
                nil,
                size,
                &size,
                &isRunning
            )

            if runStatus == noErr, isRunning != 0 {
                logger.debug("Camera is in use (CMIO device \(deviceID))")
                return true
            }
        }

        return false
    }
}

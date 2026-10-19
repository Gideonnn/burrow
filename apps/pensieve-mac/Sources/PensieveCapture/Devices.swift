import AVFoundation
import CoreAudio
import Foundation

// CoreAudio property plumbing and the device list, from RecHoarder. Everything
// else that talks to the HAL goes through these.

let system = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
             -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                             mElement: kAudioObjectPropertyElementMain)
}

func propertySize(_ object: AudioObjectID, _ a: AudioObjectPropertyAddress) -> UInt32? {
  var a = a
  var size: UInt32 = 0
  guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr else { return nil }
  return size
}

func propertyString(_ object: AudioObjectID, _ a: AudioObjectPropertyAddress) -> String? {
  var a = a
  var value: CFString? = nil
  var size = UInt32(MemoryLayout<CFString?>.size)
  let status = withUnsafeMutablePointer(to: &value) {
    AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0)
  }
  guard status == noErr, let value else { return nil }
  return value as String
}

func propertyUInt32(_ object: AudioObjectID, _ a: AudioObjectPropertyAddress) -> UInt32? {
  var a = a
  var value: UInt32 = 0
  var size = UInt32(MemoryLayout<UInt32>.size)
  guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr else { return nil }
  return value
}

func propertyFormat(_ object: AudioObjectID, _ a: AudioObjectPropertyAddress) -> AudioStreamBasicDescription? {
  var a = a
  var asbd = AudioStreamBasicDescription()
  var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
  guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &asbd) == noErr else { return nil }
  return asbd
}

func allDeviceIDs() -> [AudioObjectID] {
  let a = address(kAudioHardwarePropertyDevices)
  guard let size = propertySize(system, a), size > 0 else { return [] }
  var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
  var mutable = a
  var used = size
  guard AudioObjectGetPropertyData(system, &mutable, 0, nil, &used, &ids) == noErr else { return [] }
  return ids
}

// Per-buffer channel counts from the stream configuration. An aggregate hands
// its IOProc one buffer per stream in this same order, which is how the
// recorder tells the microphone's buffer from the tap's.
func streamChannels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
  var a = address(kAudioDevicePropertyStreamConfiguration, scope)
  guard let size = propertySize(device, a), size > 0 else { return [] }
  let buffer = UnsafeMutableRawPointer.allocate(
    byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
  defer { buffer.deallocate() }
  var used = size
  guard AudioObjectGetPropertyData(device, &a, 0, nil, &used, buffer) == noErr else { return [] }
  let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
  return list.map { Int($0.mNumberChannels) }
}

func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
  streamChannels(device, scope: scope).reduce(0, +)
}

func fourCC(_ value: UInt32) -> String {
  let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
               UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
  return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
}

func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
  guard let id = propertyUInt32(system, address(selector)), id != 0 else { return nil }
  return AudioObjectID(id)
}

public struct Device: Equatable, Hashable, Sendable {
  public let id: AudioObjectID
  public let uid: String
  public let name: String
  let inputs: Int
  let transport: String

  // Virtual devices (loopbacks, remote-desktop audio) are never a microphone
  // anyone meant to record with, and a leftover aggregate is plumbing.
  var isVirtual: Bool { ["virt", "grup", "ccwd"].contains(transport) }
}

func devices() -> [Device] {
  allDeviceIDs().compactMap { id in
    guard let uid = propertyString(id, address(kAudioDevicePropertyDeviceUID)) else { return nil }
    return Device(id: id, uid: uid,
                  name: propertyString(id, address(kAudioObjectPropertyName)) ?? uid,
                  inputs: channelCount(id, scope: kAudioObjectPropertyScopeInput),
                  transport: fourCC(propertyUInt32(id, address(kAudioDevicePropertyTransportType)) ?? 0))
  }
}

func device(uid: String) -> Device? { devices().first { $0.uid == uid } }

// Headphones first: a microphone next to open speakers hears the far end twice.
private func rank(_ device: Device) -> Int {
  switch device.transport {
  case "blue", "bltE": return 0
  case "usb": return 1
  case "bltn": return 2
  default: return 3
  }
}

public func microphones() -> [Device] {
  devices().filter { $0.inputs > 0 && !$0.isVirtual }
    .sorted { (rank($0), $0.name) < (rank($1), $1.name) }
}

// The system default when it is a real microphone, otherwise the best ranked.
public func preferredMicrophone() -> Device? {
  let real = microphones()
  if let current = defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
     let selected = real.first(where: { $0.id == current }) { return selected }
  return real.first
}

public func requestMicrophoneAccess(_ done: @escaping (Bool) -> Void) {
  switch AVCaptureDevice.authorizationStatus(for: .audio) {
  case .authorized: done(true)
  case .notDetermined:
    AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { done(granted) } }
  default: done(false)
  }
}

public struct CaptureError: Error, LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

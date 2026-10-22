import Carbon.HIToolbox
import Foundation

// A global hot key that reports both press and release, for hold-to-talk
// (Option+Space). Carbon's hot keys need no Accessibility permission and
// swallow the keystroke, so the space never reaches the app underneath.

public final class HoldHotKey {
  public static let optionSpace = (keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

  private var ref: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let id: UInt32
  private let onPress: () -> Void
  private let onRelease: () -> Void
  private static var next: UInt32 = 1
  private struct Weak { weak var hotKey: HoldHotKey? }
  private static var registered: [UInt32: Weak] = [:]

  /// Calls back on the main thread. Fails when another app holds the key.
  public init(
    keyCode: UInt32 = HoldHotKey.optionSpace.keyCode, modifiers: UInt32 = HoldHotKey.optionSpace.modifiers,
    onPress: @escaping () -> Void, onRelease: @escaping () -> Void
  ) throws {
    id = Self.next
    Self.next += 1
    self.onPress = onPress
    self.onRelease = onRelease
    var types = [
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
      var hotKey = EventHotKeyID()
      GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
      guard let found = HoldHotKey.registered[hotKey.id]?.hotKey else { return OSStatus(eventNotHandledErr) }
      if GetEventKind(event) == UInt32(kEventHotKeyPressed) { found.onPress() } else { found.onRelease() }
      return noErr
    }, types.count, &types, nil, &handler)
    guard status == noErr else { throw CaptureError("Kon de sneltoets voor dicteren niet instellen.") }
    let signature = OSType(0x5053_5645) // "PSVE"
    guard RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), 0, &ref) == noErr
    else {
      if let handler { RemoveEventHandler(handler) }
      throw CaptureError("⌥ Spatie is al in gebruik door een andere app.")
    }
    Self.registered[id] = Weak(hotKey: self)
  }

  public func invalidate() {
    if let ref { UnregisterEventHotKey(ref) }
    if let handler { RemoveEventHandler(handler) }
    ref = nil
    handler = nil
    Self.registered[id] = nil
  }

  deinit { invalidate() }
}

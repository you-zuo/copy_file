import Cocoa
import FlutterMacOS
import IOKit.pwr_mgt

final class SleepBlockerChannel: NSObject {
  private static let shared = SleepBlockerChannel()
  private static let pluginName = "SleepBlockerChannel"
  private static let channelName = "copy_file/sleep_blocker"

  private var assertionID: IOPMAssertionID = 0
  private var isActive = false

  static func register(with registry: FlutterPluginRegistry) {
    let registrar = registry.registrar(forPlugin: pluginName)
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger
    )

    channel.setMethodCallHandler { call, result in
      shared.handle(call: call, result: result)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "setActive" else {
      result(FlutterMethodNotImplemented)
      return
    }

    guard
      let arguments = call.arguments as? [String: Any],
      let active = arguments["active"] as? Bool
    else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "Missing active state",
          details: nil
        )
      )
      return
    }

    do {
      if active {
        try activate()
      } else {
        deactivate()
      }
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "sleep_blocker_error",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func activate() throws {
    if isActive {
      return
    }

    let reason = "Copy File has active copy tasks" as CFString
    let status = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      reason,
      &assertionID
    )

    guard status == kIOReturnSuccess else {
      throw SleepBlockerError.assertionFailed(code: status)
    }

    isActive = true
  }

  private func deactivate() {
    guard isActive else {
      return
    }

    IOPMAssertionRelease(assertionID)
    assertionID = 0
    isActive = false
  }
}

private enum SleepBlockerError: LocalizedError {
  case assertionFailed(code: IOReturn)

  var errorDescription: String? {
    switch self {
    case .assertionFailed(let code):
      return "Failed to create sleep prevention assertion (\(code))"
    }
  }
}

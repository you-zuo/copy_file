import Cocoa
import FlutterMacOS

final class SecurityScopedBookmarkChannel: NSObject {
  private static let shared = SecurityScopedBookmarkChannel()
  private static let pluginName = "SecurityScopedBookmarkChannel"
  private static let channelName = "copy_file/security_scoped_bookmarks"

  private var activeResources: [String: URL] = [:]

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
    guard let arguments = call.arguments as? [String: Any] else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "Missing method arguments",
          details: nil
        )
      )
      return
    }

    do {
      switch call.method {
      case "createBookmark":
        guard let path = arguments["path"] as? String else {
          throw BookmarkError.invalidPath
        }

        let url = URL(fileURLWithPath: path)
        let bookmark = try url.bookmarkData(
          options: .withSecurityScope,
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
        result(bookmark.base64EncodedString())
      case "startAccess":
        guard let encodedBookmark = arguments["bookmark"] as? String else {
          throw BookmarkError.invalidBookmark
        }

        guard let bookmarkData = Data(base64Encoded: encodedBookmark) else {
          throw BookmarkError.invalidBookmark
        }

        var isStale = false
        let url = try URL(
          resolvingBookmarkData: bookmarkData,
          options: .withSecurityScope,
          relativeTo: nil,
          bookmarkDataIsStale: &isStale
        )

        guard url.startAccessingSecurityScopedResource() else {
          throw BookmarkError.startAccessFailed
        }

        let token = UUID().uuidString
        activeResources[token] = url
        result(token)
      case "stopAccess":
        guard let token = arguments["token"] as? String else {
          throw BookmarkError.invalidToken
        }

        if let url = activeResources.removeValue(forKey: token) {
          url.stopAccessingSecurityScopedResource()
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(
        FlutterError(
          code: "bookmark_error",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }
}

private enum BookmarkError: LocalizedError {
  case invalidPath
  case invalidBookmark
  case invalidToken
  case startAccessFailed

  var errorDescription: String? {
    switch self {
    case .invalidPath:
      return "Invalid directory path"
    case .invalidBookmark:
      return "Invalid security scoped bookmark"
    case .invalidToken:
      return "Invalid access token"
    case .startAccessFailed:
      return "Failed to restore directory access"
    }
  }
}

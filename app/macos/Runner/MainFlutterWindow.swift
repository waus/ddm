import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var appMenuChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let appMenuChannel = FlutterMethodChannel(
      name: "ddm/app_menu",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    self.appMenuChannel = appMenuChannel
    installMessageMenuItem()

    let filePickerChannel = FlutterMethodChannel(
      name: "ddm/file_picker",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    filePickerChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "pickExternalStorageSyncFile" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let initialUrl = arguments["initialUrl"] as? String
      else {
        result(FlutterError(
          code: "bad-arguments",
          message: "initialUrl is required",
          details: nil))
        return
      }
      self?.pickExternalStorageSyncFile(initialUrl: initialUrl, result: result)
    }

    super.awakeFromNib()
  }

  private func installMessageMenuItem() {
    guard let mainMenu = NSApplication.shared.mainMenu else {
      return
    }

    let messageMenu: NSMenu
    if let existing = mainMenu.item(withTitle: "Message") {
      messageMenu = existing.submenu ?? NSMenu(title: "Message")
      existing.submenu = messageMenu
    } else {
      messageMenu = NSMenu(title: "Message")
      let messageMenuItem = NSMenuItem(title: "Message", action: nil, keyEquivalent: "")
      messageMenuItem.submenu = messageMenu
      mainMenu.insertItem(messageMenuItem, at: min(1, mainMenu.numberOfItems))
    }

    if messageMenu.items.contains(where: { $0.action == #selector(newMessageMenuItemSelected(_:)) }) {
      return
    }

    let newMessageItem = NSMenuItem(
      title: "New Message",
      action: #selector(newMessageMenuItemSelected(_:)),
      keyEquivalent: "n")
    newMessageItem.keyEquivalentModifierMask = [.command]
    newMessageItem.target = self
    messageMenu.addItem(newMessageItem)
  }

  @objc private func newMessageMenuItemSelected(_ sender: Any?) {
    appMenuChannel?.invokeMethod("newMessage", arguments: nil)
  }

  private func pickExternalStorageSyncFile(
    initialUrl: String,
    result: @escaping FlutterResult
  ) {
    guard let fileUrl = URL(string: initialUrl), fileUrl.isFileURL else {
      result(FlutterError(
        code: "bad-url",
        message: "initialUrl must be a file URL",
        details: nil))
      return
    }

    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedFileTypes = ["sqlite"]
    panel.directoryURL = fileUrl.deletingLastPathComponent()
    panel.nameFieldStringValue = fileUrl.lastPathComponent
    panel.message = "Choose ddm-sync.sqlite to grant DDM access."

    panel.beginSheetModal(for: self) { response in
      guard response == .OK, let url = panel.url else {
        result(nil)
        return
      }
      result(url.absoluteString)
    }
  }
}

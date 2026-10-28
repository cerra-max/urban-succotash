// 无边记 · 思维画布 —— macOS 本地 App 外壳
// 用 WKWebView 加载 Resources/web/index.html，并通过 window.webkit.messageHandlers.wbj 提供：
//   read / write / remove   读写 ~/Library/Application Support/Wubianji 下的画板数据
//   saveFile / openFile     系统的存储、打开面板
//   setTitle                窗口标题
import Cocoa
import WebKit
import UniformTypeIdentifiers

let dataDir: URL = {
  let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  let dir = base.appendingPathComponent("Wubianji", isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}()

final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
  weak var window: NSWindow?
  // 只允许直接写入用户在面板中选择过、或从访达打开的文件
  var allowedPaths = Set<String>()

  func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage,
                             replyHandler: @escaping (Any?, String?) -> Void) {
    guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
      return replyHandler(nil, "无效的消息")
    }
    switch op {
    case "read":
      guard let url = dataFile(body["name"]) else { return replyHandler(nil, "无效的文件名") }
      replyHandler(try? String(contentsOf: url, encoding: .utf8), nil)
    case "write":
      guard let url = dataFile(body["name"]), let text = body["text"] as? String else { return replyHandler(nil, "无效的参数") }
      do { try text.write(to: url, atomically: true, encoding: .utf8); replyHandler(true, nil) }
      catch { replyHandler(nil, error.localizedDescription) }
    case "remove":
      guard let url = dataFile(body["name"]) else { return replyHandler(nil, "无效的文件名") }
      try? FileManager.default.removeItem(at: url)
      replyHandler(true, nil)
    case "setTitle":
      window?.title = (body["title"] as? String) ?? "无边记"
      replyHandler(true, nil)
    case "saveFile":
      saveFile(body, replyHandler)
    case "openFile":
      openFile(replyHandler)
    default:
      replyHandler(nil, "未知操作 \(op)")
    }
  }

  private func dataFile(_ name: Any?) -> URL? {
    guard let s = name as? String, !s.hasPrefix("."),
          s.range(of: "^[A-Za-z0-9._-]{1,80}$", options: .regularExpression) != nil else { return nil }
    return dataDir.appendingPathComponent(s)
  }

  private func saveFile(_ body: [String: Any], _ reply: @escaping (Any?, String?) -> Void) {
    let data: Data
    if let t = body["text"] as? String { data = Data(t.utf8) }
    else if let b = body["base64"] as? String, let d = Data(base64Encoded: b) { data = d }
    else { return reply(nil, "没有可保存的内容") }

    let write = { (url: URL) in
      do {
        try data.write(to: url, options: .atomic)
        self.allowedPaths.insert(url.path)
        reply(url.path, nil)
      } catch { reply(nil, error.localizedDescription) }
    }
    if let p = body["path"] as? String, allowedPaths.contains(p) { return write(URL(fileURLWithPath: p)) }

    let name = (body["name"] as? String) ?? "未命名"
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    let ext = (name as NSString).pathExtension
    if !ext.isEmpty, let t = UTType(filenameExtension: ext) { panel.allowedContentTypes = [t] }
    let done = { (r: NSApplication.ModalResponse) in
      if r == .OK, let url = panel.url { write(url) } else { reply(nil, nil) }
    }
    if let w = window { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
  }

  private func openFile(_ reply: @escaping (Any?, String?) -> Void) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [UTType(filenameExtension: "wbj") ?? .json, .json]
    let done = { (r: NSApplication.ModalResponse) in
      guard r == .OK, let url = panel.url else { return reply(nil, nil) }
      do { reply(try self.fileInfo(url), nil) } catch { reply(nil, error.localizedDescription) }
    }
    if let w = window { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
  }

  func fileInfo(_ url: URL) throws -> [String: String] {
    let text = try String(contentsOf: url, encoding: .utf8)
    allowedPaths.insert(url.path)
    return ["name": url.lastPathComponent, "text": text, "path": url.path]
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
  var window: NSWindow!
  var webView: WKWebView!
  let bridge = Bridge()
  var loaded = false
  var pendingOpen: [URL] = []

  func applicationDidFinishLaunching(_ note: Notification) {
    buildMenu()

    let config = WKWebViewConfiguration()
    config.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "wbj")
    webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    if #available(macOS 13.3, *) { webView.isInspectable = true }

    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                      backing: .buffered, defer: false)
    window.title = "无边记"
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 640, height: 460)
    window.tabbingMode = .disallowed
    window.contentView = webView
    window.delegate = self
    window.center()
    window.setFrameAutosaveName("main")
    bridge.window = window

    let web = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)
    webView.loadFileURL(web.appendingPathComponent("index.html"), allowingReadAccessTo: web)

    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  // 在访达中双击 .wbj 文件
  func application(_ app: NSApplication, open urls: [URL]) {
    if loaded { urls.forEach(openInPage) } else { pendingOpen += urls }
  }

  private func openInPage(_ url: URL) {
    guard let info = try? bridge.fileInfo(url) else { return }
    webView.callAsyncJavaScript("await window.wbjOpenText(name, text, path)",
                                arguments: ["name": info["name"]!, "text": info["text"]!, "path": info["path"]!],
                                in: nil, in: .page, completionHandler: nil)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

  // 退出前等页面把未保存的修改写入磁盘
  func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
    guard loaded else { return .terminateNow }
    var replied = false
    let finish = { if !replied { replied = true; NSApp.reply(toApplicationShouldTerminate: true) } }
    webView.callAsyncJavaScript("return await (window.wbjFlush ? window.wbjFlush() : true)",
                                arguments: [:], in: nil, in: .page) { _ in finish() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: finish)
    return .terminateLater
  }

  // MARK: 网页
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    loaded = true
    pendingOpen.forEach(openInPage)
    pendingOpen = []
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = action.request.url else { return decisionHandler(.cancel) }
    if url.isFileURL || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" {
      return decisionHandler(.allow)
    }
    // 外部链接交给默认浏览器
    NSWorkspace.shared.open(url)
    decisionHandler(.cancel)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
    let a = NSAlert(); a.messageText = message
    a.beginSheetModal(for: window) { _ in completionHandler() }
  }

  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
    let a = NSAlert(); a.messageText = message
    a.addButton(withTitle: "确定"); a.addButton(withTitle: "取消")
    a.beginSheetModal(for: window) { r in completionHandler(r == .alertFirstButtonReturn) }
  }

  // <input type="file">（插入图片）
  func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    panel.canChooseDirectories = false
    panel.beginSheetModal(for: window) { r in completionHandler(r == .OK ? panel.urls : nil) }
  }

  // MARK: 菜单
  @objc func command(_ sender: NSMenuItem) {
    guard let cmd = sender.representedObject as? String else { return }
    webView.callAsyncJavaScript("window.wbjCommand && window.wbjCommand(cmd)", arguments: ["cmd": cmd],
                                in: nil, in: .page, completionHandler: nil)
  }

  @objc func showDataFolder(_ sender: Any?) { NSWorkspace.shared.open(dataDir) }

  private func item(_ title: String, _ cmd: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
    let it = NSMenuItem(title: title, action: #selector(command(_:)), keyEquivalent: key)
    it.keyEquivalentModifierMask = mods
    it.representedObject = cmd
    it.target = self
    return it
  }

  private func std(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
    let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
    it.keyEquivalentModifierMask = mods
    return it
  }

  private func buildMenu() {
    let main = NSMenu()
    func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
      let m = NSMenu(title: title)
      items.forEach(m.addItem)
      let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      top.submenu = m
      main.addItem(top)
      return m
    }
    _ = add("无边记", [
      std("关于 无边记", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
      .separator(),
      { let i = NSMenuItem(title: "在访达中显示数据文件夹", action: #selector(showDataFolder(_:)), keyEquivalent: ""); i.target = self; return i }(),
      .separator(),
      std("隐藏 无边记", #selector(NSApplication.hide(_:)), "h"),
      std("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
      std("全部显示", #selector(NSApplication.unhideAllApplications(_:)), ""),
      .separator(),
      std("退出 无边记", #selector(NSApplication.terminate(_:)), "q"),
    ])
    _ = add("文件", [
      item("新建画板", "newBoard", "n"),
      item("打开…", "open", "o"),
      .separator(),
      item("保存", "save", "s"),
      item("另存为…", "saveAs", "s", [.command, .shift]),
      .separator(),
      item("导出为 PNG 图片…", "exportPNG", "e", [.command, .shift]),
      item("导出为 SVG 矢量图…", "exportSVG"),
      item("导出思维导图大纲（Markdown）…", "exportMD"),
      .separator(),
      item("多人协作…", "share", "k", [.command, .shift]),
      .separator(),
      std("关闭窗口", #selector(NSWindow.performClose(_:)), "w"),
    ])
    _ = add("编辑", [
      item("撤销", "undo", "z"),
      item("重做", "redo", "z", [.command, .shift]),
      .separator(),
      std("剪切", #selector(NSText.cut(_:)), "x"),
      std("拷贝", #selector(NSText.copy(_:)), "c"),
      std("粘贴", #selector(NSText.paste(_:)), "v"),
      item("复制一份", "duplicate", "d"),
      item("删除", "deleteSel"),
      std("全选", #selector(NSText.selectAll(_:)), "a"),
      .separator(),
      item("插入图片…", "insertImage", "i", [.command, .shift]),
    ])
    _ = add("显示", [
      item("放大", "zoomIn", "="),
      item("缩小", "zoomOut", "-"),
      item("实际大小", "zoom100", "0"),
      item("适应画布", "fit", "1"),
      .separator(),
      item("显示 / 隐藏画板列表", "sidebar", "b", [.command, .control]),
      .separator(),
      std("进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
    ])
    let win = add("窗口", [
      std("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"),
      std("缩放", #selector(NSWindow.performZoom(_:)), ""),
    ])
    _ = add("帮助", [item("快捷键与帮助", "help", "/", [.command, .shift])])
    NSApp.mainMenu = main
    NSApp.windowsMenu = win
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

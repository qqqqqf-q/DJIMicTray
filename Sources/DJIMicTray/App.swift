import AppKit
import Combine
import SwiftUI

@main
struct DJIMicTrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 菜单栏入口由 AppDelegate 里的 NSStatusItem 提供，这里不需要任何窗口
        Settings { EmptyView() }
    }
}

/// 不用 SwiftUI 的 MenuBarExtra(.window)：它的窗口只在弹出时定一次尺寸，之后展开设置、连上设备等
/// 内容高度变化不会跟着调整，内容会被上下裁掉。NSPopover 会跟随 preferredContentSize 实时调整。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mic = MicController()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        let host = NSHostingController(rootView: MenuView(mic: mic))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient

        updateIcon()
        // objectWillChange 在值变化前触发，下一轮主循环再读最新状态
        cancellable = mic.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateIcon() {
        let name = mic.isRecording ? "record.circle.fill" : mic.isConnected ? "mic.fill" : "mic"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "DJI Mic")
        image?.isTemplate = true
        statusItem.button?.image = image
    }
}

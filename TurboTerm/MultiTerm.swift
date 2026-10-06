import Foundation
import SwiftUI
import Combine

/// 一个终端窗格: 独立的控制器 + 独立的后端 + 独立渲染
final class TerminalPane: Identifiable, ObservableObject {
    let id = UUID()
    var name: String
    let controller: TerminalController
    private let backend: BuiltinShell

    init(name: String) {
        self.name = name
        self.controller = TerminalController(cols: 80, rows: 24)
        self.backend = BuiltinShell()
        controller.start(backend: backend)
    }

    func stop() {
        backend.stop()
    }
}

/// 多开管理器:
/// - panes[0] 永远是主窗口 (最左边)
/// - 主窗口的输入可广播到所有窗口 (broadcast 开关)
final class PaneManager: ObservableObject {
    @Published var panes: [TerminalPane] = []
    @Published var broadcast = true
    @Published var paneCount = 1
    @Published var settings = TermSettings()

    private var nameCounter = 1

    init() {
        syncPanes()
    }

    var master: TerminalPane? { panes.first }

    /// 按 paneCount 同步窗格数量 (1~6)
    func syncPanes() {
        let n = min(max(paneCount, 1), 6)
        paneCount = n
        while panes.count < n {
            let name = panes.isEmpty ? "主" : "窗口\(nameCounter + 1)"
            nameCounter += 1
            let pane = TerminalPane(name: name)
            pane.controller.applySettings(settings)
            panes.append(pane)
        }
        while panes.count > n {
            let pane = panes.removeLast()
            pane.stop()
        }
        applySettingsToAll()
    }

    func removePane(_ pane: TerminalPane) {
        guard panes.count > 1, pane.id != master?.id else { return }
        pane.stop()
        panes.removeAll { $0.id == pane.id }
        paneCount = panes.count
    }

    /// 主窗口输入: 发给主窗口, 广播开时重复发给所有多开窗口
    func sendToMaster(_ text: String) {
        guard let m = master else { return }
        m.controller.send(text)
        if broadcast {
            for p in panes.dropFirst() {
                p.controller.send(text)
            }
        }
    }

    func sendBytesToMaster(_ bytes: [UInt8]) {
        guard let m = master else { return }
        m.controller.sendBytes(bytes)
        if broadcast {
            for p in panes.dropFirst() {
                p.controller.sendBytes(bytes)
            }
        }
    }

    /// 设置应用到所有窗格 (主线程调用)
    func applySettingsToAll() {
        for (i, p) in panes.enumerated() {
            // panes[0] 是主窗口; 其他窗口恒为省电模式 (1fps + 160p)
            p.controller.isMasterPane = (i == 0)
            p.controller.applySettings(settings)
        }
    }
}

import SwiftUI

struct ContentView: View {
    @StateObject private var manager = PaneManager()
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            paneTabs
            paneArea
            Divider()
            keyRow
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(manager: manager)
        }
    }

    // MARK: - 窗格标签栏

    private var paneTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(manager.panes) { pane in
                    HStack(spacing: 4) {
                        Text(pane.name + (pane.id == manager.master?.id ? " ·主" : ""))
                            .font(.system(size: 12, design: .monospaced))
                        if pane.id != manager.master?.id {
                            Button("×") { manager.removePane(pane) }
                                .font(.system(size: 14, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)
                }
                Button("+ 多开") {
                    withAnimation {
                        manager.paneCount += 1
                        manager.syncPanes()
                    }
                }
                .buttonStyle(.bordered)
                .font(.system(size: 12))
                .disabled(manager.panes.count >= 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    // MARK: - 窗格区域 (终端本身就是输入框: 点一下弹键盘直接打字)

    private var paneArea: some View {
        Group {
            if manager.panes.count == 1, let pane = manager.panes.first {
                TerminalMetalView(
                    controller: pane.controller,
                    onTextInput: { manager.sendToMaster($0) },
                    onDelete: { manager.sendBytesToMaster([0x7F]) }
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 6),
                                  GridItem(.flexible(), spacing: 6)],
                        spacing: 6
                    ) {
                        ForEach(manager.panes) { pane in
                            VStack(spacing: 2) {
                                Text(pane.name + (pane.id == manager.master?.id ? " · 主输入" : " · 1fps/160p"))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                TerminalMetalView(
                                    controller: pane.controller,
                                    onTextInput: { manager.sendToMaster($0) },
                                    onDelete: { manager.sendBytesToMaster([0x7F]) }
                                )
                                    .frame(height: 250)
                                    .cornerRadius(6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                    )
                            }
                        }
                    }
                    .padding(6)
                }
            }
        }
    }

    // MARK: - 快捷键行 (下方菜单)

    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button("⚙️") { showSettings = true }
                    .buttonStyle(.bordered)
                Button("A−") { adjustFont(-1) }
                    .buttonStyle(.bordered)
                    .font(.system(size: 14, design: .monospaced))
                Button("A＋") { adjustFont(1) }
                    .buttonStyle(.bordered)
                    .font(.system(size: 14, design: .monospaced))
                KeyButton("Tab") { manager.sendBytesToMaster([0x09]) }
                KeyButton("Esc") { manager.sendBytesToMaster([0x1B]) }
                KeyButton("^C") { manager.sendBytesToMaster([0x03]) }
                KeyButton("↑") { manager.sendBytesToMaster([0x1B, 0x5B, 0x41]) }
                KeyButton("↓") { manager.sendBytesToMaster([0x1B, 0x5B, 0x42]) }
                KeyButton("←") { manager.sendBytesToMaster([0x1B, 0x5B, 0x44]) }
                KeyButton("→") { manager.sendBytesToMaster([0x1B, 0x5B, 0x43]) }
                KeyButton("广播\(manager.broadcast ? "开" : "关")") {
                    manager.broadcast.toggle()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(UIColor.secondarySystemBackground))
    }

    private func adjustFont(_ d: CGFloat) {
        manager.settings.fontSize = min(max(manager.settings.fontSize + d, 10), 24)
        manager.applySettingsToAll()
    }
}

private struct KeyButton: View {
    let label: String
    let action: () -> Void

    init(_ label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(label, action: action)
            .buttonStyle(.bordered)
            .font(.system(size: 14, design: .monospaced))
    }
}

// MARK: - 设置页: 字体 / 分辨率 / 帧率 / 性能 / 回滚 / 多开

struct SettingsView: View {
    @ObservedObject var manager: PaneManager

    var body: some View {
        NavigationView {
            Form {
                Section("字体") {
                    Stepper("字体大小: \(Int(manager.settings.fontSize))pt",
                            value: $manager.settings.fontSize,
                            in: CGFloat(10)...CGFloat(24), step: 1)
                    Picker("字体分辨率", selection: $manager.settings.renderScale) {
                        Text("低 1x").tag(CGFloat(1))
                        Text("中 2x").tag(CGFloat(2))
                        Text("高 3x").tag(CGFloat(3))
                    }
                    .pickerStyle(.segmented)
                    Text("分辨率只影响字形烘焙清晰度, 不影响运行逻辑。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("性能") {
                    Picker("帧率上限", selection: $manager.settings.fps) {
                        Text("60").tag(60)
                        Text("120").tag(120)
                    }
                    .pickerStyle(.segmented)
                    Toggle("性能模式", isOn: $manager.settings.perfMode)
                    Text("性能模式: 主窗口锁 10fps + 最低分辨率; 多开窗口恒为 1fps + 160p。数据一字不丢。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Picker("回滚行数", selection: $manager.settings.scrollbackCap) {
                        Text("关").tag(0)
                        Text("1000").tag(1000)
                        Text("2000").tag(2000)
                        Text("5000").tag(5000)
                    }
                    .pickerStyle(.segmented)
                }

                Section("多开") {
                    Stepper("窗口数: \(manager.paneCount)",
                            value: $manager.paneCount, in: 1...6)
                    Toggle("主窗口输入广播到所有窗口", isOn: $manager.broadcast)
                    Text("在主窗口(最左边)输入的命令会自动重复发给所有窗口。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("多开窗口恒为 1fps / 160p 省电模式，几乎不占 GPU。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("压力测试") {
                    Text("主窗口输入 burst 10000 回车: 一瞬间推送 10,000 条消息。")
                        .font(.footnote)
                    Text("多开 4 窗 + 广播开 + burst: 四窗口同时冲击。")
                        .font(.footnote)
                }
            }
            .navigationTitle("终端设置")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: manager.settings) { _ in
            manager.applySettingsToAll()
        }
        .onChange(of: manager.paneCount) { _ in
            manager.syncPanes()
        }
    }
}

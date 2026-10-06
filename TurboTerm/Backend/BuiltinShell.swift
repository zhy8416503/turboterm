import Foundation

/// 内置演示 Shell: 不依赖任何外部进程, 所有命令都在 App 内执行。
/// 包含高频文字压力测试命令: bounce / matrix / yes / bench,
/// 用来验证渲染管线在高频率文字跳动下的表现。
final class BuiltinShell: TerminalBackend {

    private var onData: ((Data) -> Void)?
    private let workQ = DispatchQueue(label: "turboterm.shell", qos: .userInitiated)
    private let lock = NSLock()

    private var lineBuf: [UInt8] = []
    private var currentJob: UUID? = nil
    private var cancelledJobs = Set<UUID>()

    private let prompt = "turbo$ "

    // MARK: - TerminalBackend

    func start(onData: @escaping (Data) -> Void) {
        self.onData = onData
        emit(banner())
        emit(prompt)
    }

    func stop() {
        cancelJob()
    }

    func send(_ data: Data) {
        workQ.async { [weak self] in
            guard let self = self else { return }
            for b in data {
                self.handleInputByte(b)
            }
        }
    }

    // MARK: - 输入

    private func handleInputByte(_ b: UInt8) {
        // Ctrl-C: 取消当前任务
        if b == 0x03 {
            lock.lock()
            let hasJob = currentJob != nil
            lock.unlock()
            if hasJob {
                cancelJob()
                emit("^C\r\n" + prompt)
            } else {
                emit("^C\r\n" + prompt)
            }
            lineBuf.removeAll()
            return
        }
        // 有任务在跑时, 普通输入直接忽略 (除了 Ctrl-C)
        lock.lock()
        let busy = currentJob != nil
        lock.unlock()
        if busy { return }

        switch b {
        case 0x0D, 0x0A: // 回车
            let line = String(bytes: lineBuf, encoding: .utf8) ?? ""
            lineBuf.removeAll()
            emit(line + "\r\n")
            runCommand(line)
        case 0x7F, 0x08: // 退格
            if !lineBuf.isEmpty {
                lineBuf.removeLast()
                emit("\u{8} \u{8}")
            }
        case 0x1B:
            break // 裸 ESC 忽略 (方向键等序列由命令自己处理, 这里简化)
        default:
            if b >= 0x20 || b >= 0x80 {
                lineBuf.append(b)
                emit(String(bytes: [b], encoding: .utf8) ?? "")
            }
        }
    }

    // MARK: - 输出

    private func emit(_ s: String) {
        if let d = s.data(using: .utf8) { onData?(d) }
    }

    private func emit(_ d: Data) { onData?(d) }

    // MARK: - 任务管理

    /// 启动一个可取消的长时间任务, 返回 job id
    private func beginJob() -> UUID {
        let id = UUID()
        lock.lock()
        currentJob = id
        lock.unlock()
        return id
    }

    private func jobCancelled(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledJobs.contains(id)
    }

    private func endJob(_ id: UUID, showPrompt: Bool = true) {
        lock.lock()
        if currentJob == id { currentJob = nil }
        cancelledJobs.remove(id)
        lock.unlock()
        if showPrompt { emit("\r\n" + prompt) }
    }

    private func cancelJob() {
        lock.lock()
        if let id = currentJob { cancelledJobs.insert(id); currentJob = nil }
        lock.unlock()
    }

    // MARK: - 命令分发

    private func runCommand(_ line: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let cmd = parts.first?.lowercased() else { emit(prompt); return }
        let args = Array(parts.dropFirst())
        switch cmd {
        case "help": cmdHelp()
        case "echo": emit(args.joined(separator: " ") + "\r\n" + prompt)
        case "clear": emit("\u{1B}[2J\u{1B}[H" + prompt)
        case "sleep":
            let n = Double(args.first ?? "1") ?? 1
            Thread.sleep(forTimeInterval: min(max(n, 0), 30))
            emit(prompt)
        case "yes": cmdYes(args)
        case "burst": cmdBurst(args)
        case "bounce": cmdBounce(args)
        case "matrix": cmdMatrix(args)
        case "bench": cmdBench(args)
        case "colors": cmdColors()
        case "title": emit("\u{1B}]2;\(args.joined(separator: " "))\u{7}" + prompt)
        case "exit", "quit": emit("内置 shell 没有退出, 关掉 App 即可 🙂\r\n" + prompt)
        case "": emit(prompt)
        default: emit("未知命令: \(cmd)  (输入 help 查看)\r\n" + prompt)
        }
    }

    private func cmdHelp() {
        emit("""
        内置命令:
          help              显示本帮助
          echo <文字>        回显
          clear             清屏
          sleep <秒>         等待
          colors            256 色测试
          title <文字>       设置终端标题
          yes [文字]        高速无限输出 (Ctrl-C 停止) —— 滚动压力测试
          burst [条数]       一瞬间推送 N 条消息 (默认 10000) —— 瞬时冲击测试
          bounce [文字] [hz] 文字波浪跳动, 默认 60Hz —— 高频跳动测试
          matrix [hz]       黑客帝国字符雨 —— 全屏高频重绘测试
          bench [行数]       吞吐量测试, 输出 N 行并报告行/秒
        快捷键: 右下角 ^C 可随时中断长时间任务
        \r\n
        """ + prompt)
    }

    // MARK: - 高频演示命令

    /// yes: 无限高速输出, 测试滚动与解析吞吐
    private func cmdYes(_ args: [String]) {
        let text = args.isEmpty ? "y" : args.joined(separator: " ")
        let id = beginJob()
        workQ.async { [weak self] in
            guard let self = self else { return }
            var i = 0
            // 按块输出, 减少回调次数, 让解析器批量吃数据
            while !self.jobCancelled(id) {
                var chunk = ""
                chunk.reserveCapacity(64 * 1024)
                for _ in 0..<2000 {
                    i += 1
                    chunk += "\(text) \(i)\r\n"
                }
                self.emit(chunk)
            }
            self.endJob(id)
        }
    }

    /// bounce: 文字波浪跳动 —— 每帧全屏重写, 默认 60Hz
    /// 这就是你要的"高频率字体跳动": 数据推送频率 >> 屏幕刷新率时,
    /// 脏行合并保证每帧只画一次, 不会掉帧也不会撕裂。
    private func cmdBounce(_ args: [String]) {
        let text = args.first ?? "TURBO◆霓虹"
        let hz = min(max(Double(args.dropFirst().first ?? "60") ?? 60, 1), 240)
        let id = beginJob()
        workQ.async { [weak self] in
            guard let self = self else { return }
            let cols = 60, bandRows = 12, baseRow = 6
            let chars = Array(text)
            self.emit("\u{1B}[?25l")  // 藏光标
            let t0 = Date()
            var frames = 0
            let interval = 1.0 / hz
            while !self.jobCancelled(id) {
                let f0 = Date()
                var out = "\u{1B}[H"  // 回到左上角
                let t = Date().timeIntervalSince(t0)
                // 背景行
                for r in 0..<bandRows + 2 {
                    var line = ""
                    for c in 0..<cols {
                        let wave = sin(t * 6.0 + Double(c) * 0.35) * Double(bandRows / 2 - 1)
                        let targetRow = baseRow + Int(round(wave))
                        if r == targetRow - 2 && c < chars.count * 3 {
                            let ch = chars[(c / 3) % chars.count]
                            // 霓虹渐变色
                            let hue = (c * 7 + frames * 3) % 216 + 16
                            line += "\u{1B}[38;5;\(hue)m\(ch)\u{1B}[0m"
                        } else {
                            line += " "
                        }
                    }
                    // 去掉行尾空格, 减少传输量
                    while line.hasSuffix(" ") { line.removeLast() }
                    out += line + "\r\n"
                }
                // 状态行
                let elapsed = Date().timeIntervalSince(t0)
                let fps = elapsed > 0 ? Double(frames) / elapsed : 0
                out += String(format: "\u{1B}[38;5;240mframe %d  %.1f fps  (Ctrl-C 停止)\u{1B}[0m", frames, fps)
                //  padding 到行尾防止残留
                out += String(repeating: " ", count: max(0, cols - 40))
                self.emit(out)
                frames += 1
                let spent = Date().timeIntervalSince(f0)
                if spent < interval { Thread.sleep(forTimeInterval: interval - spent) }
            }
            self.emit("\u{1B}[?25h")  // 恢复光标
            self.endJob(id)
        }
    }

    /// matrix: 字符雨 —— 每帧全屏随机重绘
    private func cmdMatrix(_ args: [String]) {
        let hz = min(max(Double(args.first ?? "30") ?? 30, 1), 120)
        let id = beginJob()
        workQ.async { [weak self] in
            guard let self = self else { return }
            let cols = 50, rows = 18
            let glyphs = Array("アイカ0123456789XYZ$#*+=:")
            var drops = [Int](repeating: 0, count: cols)
            var speeds = [Int](repeating: 1, count: cols)
            for c in 0..<cols { drops[c] = Int.random(in: 0..<rows); speeds[c] = Int.random(in: 1...3) }
            self.emit("\u{1B}[?25l\u{1B}[2J")
            let interval = 1.0 / hz
            var tick = 0
            while !self.jobCancelled(id) {
                let f0 = Date()
                var out = "\u{1B}[H\u{1B}[38;5;46m"
                for r in 0..<rows {
                    var line = ""
                    for c in 0..<cols {
                        let head = drops[c]
                        if r == head {
                            line += "\u{1B}[38;5;159m\(glyphs.randomElement()!)\u{1B}[38;5;46m"
                        } else if r == head - 1 || r == head - 2 {
                            line += "\(glyphs.randomElement()!)"
                        } else {
                            line += " "
                        }
                    }
                    while line.hasSuffix(" ") { line.removeLast() }
                    out += line + "\r\n"
                }
                self.emit(out)
                tick += 1
                if tick % 2 == 0 {
                    for c in 0..<cols {
                        drops[c] += speeds[c]
                        if drops[c] - 3 > rows {
                            drops[c] = 0
                            speeds[c] = Int.random(in: 1...3)
                        }
                    }
                }
                let spent = Date().timeIntervalSince(f0)
                if spent < interval { Thread.sleep(forTimeInterval: interval - spent) }
            }
            self.emit("\u{1B}[?25h\u{1B}[0m")
            self.endJob(id)
        }
    }

    /// burst: 一瞬间推送 N 条消息 —— 模拟 10k 条/秒的消息冲击
    /// 数据一次性进解析器, 脏行合并 + vsync 节流保证界面不卡, 数据一字不丢
    private func cmdBurst(_ args: [String]) {
        let n = min(max(Int(args.first ?? "10000") ?? 10000, 1), 200000)
        let id = beginJob()
        workQ.async { [weak self] in
            guard let self = self else { return }
            var data = Data()
            data.reserveCapacity(n * 48)
            for i in 0..<n {
                if self.jobCancelled(id) { break }
                data.append(contentsOf: "burst msg \(i) ▓▒░ 跳动测试\r\n".utf8)
            }
            let t0 = Date()
            self.emit(data)
            let dt = Date().timeIntervalSince(t0)
            self.emit(String(format: "\r\n已推送 %d 条, 推送耗时 %.3f 秒\r\n", n, dt))
            self.endJob(id)
        }
    }

    /// bench: 吞吐量测试
    private func cmdBench(_ args: [String]) {
        let n = min(max(Int(args.first ?? "20000") ?? 20000, 100), 500000)
        let id = beginJob()
        workQ.async { [weak self] in
            guard let self = self else { return }
            self.emit("输出 \(n) 行……\r\n")
            let t0 = Date()
            var done = 0
            while done < n && !self.jobCancelled(id) {
                var chunk = ""
                chunk.reserveCapacity(128 * 1024)
                let batch = min(5000, n - done)
                for i in 0..<batch {
                    chunk += "bench line \(done + i) 0123456789 abcdefghijklmnopqrstuvwxyz\r\n"
                }
                self.emit(chunk)
                done += batch
            }
            let dt = Date().timeIntervalSince(t0)
            let rate = dt > 0 ? Double(done) / dt : 0
            self.emit(String(format: "\r\n完成: %d 行, %.2f 秒, %.0f 行/秒\r\n", done, dt, rate))
            self.endJob(id)
        }
    }

    private func cmdColors() {
        var out = ""
        for i in 0..<256 {
            out += "\u{1B}[48;5;\(i)m \(String(format: "%3d", i)) \u{1B}[0m"
            if i % 16 == 15 { out += "\r\n" }
        }
        emit(out + "\r\n" + prompt)
    }

    private func banner() -> String {
        return """
        \u{1B}[38;5;201m████████╗██╗   ██╗██████╗ ██████╗  ██████╗ \u{1B}[0m
        \u{1B}[38;5;165m╚══██╔══╝██║   ██║██╔══██╗██╔══██╗██╔═══██╗\u{1B}[0m
        \u{1B}[38;5;129m   ██║   ██║   ██║██████╔╝██████╔╝██║   ██║\u{1B}[0m
        \u{1B}[38;5;93m    ██║   ██║   ██║██╔══██╗██╔══██╗██║   ██║\u{1B}[0m
        \u{1B}[38;5;57m    ██║   ╚██████╔╝██║  ██║██████╔╝╚██████╔╝\u{1B}[0m
        \u{1B}[38;5;51m    ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚═════╝  ╚═════╝ \u{1B}[0m
        \u{1B}[38;5;240mTurboTerm v1.0 · 高性能终端 · 输入 help 查看命令\u{1B}[0m\r\n
        """
    }
}

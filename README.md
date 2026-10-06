# TurboTerm — 高性能 iOS 终端

一个可以直接打包成 IPA 的 iOS 终端 App 工程（Xcode 项目，Swift + Metal）。
为**高频率文字跳动/高速文本输出**做了专门的渲染优化。

> 说明：这不是 iSH 那种"在 iOS 上模拟 x86 跑真正 Linux"的方案。
> 从零写一个 CPU 模拟器 + Linux 用户态是几年量级的工作，一次交付做不到。
> 这个项目是"iSH 式终端 App"：完整的 VT 终端模拟器 + GPU 加速渲染管线 +
> 内置 Shell，开箱即用；以后可以通过 `TerminalBackend` 协议接 SSH 连你的云电脑。

## 在线打包 IPA（没有 Mac 也行）

我这边的 Linux 云电脑跑不了 macOS，所以这一步得借 GitHub 的云端 Mac：

1. 在 GitHub 建个仓库（公开库免费），把 `TurboTerm-v5.zip` 解压后的**整个文件夹**
   （包括隐藏的 `.github` 目录）传上去。
2. 打开仓库的 **Actions** → 左侧选 **Build IPA** → 右侧点 **Run workflow**。
3. 等几分钟构建完成，在页面底部 **Artifacts** 下载 `TurboTerm-unsigned-ipa`，
   里面就是 `TurboTerm-unsigned.ipa`。

注意两点：
- 打出来的是**未签名**包，真机安装前要用你自己的方法签名
  （你之前提过有自己的 Linux 打包/签名流程，就用那套）。
- 走 Apple 官方签名需要你自己的 Apple Developer 账号，
  账号密码我碰不了，也别发给我。

## v4 CPU 侧

- **回滚批量丢弃**：原来每次滚动都 `removeFirst()`，O(n) 搬移，万条/秒时是 CPU 热点；
  现在超限 256 行才批量丢一次，摊销 O(1)；回滚关掉时零开销。
- **脏行追踪去哈希**：每字符一次 `Set` 哈希插入 → 布尔数组下标写，无哈希开销。
- **ASCII 快路径**：`put()` 里 99% 的 ASCII 字符跳过宽字符判定，直接写格子。
- 以上都不影响运行，只砍 CPU。

## v3 省电档位

- **回滚批量丢弃**：原来每次滚动都 `removeFirst()`，O(n) 搬移，万条/秒时是 CPU 热点；
  现在超限 256 行才批量丢一次，摊销 O(1)；回滚关掉时零开销。
- **脏行追踪去哈希**：每字符一次 `Set` 哈希插入 → 布尔数组下标写，无哈希开销。
- **ASCII 快路径**：`put()` 里 99% 的 ASCII 字符跳过宽字符判定，直接写格子。
- 以上都不影响运行，只砍 CPU。

- **性能模式**：主窗口直接锁 **10fps** + 字体分辨率降到最低（1x）。
- **多开从窗口**：恒为 **1fps + 160p** 省电模式——强制 160 像素高的 drawable，
  图层自动放大显示，GPU 每帧只画这点像素，几乎零开销（格子会变小，只看个大概）。
- 主窗口在性能模式下保持正常网格（可读），只是字变糊 + 10fps。

## v2 新功能

- **多开**：点 "+ 多开" 最多开 6 个终端窗口，主窗口（最左边）的输入会自动
  重复发给所有窗口（"广播"开关可关）。每个窗口独立解析、独立渲染。
- **底部菜单**：⚙️ 设置页 + 快捷键行直接调字体大小（A−/A＋）。
  - 字体大小 10~24pt、字体分辨率 1x/2x/3x、帧率 60/120、回滚行数、性能模式。
- **万条冲击**：`burst 10000` 一瞬间推送 10,000 条消息，测极限压力。

## 目录结构

```
TurboTerm.xcodeproj/        Xcode 工程（用脚本 gen_pbxproj.py 生成）
TurboTerm/
  TurboTermApp.swift         App 入口
  ContentView.swift          界面：窗格标签/终端网格/快捷键行/输入行/设置页
  MultiTerm.swift            多开管理：TerminalPane + PaneManager（主窗口广播输入）
  Info.plist
  Terminal/
    TerminalBuffer.swift     终端网格：格子数组、脏行追踪、回滚、备用屏幕、滚动区域
                             （滚动/插入/删除全部用 memmove 行块搬移）
    VTParser.swift           ANSI/VT100 状态机：光标、擦除、SGR(16/256/真彩色)、OSC标题
  Renderer/
    GlyphAtlas.swift         字形图集：CoreText 烘焙一次，之后全是纹理采样
    TerminalMetalView.swift  四线程流水线：parser 队列 / prep 线程(三重缓冲) /
                             shell 队列 / 主线程提交 + 设置应用
    Shaders.metal            背景/字形混合 shader，下划线
  Backend/
    TerminalBackend.swift    数据源协议（以后接 SSH 就实现这个）
    BuiltinShell.swift       内置 Shell：help/echo/clear/yes/burst/bounce/matrix/bench/colors
```

## 高频优化是怎么做的（v2：硬件加速 + 多线程）

四线程流水线，各干各的，互不阻塞：

1. **turboterm.shell**（后台）：后端命令执行，`burst` 一次拼好 10,000 条再推。
2. **turboterm.parser**（userInteractive）：VT 解析 + 网格状态，有状态所以串行；
   输入侧有**背压合并**——生产者再快，队列里也只有一个待处理数据块，不堆积。
3. **turboterm.prep**（后台）：顶点填充 + GPU 上传，用**三重缓冲**，
   写和读永不打架；预处理跟不上时脏帧自动合并（只合并显示，数据一字不丢）。
4. **主线程**：只做 Metal 编码提交 + 4 个顶点的光标，零重活。

其他手段：

- **Metal 硬件加速**：全屏一次 draw call，字形全是 GPU 纹理采样。
- **memmove 行块搬移**：滚动/插入/删除行一次内存搬移，比逐格循环快一个数量级。
- **脏行追踪 + vsync 合并**：10k 条/秒进来，每帧也只画一次。
- **字形预热**：启动时把 ASCII + 常用中文先烘焙好，高频冲击时零现场光栅化。
- **性能模式**（设置里开）：锁 60 帧 + 分辨率降到 1x，显示合并更激进。
- 以上全是"不影响运行"的优化：**数据一字不丢**，只合并/节流显示侧。

## 试玩高频效果

打开 App 后输入：

- `bounce TURBO◆霓虹 120` — 文字波浪跳动，120Hz 全屏重写，看掉不掉帧
- `matrix 60` — 字符雨，全屏随机重绘
- `burst 10000` — **一瞬间推送 10,000 条消息**（可改条数，如 `burst 50000`）
- `yes` — 无限高速滚动（右下角 `^C` 停止）
- `bench 50000` — 输出 5 万行并报告"行/秒"吞吐量
- 多开 4 窗 + 广播开 + `burst`：四个窗口同时吃 10k 冲击

## 打包成 IPA

1. 用 Xcode 打开 `TurboTerm.xcodeproj`（需要 macOS + Xcode 14+）。
2. 把 `PRODUCT_BUNDLE_IDENTIFIER`（默认 `com.turboterm.ios`）改成你自己的，
   在 Signing 中选你的 Team（或按你的 Linux 打包管线处理签名）。
3. 真机 Release 构建：`xcodebuild -project TurboTerm.xcodeproj -scheme TurboTerm -configuration Release -destination 'generic/platform=iOS' build`，
   然后按你的流程导出 IPA。工程零第三方依赖，`swift package` 不需要联网。

注意：我这边是 Linux，没有 Xcode，**没有实际编译验证过**。
如果打包时报 Swift/签名错误，把报错原文贴给我，我来修。

## 已知限制 / 后续可加

- 内置 Shell 是演示用的命令集，不是真正的 bash；`bounce/matrix/yes/bench` 是压力测试。
- 真机键盘用系统键盘 + 底部快捷键行（Tab/Esc/方向键/^C）。
- 想连你的云电脑：在 `Backend/` 里新建 `SSHBackend.swift` 实现 `TerminalBackend`
  协议（推荐 pure-Swift 的 Citadel 库走 SPM），`ContentView` 里把
  `BuiltinShell()` 换掉即可，渲染管线不用动。
- 回滚目前只存不看（2000 行上限），后续可加手势滚动查看。

## 重新生成工程文件

```bash
python3 gen_pbxproj.py
```

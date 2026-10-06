import Foundation

/// 终端数据源协议: 产生输出 / 接收输入
/// 输出回调可能在任意线程被调用, 解析器内部会转到串行队列。
/// 以后接 SSH 时, 只需实现这个协议即可替换 BuiltinShell。
protocol TerminalBackend: AnyObject {
    func start(onData: @escaping (Data) -> Void)
    func send(_ data: Data)
    func stop()
}

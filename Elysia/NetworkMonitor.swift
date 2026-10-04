import Combine
import Foundation
import Network

/// 网络可达性，用来判断未下载的歌曲能不能播。
///
/// 离线时只有已下载到本机的曲目可播，云端曲目点了也播不了，因此界面要把它们标灰、
/// 点选时给出说明。状态由系统在链路变化时推送，不需要轮询。
///
/// 判据是「有没有可用的网络路径」：只要系统认为当前无法联网（拔网线、关 Wi-Fi、
/// 飞行模式），未下载的曲目一律视为播不了。反过来，系统说有网时不去猜测能否连通
/// 具体服务——那种不确定性交给 Apple Music 自己处理，界面不擅自替用户判断。
final class NetworkMonitor: ObservableObject {
    /// 当前是否联网。
    ///
    /// 初始按「联网」处理：启动瞬间系统还没给出结论，若先按离线算，整个列表会先灰
    /// 一下再恢复。
    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "org.macwave.elysia.network")
    /// 是否已经记录过状态。首次结论也要记，否则日志里看不出 Elysia 认为自己在不在线
    private var hasReported = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { self?.apply(online) }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    private func apply(_ online: Bool) {
        if hasReported, isOnline == online { return }
        hasReported = true
        isOnline = online
        Diagnostics.log(online ? "网络已连接" : "网络已断开，未下载的歌曲将无法播放")
    }
}

import Foundation
import MediaPlayer

// MARK: - 媒体键接管（F7 上一首 / F8 播放暂停 / F9 下一首）
//
// macOS 把这三个键送给「当前正在播放」的那个 app，而不是最前面的窗口。要让 Elysia
// 优先于 Apple Music，需要两步：
//
//   1. 用 MPNowPlayingInfoCenter 认领「正在播放」这个位置——macOS 才会把键路由过来；
//   2. 用 MPRemoteCommandCenter 注册处理函数——才能真正收到按键。
//
// 两步都不需要辅助功能或输入监控权限，也不依赖任何特权。相比之下 NSEvent 的全局
// 监听不仅要权限，而且无法消费事件（Apple Music 会同时响应，变成一次按键跳两首）。
//
// 代价：认领之后系统「控制中心」的正在播放模块会显示 Elysia。对 Elysia 这种本来就在
// 展示当前曲目的 app 而言是合理的；Elysia 退出后该位置自动交还 Apple Music。
enum MediaKeys {

    /// 注册媒体键处理，并认领「正在播放」位置。
    ///
    /// - Parameters:
    ///   - onPrevious: F7，与界面上的「上一首」走同一条逻辑
    ///   - onNext: F9，同上
    ///   - onTogglePlayPause: F8
    static func install(
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onTogglePlayPause: @escaping () -> Void
    ) {
        let center = MPRemoteCommandCenter.shared()

        // 返回 .success 表示已处理；系统据此不再把该键交给其它 app。
        // 回调可能来自任意线程，统一切回主线程，与按钮点击的上下文一致。
        func onMain(_ action: @escaping () -> Void) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
            { _ in
                DispatchQueue.main.async { action() }
                return .success
            }
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget(handler: onMain(onPrevious))

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget(handler: onMain(onNext))

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget(handler: onMain(onTogglePlayPause))
        center.playCommand.isEnabled = true
        center.playCommand.addTarget(handler: onMain(onTogglePlayPause))
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget(handler: onMain(onTogglePlayPause))

        // 认领「正在播放」位置。曲目信息由 update 填充。
        MPNowPlayingInfoCenter.default().playbackState = .paused
        Diagnostics.log("媒体键已注册，并认领「正在播放」位置")
    }

    /// 把当前曲目发布给系统，让「控制中心」与媒体键路由都指向 Elysia。
    static func update(
        title: String?,
        artist: String?,
        duration: Double,
        position: Double,
        isPlaying: Bool
    ) {
        let center = MPNowPlayingInfoCenter.default()
        guard let title else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let artist { info[MPMediaItemPropertyArtist] = artist }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }

        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}

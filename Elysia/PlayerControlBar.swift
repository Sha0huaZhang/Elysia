import SwiftUI
import AppKit

// MARK: - 顶部控制条
struct PlayerControlBar: View {
    let isPlaying: Bool
    let repeatMode: RepeatMode
    let title: String?
    let artist: String?
    let artwork: NSImage?
    @Binding var position: Double
    let duration: Double
    @Binding var isDragging: Bool
    @Binding var dragValue: Double
    @Binding var volume: Double
    @Binding var isDraggingVolume: Bool
    @Binding var dragVolumeValue: Double
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToggleRepeat: () -> Void
    let onTogglePlayPause: () -> Void
    let onSeek: (Double) -> Void
    let onVolumeChange: (Double) -> Void
    let onVolumeCommit: (Double) -> Void

    var body: some View {
        // 左右两侧块等宽，中间的正在播放信息因此精确居中，且不会与两侧重叠
        HStack(spacing: 0) {
            transportControls
                .frame(width: 190, alignment: .leading)

            NowPlayingInline(
                title: title,
                artist: artist,
                artwork: artwork,
                isPlaying: isPlaying,
                position: $position,
                duration: duration,
                isDragging: $isDragging,
                dragValue: $dragValue,
                onSeek: onSeek
            )
            .frame(maxWidth: 400)

            volumeControls
                .frame(width: 190, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        // 略微加高：封面获得更大的上边距，内部内容仍整体垂直居中
        .frame(height: 66)
    }

    private var transportControls: some View {
        HStack(spacing: 20) {
            Button(action: onPrevious) {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.plain)

            Button(action: onTogglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            Button(action: onNext) {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.plain)

            Button(action: onToggleRepeat) {
                Image(systemName: repeatIcon)
                    .foregroundColor(repeatMode == .off ? .primary : .accentColor)
            }
            .buttonStyle(.plain)
        }
        .font(.title3)
    }

    private var volumeControls: some View {
        HStack(spacing: 8) {
            Image(systemName: volumeIcon)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 18, alignment: .center)

            Slider(
                value: Binding(
                    get: { isDraggingVolume ? dragVolumeValue : volume },
                    set: { newValue in
                        dragVolumeValue = newValue
                        isDraggingVolume = true
                    }
                ),
                in: 0...100,
                onEditingChanged: { editing in
                    if editing {
                        isDraggingVolume = true
                    } else {
                        // 松手：下发最终值并结束拖动状态
                        onVolumeCommit(dragVolumeValue)
                        isDraggingVolume = false
                    }
                }
            )
            // 拖动过程中持续下发，音量实时跟随
            .onChange(of: dragVolumeValue) { newValue in
                if isDraggingVolume {
                    onVolumeChange(newValue)
                }
            }
            .controlSize(.mini)
            .tint(.red)
            .frame(width: 80, height: 12)
        }
    }

    private var repeatIcon: String {
        switch repeatMode {
        case .off:  return "repeat"
        case .all:  return "repeat"
        case .one:  return "repeat.1"
        }
    }

    private var volumeIcon: String {
        let v = isDraggingVolume ? dragVolumeValue : volume
        if v <= 0 { return "speaker.slash.fill" }
        if v < 33 { return "speaker.fill" }
        if v < 66 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }
}

// MARK: - 控制条中央的正在播放信息（无独立外框）
struct NowPlayingInline: View {
    let title: String?
    let artist: String?
    let artwork: NSImage?
    let isPlaying: Bool
    @Binding var position: Double
    let duration: Double
    @Binding var isDragging: Bool
    @Binding var dragValue: Double
    let onSeek: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 封面、歌名、歌手视为一个整体
            HStack(spacing: 8) {
                Group {
                    if let artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.gray.opacity(0.3))
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            )
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 0) {
                    Text(title ?? String(localized: "player.notPlaying"))
                        .font(.system(size: 12))
                        .fontWeight(isPlaying ? .bold : .semibold)
                        // 播放中红色；暂停或未播放时跟随系统前景色
                        .foregroundStyle(isPlaying ? Color.red : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(artist ?? "—")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // 进度条在他们下面，从左边缘起
            HStack(spacing: 6) {
                Text(formatTime(isDragging ? dragValue : position))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .monospacedDigit()

                Slider(
                    value: Binding(
                        get: { isDragging ? dragValue : position },
                        set: { newValue in
                            dragValue = newValue
                            isDragging = true
                        }
                    ),
                    in: 0...max(duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            isDragging = true
                        } else {
                            // 松手必须把 isDragging 设回 false。少了这一步，拖过一次
                            // 进度条之后它就永远是 true，显示值会一直取 dragValue，
                            // 轮询也不再更新 position —— 换歌时进度条就不会归零。
                            onSeek(dragValue)
                            isDragging = false
                        }
                    }
                )
                .controlSize(.mini)
                .tint(.red)

                Text(formatTime(duration))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isPlaying)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

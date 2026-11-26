import AVFoundation
import AVKit
import AppKit
import SwiftUI
import VLCKit

struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer
    var openVideo: (URL) -> Void

    func makeNSView(context: Context) -> AVPlayerView {
        let view = DroppableAVPlayerView()
        view.openVideo = openVideo
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.showsSharingServiceButton = false
        view.updatesNowPlayingInfoCenter = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        (nsView as? DroppableAVPlayerView)?.openVideo = openVideo
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

struct VLCPlayerView: NSViewRepresentable {
    let controller: PlayerController
    var openVideo: (URL) -> Void

    func makeNSView(context: Context) -> VLCVideoView {
        let view = DroppableVLCVideoView()
        view.openVideo = openVideo
        view.backColor = .black
        view.fillScreen = true
        controller.attachVLCDrawable(view)
        return view
    }

    func updateNSView(_ nsView: VLCVideoView, context: Context) {
        (nsView as? DroppableVLCVideoView)?.openVideo = openVideo
        controller.attachVLCDrawable(nsView)
    }

    static func dismantleNSView(_ nsView: VLCVideoView, coordinator: Void) {
        // PlayerController replaces the drawable when another video surface is
        // created. There is no model reference in this static callback.
    }
}

// Native video views participate in AppKit's drag destination lookup before
// their SwiftUI parent. Accept files here as well as on the surrounding window.
private final class DroppableVLCVideoView: VLCVideoView {
    var openVideo: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        VideoFile.read(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        VideoFile.read(from: sender.draggingPasteboard) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = VideoFile.read(from: sender.draggingPasteboard) else { return false }
        // Defer rebuilding SwiftUI's video surface until this drag has ended.
        let action = openVideo
        Task { @MainActor in action?(url) }
        return true
    }
}

private final class DroppableAVPlayerView: AVPlayerView {
    var openVideo: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        VideoFile.read(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        VideoFile.read(from: sender.draggingPasteboard) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = VideoFile.read(from: sender.draggingPasteboard) else { return false }
        let action = openVideo
        Task { @MainActor in action?(url) }
        return true
    }
}

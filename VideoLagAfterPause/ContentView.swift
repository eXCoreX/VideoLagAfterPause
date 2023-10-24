//
//  ContentView.swift
//  VideoLagAfterPause
//
//  Created by Rostyslav Litvinov on 10/23/23.
//

import SwiftUI
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins

@MainActor
class RequestTimeObserver: ObservableObject {
    static let `default` = RequestTimeObserver()

    var requestedRefreshTime: Date?
    @Published var timeToStart: TimeInterval = 0
    @Published var timeToRender: TimeInterval = 0
    @Published var lastRenderedTime: CMTime = .zero
}

class FilterSettings {
    var invertColors = false
}

class VideoCompositor: NSObject, AVVideoCompositing {
    let requiredPixelBufferAttributesForRenderContext: [String: Any] =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let sourcePixelBufferAttributes: [String: Any]? =
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { }

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        let dateStarted = Date.now

        guard let buffer1 = asyncVideoCompositionRequest.sourceFrame(byTrackID: 1),
              let buffer2 = asyncVideoCompositionRequest.sourceFrame(byTrackID: 2),
              let buffer3 = asyncVideoCompositionRequest.sourceFrame(byTrackID: 3),
              let buffer4 = asyncVideoCompositionRequest.sourceFrame(byTrackID: 4) else {
            asyncVideoCompositionRequest.finishCancelledRequest()
            return
        }

        // Some random image filtering just to use all of the buffers
        let ciImage = CIImage(cvPixelBuffer: buffer1)

        let dodgeFilter = CIFilter.colorDodgeBlendMode()
        dodgeFilter.backgroundImage = ciImage
        dodgeFilter.inputImage = CIImage(cvPixelBuffer: buffer2)

        let burnFilter = CIFilter.colorBurnBlendMode()
        burnFilter.backgroundImage = dodgeFilter.outputImage
        burnFilter.inputImage = CIImage(cvPixelBuffer: buffer3)

        var result = burnFilter.outputImage!

        // Make some visual changes to visually differenciate when the settings are applied to the video
        let filterSettings = (asyncVideoCompositionRequest.videoCompositionInstruction as! CustomInstruction).filterSettings
        var maskImage = CIImage(cvPixelBuffer: buffer4)
        if filterSettings.invertColors {
            let ciFilter = CIFilter.colorInvert()
            ciFilter.inputImage = maskImage
            maskImage = ciFilter.outputImage!
        }

        let blueMask = CIFilter.blendWithBlueMask()
        blueMask.backgroundImage = filterSettings.invertColors ? CIImage(cvPixelBuffer: buffer4) : .black
        blueMask.inputImage = filterSettings.invertColors ? CIImage(cvPixelBuffer: buffer4) : result
        blueMask.maskImage = maskImage

        result = blueMask.outputImage!

        let newBuffer = asyncVideoCompositionRequest.renderContext.newPixelBuffer()!
        CIContext().render(result, to: newBuffer)

        asyncVideoCompositionRequest.finish(withComposedVideoFrame: newBuffer)    
        
        let dateFinished = Date.now

        // Time observing
        Task { @MainActor in
            RequestTimeObserver.default.lastRenderedTime = asyncVideoCompositionRequest.compositionTime
            if let dateRequested = RequestTimeObserver.default.requestedRefreshTime {
                guard dateRequested < dateStarted else { return }

                RequestTimeObserver.default.timeToStart = dateStarted.timeIntervalSince(dateRequested)
                RequestTimeObserver.default.timeToRender = dateFinished.timeIntervalSince(dateRequested)
                RequestTimeObserver.default.requestedRefreshTime = nil
            }
        }
    }
}

class CustomInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange
    var filterSettings: FilterSettings

    var enablePostProcessing: Bool = false
    var containsTweening: Bool = false
    var requiredSourceTrackIDs: [NSValue]? = [
        NSNumber(value: 1),
        NSNumber(value: 2),
        NSNumber(value: 3),
        NSNumber(value: 4)
    ]
    var passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    init(timeRange: CMTimeRange, filterSettings: FilterSettings) {
        self.timeRange = timeRange
        self.filterSettings = filterSettings
    }
}

class PlayerStore: ObservableObject {
    let avPlayer = AVPlayer()
    let filterSettings = FilterSettings()

    func loadVideo() async throws {
        // Assets
        let videoAsset = AVAsset(url: Bundle.main.url(forResource: "example_video", withExtension: "mp4")!)
        let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first!

        let videoAsset2 = AVAsset(url: Bundle.main.url(forResource: "example_video_2", withExtension: "mp4")!)
        let videoTrack2 = try await videoAsset2.loadTracks(withMediaType: .video).first!

        let videoAsset3 = AVAsset(url: Bundle.main.url(forResource: "example_video_3", withExtension: "mp4")!)
        let videoTrack3 = try await videoAsset3.loadTracks(withMediaType: .video).first!

        let videoAsset4 = AVAsset(url: Bundle.main.url(forResource: "light_leak_2", withExtension: "mp4")!)
        let videoTrack4 = try await videoAsset4.loadTracks(withMediaType: .video).first!
        let videoTrack4TimeRange = try await videoTrack4.load(.timeRange)


        // Composition
        let composition = AVMutableComposition()
        let track1 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1)!
        let track2 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 2)!
        let track3 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 3)!
        let track4 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 4)!

        try track1.insertTimeRange(videoTrack4TimeRange, of: videoTrack, at: .zero)
        try track2.insertTimeRange(videoTrack4TimeRange, of: videoTrack2, at: .zero)
        try track3.insertTimeRange(videoTrack4TimeRange, of: videoTrack3, at: .zero)
        try track4.insertTimeRange(videoTrack4TimeRange, of: videoTrack4, at: .zero)

        // Video composition
        let videoComposition = AVMutableVideoComposition()

        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        videoComposition.customVideoCompositorClass = VideoCompositor.self
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderSize = CGSize(width: 1080, height: 1920)
        videoComposition.instructions = [CustomInstruction(timeRange: videoTrack4TimeRange, filterSettings: filterSettings)]

        let playerItem = AVPlayerItem(asset: composition)

        playerItem.videoComposition = videoComposition

        avPlayer.replaceCurrentItem(with: playerItem)
    }

    func toggleInversion() {
        filterSettings.invertColors.toggle()
        if avPlayer.rate == 0 {
            avPlayer.currentItem?.videoComposition = avPlayer.currentItem?.videoComposition?.mutableCopy() as? AVVideoComposition
        }
    }
}

struct ContentView: View {
    @StateObject private var playerStore = PlayerStore()
    @State private var ballOffset = 0.0

    @ObservedObject private var timeObserver = RequestTimeObserver.default

    var body: some View {
        VStack {
            VideoPlayer(player: playerStore.avPlayer)
                .task {
                    try? await playerStore.loadVideo()
                }
                .overlay(alignment: .topTrailing) {
                    meterView
                }
                .overlay(alignment: .topTrailing) {
                    gaugeView
                }
            VStack {
                Button("Toggle inversion") {
                    RequestTimeObserver.default.requestedRefreshTime = .now
                    playerStore.toggleInversion()
                    Task {
                        withAnimation(nil) {
                            ballOffset = 0
                        }
                        withAnimation(.linear(duration: 1)) {
                            ballOffset = 400
                        }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        ballOffset = 0
                    }
                }
                .buttonStyle(.borderedProminent)

                Text("Time to start request: \(timeObserver.timeToStart * 1000, format: .number.precision(.fractionLength(1))) ms")

                Text("Time to complete render: \(timeObserver.timeToRender * 1000, format: .number.precision(.fractionLength(1))) ms")

                Text("Last rendered time: \(timeObserver.lastRenderedTime.value)/\(timeObserver.lastRenderedTime.timescale)")
            }
        }
    }

    private var meterView: some View {
        VStack(spacing: 0) {
            ForEach(0..<11) { time in
                VStack(spacing: 0) {
                    Text("\(Double(time) / 10, format: .number)")
                    Color.primary.frame(width: 30, height: 2)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .background(.background)
        .frame(height: 440)
    }

    private var gaugeView: some View {
        Circle()
            .frame(width: 50, height: 50)
            .offset(x: -40, y: 0)
            .overlay {
                Rectangle()
                    .fill(.red)
                    .frame(width: 100, height: 4)
            }
            .offset(x: -40, y: ballOffset)
    }
}

#Preview {
    ContentView()
}

import AVKit
import MilepostKit
import SwiftUI

/// Hosts the shared `AVPlayer` in an `AVPlayerViewController`.
///
/// This exists for AirPlay video streaming, which the CarPlay video entitlement
/// requires. `AVPlayer.allowsExternalPlayback` is necessary but not sufficient:
/// without a player view controller there is no video output, so AVFoundation
/// never builds a video pipeline and there is nothing to send to the car. The
/// browsing templates render and audio plays, but the car display stays empty.
///
/// `AVPlayerViewController` also brings the transport UI, subtitle and audio
/// language menus, and the AirPlay route picker for free.
struct VideoStage: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        // Keep the on-phone chrome minimal: in the car the driver uses CarPlay's
        // own controls, and on the phone this view is a stage, not a player UI.
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}

/// Full-screen video, shown on the phone whenever a video item is current.
///
/// Deliberately full screen and long-lived: it gives AVFoundation one stable
/// video output for the whole item, which is what AirPlay hands to the car.
struct VideoScreen: View {
    let engine: PlaybackEngine

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoStage(player: engine.player)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        engine.perform(.pause, from: .phone)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.title2)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Stop watching")

                    Spacer()
                    RoutePicker()
                        .frame(width: 44, height: 32)
                }
                .padding()
                Spacer()

                if let item = engine.currentItem {
                    Text(item.title)
                        .font(.headline)
                        .padding(.bottom, 28)
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

/// The AirPlay route button, so a passenger can pick the car's display directly.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.activeTintColor = .systemOrange
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

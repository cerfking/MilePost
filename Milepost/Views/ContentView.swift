import MilepostKit
import SwiftUI

struct ContentView: View {
    private let engine = AppEnvironment.shared.engine

    var body: some View {
        NavigationStack {
            List {

                Section {
                    ForEach(engine.catalog.items) { item in
                        Button {
                            engine.perform(.play(itemID: item.id), from: .phone)
                        } label: {
                            TrackRow(
                                title: item.title,
                                show: item.show,
                                duration: item.duration,
                                isCurrent: item.id == engine.currentItemID
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Episodes")
                }
            }
            .navigationTitle("Library")
            .safeAreaInset(edge: .bottom) {
                NowPlayingBar(engine: engine)
            }
            // A video item gets a full-screen player rather than a row inside
            // the list. A `List` recycles its rows, so an AVPlayerViewController
            // hosted there can be torn down and rebuilt underneath AVFoundation
            // — and a player that keeps getting rehosted is not a stable video
            // output for AirPlay to hand to the car. Full screen also matches
            // what someone actually wants on the phone.
            .fullScreenCover(isPresented: .constant(engine.currentItem?.kind == .video)) {
                VideoScreen(engine: engine)
            }
        }
    }
}

/// Takes the three fields it renders rather than the whole `MediaItem`, so a change
/// to an unrelated field would not invalidate every row.
private struct TrackRow: View {
    let title: String
    let show: String
    let duration: TimeInterval
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isCurrent ? "waveform" : "play.circle")
                .font(.title3)
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text("\(show) · \(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}

/// Reads `activity` and `elapsed` from the engine — two narrow property reads,
/// which per-property observation scopes to exactly this view.
private struct NowPlayingBar: View {
    let engine: PlaybackEngine

    var body: some View {
        if let item = engine.currentItem {
            VStack(spacing: 8) {
                ProgressView(value: engine.snapshot.progress)
                    .tint(.accentColor)

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(Duration.seconds(engine.elapsed).formatted(.time(pattern: .minuteSecond)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    Button {
                        engine.perform(.previous, from: .phone)
                    } label: {
                        Image(systemName: "backward.fill")
                    }
                    .accessibilityLabel("Previous episode")

                    Button {
                        engine.perform(.toggle, from: .phone)
                    } label: {
                        Image(systemName: engine.activity == .playing ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 32)
                    }
                    .accessibilityLabel(engine.activity == .playing ? "Pause" : "Play")

                    Button {
                        engine.perform(.next, from: .phone)
                    } label: {
                        Image(systemName: "forward.fill")
                    }
                    .accessibilityLabel("Next episode")
                }
                .buttonStyle(.plain)
                .font(.title3)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

#Preview {
    ContentView()
}

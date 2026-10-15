//
//  NotchHomeView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//

import Combine
import Defaults
import SwiftUI

// MARK: - Music Player Components

struct MusicPlayerView: View {
    @EnvironmentObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID

    @ObservedObject private var calendarManager = CalendarManager.shared

    var body: some View {
        if vm.isCompact {
            VStack(spacing: 6 * vm.notchScale) {
                if calendarManager.meetingSoon, let meeting = calendarManager.nextMeeting {
                    MeetingJoinRow(meeting: meeting)
                }
                MusicControlsView(compactArtNamespace: albumArtNamespace)
            }
            .environment(\.notchScale, vm.notchScale) // drawn at real size, stays sharp
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, -10) // sit right under the tab row
        } else {
            HStack {
                AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace).padding(.all, 5)
                MusicControlsView().drawingGroup().compositingGroup()
            }
        }
    }
}

struct AlbumArtView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID
    var showAppIcon = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if Defaults[.lightingEffect] {
                albumArtBackground
            }
            albumArtButton
        }
    }

    private var albumArtBackground: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(x: 1.3, y: 1.4)
            .rotationEffect(.degrees(92))
            .blur(radius: 40)
            .opacity(musicManager.isPlaying ? 0.5 : 0)
    }

    private var albumArtButton: some View {
        ZStack {
            Button {
                musicManager.openMusicApp()
            } label: {
                ZStack(alignment:.bottomTrailing) {
                    albumArtImage
                    appIconOverlay
                }
            }
            .buttonStyle(PlainButtonStyle())
            .scaleEffect(musicManager.isPlaying ? 1 : 0.85)
            
            albumArtDarkOverlay
        }
    }

    private var albumArtDarkOverlay: some View {
        Rectangle()
            .aspectRatio(1, contentMode: .fit)
            .foregroundColor(Color.black)
            .opacity(musicManager.isPlaying ? 0 : 0.8)
            .blur(radius: 50)
    }
                

    private var albumArtImage: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
    }

    @ViewBuilder
    private var appIconOverlay: some View {
        if showAppIcon && vm.notchState == .open && !musicManager.usingAppIconForArtwork {
            AppIcon(for: musicManager.bundleIdentifier ?? "com.apple.Music")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .offset(x: 10, y: 10)
                .transition(.scale.combined(with: .opacity))
                .zIndex(2)
        }
    }
}

struct MusicControlsView: View {
    @ObservedObject var musicManager = MusicManager.shared
        @EnvironmentObject var vm: BoringViewModel
        @ObservedObject var webcamManager = WebcamManager.shared
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast
    @Default(.musicControlSlots) private var slotConfig
    @Default(.musicControlSlotLimit) private var slotLimit
    @Default(.vinylArtwork) private var vinylArtwork
    @Environment(\.notchScale) private var scale
    /// Non-nil → Alcove-style compact layout that also draws the album art.
    var compactArtNamespace: Namespace.ID? = nil

    var body: some View {
        Group {
            if let ns = compactArtNamespace {
                compactBody(ns)
            } else {
                VStack(alignment: .leading) {
                    songInfoAndSlider
                    slotToolbar()
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// Two columns: big art (or vinyl) on the left; title, progress and controls to its right.
    private func compactBody(_ ns: Namespace.ID) -> some View {
        HStack(alignment: .top, spacing: 14 * scale) {
            Group {
                if vinylArtwork {
                    VinylArtView(image: musicManager.albumArt, isPlaying: musicManager.isPlaying)
                        .onTapGesture { musicManager.openMusicApp() }
                } else {
                    AlbumArtView(vm: vm, albumArtNamespace: ns, showAppIcon: false)
                }
            }
            .frame(width: 78 * scale, height: 78 * scale)
            .padding(.leading, -6 * scale) // tuck toward the notch edge

            VStack(spacing: 8 * scale) {
                HStack(spacing: 8 * scale) {
                    GeometryReader { geo in
                        VStack(alignment: .leading, spacing: 1) {
                            MarqueeText($musicManager.songTitle, font: .system(size: 13 * scale, weight: .bold), nsFont: .headline, textColor: .white, frameWidth: geo.size.width, scale: scale)
                            MarqueeText($musicManager.artistName, font: .system(size: 13 * scale), nsFont: .body, textColor: .gray, frameWidth: geo.size.width, scale: scale)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(height: 40 * scale)
                    Rectangle()
                        .fill(Defaults[.coloredSpectrogram] ? Color(nsColor: musicManager.avgColor).gradient : Color.gray.gradient)
                        .frame(width: 16 * scale, height: 12 * scale)
                        .mask { AudioSpectrumView(isPlaying: $musicManager.isPlaying).frame(width: 16 * scale, height: 12 * scale) }
                }
                musicSlider(compact: true)
                slotToolbar(compact: true)
                    // Inset both sides equally (keeps play centered) so edge buttons clear the output icon
                    .padding(.horizontal, 26 * scale)
                    .overlay(alignment: .trailing) { AudioOutputIcon() }
            }
        }
    }

    private var songInfoAndSlider: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 4) {
                songInfo(width: geo.size.width)
                musicSlider()
            }
        }
        .padding(.top, 10)
        .padding(.leading, 5)
    }

    private func songInfo(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MarqueeText(
                $musicManager.songTitle, font: .headline, nsFont: .headline, textColor: .white,
                frameWidth: width)
            MarqueeText(
                $musicManager.artistName,
                font: .headline,
                nsFont: .headline,
                textColor: Defaults[.playerColorTinting]
                    ? Color(nsColor: musicManager.avgColor)
                        .ensureMinimumBrightness(factor: 0.6) : .gray,
                frameWidth: width
            )
            .fontWeight(.medium)
        }
    }

    private func musicSlider(compact: Bool = false) -> some View {
        TimelineView(.animation(minimumInterval: musicManager.playbackRate > 0 ? 0.1 : nil)) { timeline in
            MusicSliderView(
                sliderValue: $sliderValue,
                duration: $musicManager.songDuration,
                lastDragged: $lastDragged,
                color: musicManager.avgColor,
                dragging: $dragging,
                currentDate: timeline.date,
                timestampDate: musicManager.timestampDate,
                elapsedTime: musicManager.elapsedTime,
                playbackRate: musicManager.playbackRate,
                isPlaying: musicManager.isPlaying,
                compact: compact
            ) { newValue in
                MusicManager.shared.seek(to: newValue)
            }
            .padding(.top, compact ? 0 : 5)
            .frame(height: compact ? 14 * scale : 36)
        }
    }

    private func slotToolbar(compact: Bool = false) -> some View {
        let slots = activeSlots
        return HStack(spacing: 6) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                slotView(for: slot)
                    .frame(maxWidth: compact ? .infinity : nil, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var activeSlots: [MusicControlButton] {
        let sanitizedLimit = min(
            max(slotLimit, MusicControlButton.minSlotCount),
            MusicControlButton.maxSlotCount
        )
        let padded = slotConfig.padded(to: sanitizedLimit, filler: .none)
        let result = Array(padded.prefix(sanitizedLimit))
        // If calendar and camera are both visible alongside music, hide the edge slots
        let shouldHideEdges = Defaults[.showCalendar] && Defaults[.showMirror] && webcamManager.cameraAvailable && vm.isCameraExpanded
        if shouldHideEdges && result.count >= 5 {
            return Array(result.dropFirst().dropLast())
        }

        return result
    }

    @ViewBuilder
    private func slotView(for slot: MusicControlButton) -> some View {
        switch slot {
        case .shuffle:
            HoverButton(icon: "shuffle", iconColor: musicManager.isShuffled ? .green : .primary, scale: .medium) {
                MusicManager.shared.toggleShuffle()
            }
        case .previous:
            HoverButton(icon: "backward.fill", scale: .medium) {
                MusicManager.shared.previousTrack()
            }
        case .playPause:
            HoverButton(icon: musicManager.isPlaying ? "pause.fill" : "play.fill", scale: .large) {
                MusicManager.shared.togglePlay()
            }
        case .next:
            HoverButton(icon: "forward.fill", scale: .medium) {
                MusicManager.shared.nextTrack()
            }
        case .repeatMode:
            HoverButton(icon: repeatIcon, iconColor: repeatIconColor, scale: .medium) {
                MusicManager.shared.toggleRepeat()
            }
        case .volume:
            VolumeControlView()
        case .favorite:
            FavoriteControlButton()
        case .goBackward:
            HoverButton(icon: "gobackward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: -15)
            }
        case .goForward:
            HoverButton(icon: "goforward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: 15)
            }
        case .none:
            Color.clear.frame(height: 1)
        }
    }

    private var repeatIcon: String {
        switch musicManager.repeatMode {
        case .off:
            return "repeat"
        case .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private var repeatIconColor: Color {
        switch musicManager.repeatMode {
        case .off:
            return .primary
        case .all, .one:
            return .green
        }
    }
}

/// Where audio is playing (AirPods, speakers, …), like Alcove's output icon; hover for the device name.
struct AudioOutputIcon: View {
    @ObservedObject private var output = AudioOutputMonitor.shared
    @Environment(\.notchScale) private var scale

    var body: some View {
        Image(systemName: output.symbol)
            .font(.system(size: 16 * scale, weight: .medium))
            .foregroundStyle(.gray)
            .frame(width: 30 * scale, height: 30 * scale)
            .help(output.name)
            .contentTransition(.symbolEffect(.replace))
    }
}

/// "Notch size" multiplier for the compact player. Views multiply their sizes by it (instead of
/// scaleEffect, which zooms a bitmap and blurs text).
private struct NotchScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var notchScale: CGFloat {
        get { self[NotchScaleKey.self] }
        set { self[NotchScaleKey.self] = newValue }
    }
}

/// Optional spinning record with the cover art as its label (Settings → Appearance).
struct VinylArtView: View {
    let image: NSImage
    let isPlaying: Bool
    @State private var spin = VinylSpin()

    var body: some View {
        // ponytail: redraws ~24fps only while playing; a paused timeline costs nothing
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !isPlaying)) { context in
            record.rotationEffect(.degrees(spin.angle(at: context.date, playing: isPlaying)))
        }
        .overlay(sheen) // light reflection stays still while the record turns
    }

    private var record: some View {
        ZStack {
            Circle().fill(Color(white: 0.07))
            ForEach([0.94, 0.84, 0.74], id: \.self) { ring in
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    .scaleEffect(ring)
            }
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(Circle())
                .scaleEffect(0.56)
            Circle()
                .fill(Color.black)
                .scaleEffect(0.08)
        }
    }

    private var sheen: some View {
        Circle()
            .fill(LinearGradient(colors: [.white.opacity(0.14), .clear, .white.opacity(0.05)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .allowsHitTesting(false)
    }
}

private final class VinylSpin {
    private var angle = 0.0
    private var last: Date?

    /// Advances only while playing, so pausing freezes the record where it stopped.
    func angle(at date: Date, playing: Bool) -> Double {
        if playing, let last {
            angle = (angle + date.timeIntervalSince(last) * 45).truncatingRemainder(dividingBy: 360) // 45°/s
        }
        last = playing ? date : nil
        return angle
    }
}

struct FavoriteControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        HoverButton(icon: iconName, iconColor: iconColor, scale: .medium) {
            MusicManager.shared.toggleFavoriteTrack()
        }
        .disabled(!musicManager.canFavoriteTrack)
        .opacity(musicManager.canFavoriteTrack ? 1 : 0.35)
    }

    private var iconName: String {
        musicManager.isFavoriteTrack ? "heart.fill" : "heart"
    }

    private var iconColor: Color {
        musicManager.isFavoriteTrack ? .red : .primary
    }
}

private extension Array where Element == MusicControlButton {
    func padded(to length: Int, filler: MusicControlButton) -> [MusicControlButton] {
        if count >= length { return self }
        return self + Array(repeating: filler, count: length - count)
    }
}

// MARK: - Volume Control View

struct VolumeControlView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var volumeSliderValue: Double = 0.5
    @State private var dragging: Bool = false
    @State private var showVolumeSlider: Bool = false
    @State private var lastVolumeUpdateTime: Date = Date.distantPast
    private let volumeUpdateThrottle: TimeInterval = 0.1
    
    var body: some View {
        HStack(spacing: 4) {
            Button(action: {
                if musicManager.volumeControlSupported {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showVolumeSlider.toggle()
                    }
                }
            }) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(musicManager.volumeControlSupported ? .white : .gray)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!musicManager.volumeControlSupported)
            .frame(width: 24)

            if showVolumeSlider && musicManager.volumeControlSupported {
                CustomSlider(
                    value: $volumeSliderValue,
                    range: 0.0...1.0,
                    color: .white,
                    dragging: $dragging,
                    lastDragged: .constant(Date.distantPast),
                    onValueChange: { newValue in
                        MusicManager.shared.setVolume(to: newValue)
                    },
                    onDragChange: { newValue in
                        let now = Date()
                        if now.timeIntervalSince(lastVolumeUpdateTime) > volumeUpdateThrottle {
                            MusicManager.shared.setVolume(to: newValue)
                            lastVolumeUpdateTime = now
                        }
                    }
                )
                .frame(width: 48, height: 8)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .clipped()
        .onReceive(musicManager.$volume) { volume in
            if !dragging {
                volumeSliderValue = volume
            }
        }
        .onReceive(musicManager.$volumeControlSupported) { supported in
            if !supported {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showVolumeSlider = false
                }
            }
        }
        .onChange(of: showVolumeSlider) { _, isShowing in
            if isShowing {
                // Sync volume from app when slider appears
                Task {
                    await MusicManager.shared.syncVolumeFromActiveApp()
                }
            }
        }
        .onDisappear {
            // volumeUpdateTask?.cancel() // No longer needed
        }
    }
    
    
    private var volumeIcon: String {
        if !musicManager.volumeControlSupported {
            return "speaker.slash"
        } else if volumeSliderValue == 0 {
            return "speaker.slash.fill"
        } else if volumeSliderValue < 0.33 {
            return "speaker.1.fill"
        } else if volumeSliderValue < 0.66 {
            return "speaker.2.fill"
        } else {
            return "speaker.3.fill"
        }
    }
}

// MARK: - Main View

struct NotchHomeView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    let albumArtNamespace: Namespace.ID

    var body: some View {
        Group {
            if !coordinator.firstLaunch {
                mainContent
            }
        }
        // simplified: use a straightforward opacity transition
        .transition(.opacity)
    }

    private var shouldShowCamera: Bool {
        Defaults[.showMirror] && webcamManager.cameraAvailable && vm.isCameraExpanded
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: (shouldShowCamera && Defaults[.showCalendar]) ? 10 : 15) {
            MusicPlayerView(albumArtNamespace: albumArtNamespace)

            if Defaults[.showCalendar] {
                CalendarView()
                    .frame(width: shouldShowCamera ? 170 : 215)
                    .onHover { isHovering in
                        vm.isHoveringCalendar = isHovering
                    }
                    .environmentObject(vm)
                    .transition(.opacity)
            }

            if shouldShowCamera {
                CameraPreviewView(webcamManager: webcamManager)
                    .scaledToFit()
                    .opacity(vm.notchState == .closed ? 0 : 1)
                    .blur(radius: vm.notchState == .closed ? 20 : 0)
                    .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.76, blendDuration: 0), value: shouldShowCamera)
            }
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
        .blur(radius: vm.notchState == .closed ? 30 : 0)
    }
}

struct MusicSliderView: View {
    @Binding var sliderValue: Double
    @Binding var duration: Double
    @Binding var lastDragged: Date
    var color: NSColor
    @Binding var dragging: Bool
    let currentDate: Date
    let timestampDate: Date
    let elapsedTime: Double
    let playbackRate: Double
    let isPlaying: Bool
    var compact = false
    var onValueChange: (Double) -> Void
    @Environment(\.notchScale) private var scale


    var body: some View {
        Group {
            if compact {
                // Alcove-style: 2:37 ━━━━━━──── -0:54
                HStack(spacing: 10 * scale) {
                    Text(timeString(from: sliderValue)).modifier(timeStyle)
                    slider
                    Text("-" + timeString(from: max(duration - sliderValue, 0))).modifier(timeStyle)
                }
            } else {
                VStack {
                    slider
                    HStack {
                        Text(timeString(from: sliderValue))
                        Spacer()
                        Text(timeString(from: duration))
                    }
                    .modifier(timeStyle)
                }
            }
        }
        .onChange(of: currentDate) {
           guard !dragging, timestampDate.timeIntervalSince(lastDragged) > -1 else { return }
            sliderValue = MusicManager.shared.estimatedPlaybackPosition(at: currentDate)
        }
    }

    private var slider: some View {
        CustomSlider(
            value: $sliderValue,
            range: 0...duration,
            color: Defaults[.sliderColor] == SliderColorEnum.albumArt
                ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.8)
                : Defaults[.sliderColor] == SliderColorEnum.accent ? .effectiveAccent : .white,
            dragging: $dragging,
            lastDragged: $lastDragged,
            onValueChange: onValueChange
        )
        .frame(height: 10 * scale, alignment: .center)
    }

    private var timeStyle: TimeStyle {
        TimeStyle(color: Defaults[.playerColorTinting]
            ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.6) : .gray, scale: scale)
    }

    struct TimeStyle: ViewModifier {
        let color: Color
        var scale: CGFloat = 1
        func body(content: Content) -> some View {
            content.fontWeight(.medium).foregroundColor(color)
                .font(scale == 1 ? .caption : .system(size: 10 * scale)).monospacedDigit()
        }
    }

    func timeString(from seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}

struct CustomSlider: View {
    @Environment(\.notchScale) private var scale
    @Binding var value: Double
    var range: ClosedRange<Double>
    var color: Color = .white
    @Binding var dragging: Bool
    @Binding var lastDragged: Date
    var onValueChange: ((Double) -> Void)?
    var onDragChange: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = CGFloat(dragging ? 9 : 5) * scale
            let rangeSpan = range.upperBound - range.lowerBound

            let progress = rangeSpan == .zero ? 0 : (value - range.lowerBound) / rangeSpan
            let filledTrackWidth = min(max(progress, 0), 1) * width

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .frame(height: height)

                Rectangle()
                    .fill(color)
                    .frame(width: filledTrackWidth, height: height)
            }
            .cornerRadius(height / 2)
            .frame(height: 10 * scale)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        withAnimation {
                            dragging = true
                        }
                        let newValue = range.lowerBound + Double(gesture.location.x / width) * rangeSpan
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                        onDragChange?(value)
                    }
                    .onEnded { _ in
                        onValueChange?(value)
                        dragging = false
                        lastDragged = Date()
                    }
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: dragging)
        }
    }
}

// MARK: - Sticky Notes

struct StickyNotesView: View {
    @EnvironmentObject var vm: BoringViewModel
    @Default(.stickyNotes) private var notes
    @State private var current = 0
    @State private var hoveredTab: Int?
    @State private var dragStartWidth: CGFloat?
    @State private var hoveredHandle: CGFloat?
    private let maxNotes = 5

    private var text: Binding<String> {
        Binding(
            get: { notes.indices.contains(current) ? notes[current] : "" },
            set: { if notes.indices.contains(current) { notes[current] = $0 } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            noteTabs
            // Click the text to type: the notch panel only becomes key on this tab (see canBecomeKey).
            TextEditor(text: text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text("Type a note…")
                            .font(.system(size: 13))
                            .foregroundStyle(.gray)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        .overlay(alignment: .leading) { if vm.notesLocked { resizeHandle(edge: -1).offset(x: -20) } }
        .overlay(alignment: .trailing) { if vm.notesLocked { resizeHandle(edge: 1).offset(x: 20) } }
        .onDisappear {
            // Hand keyboard focus back to the app you were in, so typing doesn't go to a hidden notch.
            if NSApp.keyWindow is NSPanel {
                NSWorkspace.shared.frontmostApplication?.activate()
            }
        }
    }

    /// 1 2 3 … +   ·   lock. Hover a tab to show its delete ×.
    private var noteTabs: some View {
        HStack(spacing: 4) {
            ForEach(notes.indices, id: \.self) { index in
                HStack(spacing: 3) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .semibold))
                    if hoveredTab == index && notes.count > 1 {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .onTapGesture { delete(index) }
                            .help("Delete this note")
                    }
                }
                .foregroundStyle(index == current ? .white : .gray)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(index == current ? Color.white.opacity(0.15) : .clear))
                .contentShape(Capsule())
                .onTapGesture { current = index }
                .onHover { hoveredTab = $0 ? index : (hoveredTab == index ? nil : hoveredTab) }
            }
            if notes.count < maxNotes {
                Button {
                    notes.append("")
                    current = notes.count - 1
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.gray)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New note")
            }
            Spacer(minLength: 0)
            Button {
                vm.notesLocked.toggle()
            } label: {
                Image(systemName: vm.notesLocked ? "lock.fill" : "lock.open")
                    .foregroundStyle(vm.notesLocked ? Color.yellow : .gray)
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(vm.notesLocked ? "Unlock: notch closes when the mouse leaves" : "Lock: keep notes open")
        }
    }

    private func delete(_ index: Int) {
        guard notes.count > 1, notes.indices.contains(index) else { return }
        notes.remove(at: index)
        hoveredTab = nil
        if current >= index { current = max(current - 1, 0) }
    }

    /// Drag to stretch the notes; the notch stays centered, so the width changes by twice the drag.
    private func resizeHandle(edge: CGFloat) -> some View {
        // Whole side strip is grabbable (full height, ~26pt wide), not just the little pill
        Capsule()
            .fill(Color.gray.opacity(hoveredHandle == edge || dragStartWidth != nil ? 0.95 : 0.6))
            .frame(width: hoveredHandle == edge ? 5 : 4, height: 32)
            .frame(width: 26)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                hoveredHandle = inside ? edge : (hoveredHandle == edge ? nil : hoveredHandle)
                inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop()
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        let start = dragStartWidth ?? vm.notesWidth
                        dragStartWidth = start
                        vm.notesWidth = min(max(start + edge * 2 * g.translation.width, compactOpenNotchSize.width), stickyNoteMaxWidth)
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        Defaults[.stickyNoteWidth] = Double(vm.notesWidth)
                    }
            )
            .help("Drag to resize")
    }
}

// MARK: - Clipboard History

/// Last few copied texts, kept in memory only (never written to disk).
@MainActor
final class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory()

    @Published private(set) var items: [String] = []
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private let limit = 20
    // Password managers mark secrets with these (nspasteboard.org convention); never record them
    private let skippedTypes: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"),
    ]

    func start() {
        guard timer == nil else { return }
        // ponytail: macOS has no pasteboard-change notification, so poll changeCount (a cheap integer compare)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !(pasteboard.types ?? []).contains(where: skippedTypes.contains),
              let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        items.removeAll { $0 == text }
        items.insert(text, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
    }

    /// Puts `text` back on the clipboard; the next poll moves it to the top.
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clear() { items.removeAll() }
}

struct ClipboardHistoryView: View {
    @ObservedObject private var history = ClipboardHistory.shared
    @State private var justCopied: String?

    var body: some View {
        Group {
            if history.items.isEmpty {
                Text("Copied text shows up here")
                    .font(.system(size: 13))
                    .foregroundStyle(.gray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(history.items, id: \.self) { text in
                            ClipboardRow(text: text, copied: justCopied == text) {
                                history.copy(text)
                                justCopied = text
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                    if justCopied == text { justCopied = nil }
                                }
                            }
                        }
                    }
                    .padding(.trailing, 28) // room for the clear button
                }
                .scrollIndicators(.never)
                .overlay(alignment: .topTrailing) {
                    Button {
                        withAnimation(.smooth) { history.clear() }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.gray)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear clipboard history")
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }
}

private struct ClipboardRow: View {
    let text: String
    let copied: Bool
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 6) {
                Text(text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if copied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.white.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Click to copy")
    }
}

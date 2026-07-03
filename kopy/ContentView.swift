import SwiftUI

struct ContentView: View {
    @State private var engine = ClipboardEngine.shared
    @State private var draggingFavID: UUID? = nil
    @State private var favDragOffset: CGFloat = 0
    @FocusState private var focusedFavID: UUID?
    private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            // ── Status bar ──
            statusBar
                .padding(.horizontal, 16)
                .padding(.top, 12)

            // ── Main content ──
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsPanel
                    favoritesPanel
                    historyPanel
                }
                .padding(16)
            }

            // ── Footer ──
            footerBar
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .foregroundStyle(.blue)
                    Text("Kopy")
                        .font(.title3.weight(.semibold))
                }
                .minimumScaleFactor(0.85)
                .frame(minWidth: 200)
            }
        }
        .focusable(false)
        .onTapGesture {
            focusedFavID = nil
        }
        .onAppear {
            focusedFavID = nil
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
                .shadow(color: .green.opacity(0.8), radius: 6)

            Text("Monitoring clipboard")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)

            Spacer()

            Text("\(engine.items.count) items")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Settings

    private var settingsPanel: some View {
        SettingsSection(title: "SETTINGS") {
            VStack(spacing: 10) {
                SettingsSlider(
                    label: "History Depth",
                    value: Binding(
                        get: { Double(settings.historyDepth) },
                        set: { settings.historyDepth = Int($0) }
                    ),
                    range: 5...200,
                    step: 1,
                    format: "%.0f"
                )
                Text("Number of clipboard entries to remember")
                    .font(.caption).foregroundStyle(.secondary)

                SettingsSlider(
                    label: "Overlay Preview",
                    value: Binding(
                        get: { Double(settings.overlayPreviewLength) },
                        set: { settings.overlayPreviewLength = Int($0) }
                    ),
                    range: 3...200,
                    step: 1,
                    format: "%.0f chars"
                )
                Text(settings.overlayPreviewLength <= 8
                     ? "Short preview — good for passwords"
                     : "Characters shown next to dots in the overlay")
                    .font(.caption).foregroundStyle(.secondary)

                SettingsSlider(
                    label: "Menu Bar Preview",
                    value: Binding(
                        get: { Double(settings.menuBarPreviewLength) },
                        set: {
                            settings.menuBarPreviewLength = Int($0)
                            AppDelegate.shared?.updateMenuBarPreview()
                        }
                    ),
                    range: 3...40,
                    step: 1,
                    format: "%.0f chars"
                )
                Text(settings.menuBarPreviewLength <= 8
                     ? "Short — hides sensitive content in menu bar"
                     : "Characters shown next to the icon in the menu bar")
                    .font(.caption).foregroundStyle(.secondary)

                SettingsSlider(
                    label: "Spoke Radius",
                    value: Binding(
                        get: { Double(settings.spokeRadius) },
                        set: { settings.spokeRadius = CGFloat($0) }
                    ),
                    range: 30...160,
                    step: 1,
                    format: "%.0f pt"
                )
                Text("Distance from cursor to numbered dots")
                    .font(.caption).foregroundStyle(.secondary)

                SettingsSlider(
                    label: "Backdrop Spread",
                    value: Binding(
                        get: { settings.overlayBackdropSpread },
                        set: { settings.overlayBackdropSpread = $0 }
                    ),
                    range: 0...1,
                    step: 0.01,
                    format: "%.0f%%"
                )
                Text(settings.overlayBackdropSpread < 0.15
                     ? "Barely there — just a faint blur field behind the overlay"
                     : settings.overlayBackdropSpread < 0.45
                        ? "Soft organic blur that follows the overlay without changing its layout"
                        : "Wider blur field around the spokes and previews")
                    .font(.caption).foregroundStyle(.secondary)

                SettingsSlider(
                    label: "Backdrop Intensity",
                    value: Binding(
                        get: { settings.overlayBackdropIntensity },
                        set: { settings.overlayBackdropIntensity = $0 }
                    ),
                    range: 0...1,
                    step: 0.01,
                    format: "%.0f%%"
                )
                Text(settings.overlayBackdropIntensity < 0.12
                            ? "Very subtle background blur behind the overlay"
                     : settings.overlayBackdropIntensity < 0.35
                                ? "Gentle blur that helps the overlay read clearly"
                                : "Stronger blur separation from busy backgrounds")
                    .font(.caption).foregroundStyle(.secondary)

                SettingsSlider(
                    label: "Overlay Items",
                    value: Binding(
                        get: { Double(settings.overlayItemCount) },
                        set: { settings.overlayItemCount = Int($0) }
                    ),
                    range: 3...15,
                    step: 1,
                    format: "%.0f"
                )
                Text(settings.overlayItemCount <= 5
                     ? "Compact — fewer options, less clutter"
                     : "More options shown in the radial overlay")
                    .font(.caption).foregroundStyle(.secondary)

                Divider()

                HStack {
                    Text("Shortcut")
                        .font(.callout)
                    Spacer()
                    Text(settings.shortcutDisplay)
                        .font(.callout.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    ShortcutRecorderButton()
                }
                Text("Press this shortcut anywhere to show the clipboard overlay")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Favorites

    private let mutedGreen = Color(red: 0.25, green: 0.6, blue: 0.35)

    private var favoritesPanel: some View {
        SettingsSection(title: "FAVORITES") {
            VStack(spacing: 8) {
                if settings.favorites.isEmpty {
                    Text("No favorites yet — add text you paste often")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(settings.favorites.enumerated()), id: \.element.id) { index, fav in
                        let isDragging = draggingFavID == fav.id
                        HStack(spacing: 8) {
                            // Drag grip handle
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 8)
                                        .onChanged { value in
                                            draggingFavID = fav.id
                                            favDragOffset = value.translation.height
                                        }
                                        .onEnded { value in
                                            let rowH: CGFloat = 36
                                            let step = Int(round(value.translation.height / rowH))
                                            let dest = min(max(index + step, 0), settings.favorites.count - 1)
                                            if dest != index {
                                                let item = settings.favorites.remove(at: index)
                                                settings.favorites.insert(item, at: dest)
                                                reorderFavorites()
                                            }
                                            draggingFavID = nil
                                            favDragOffset = 0
                                        }
                                )

                            // Letter badge
                            Text(fav.letter)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(mutedGreen))

                            // Text value (editable)
                            TextField("Value", text: Binding(
                                get: { fav.text },
                                set: { newVal in
                                    if let idx = settings.favorites.firstIndex(where: { $0.id == fav.id }) {
                                        settings.favorites[idx].text = newVal
                                    }
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.callout)
                            .focused($focusedFavID, equals: fav.id)

                            // Letter picker
                            Picker("", selection: Binding(
                                get: { fav.letter },
                                set: { newLetter in
                                    if let idx = settings.favorites.firstIndex(where: { $0.id == fav.id }) {
                                        settings.favorites[idx].letter = newLetter
                                    }
                                }
                            )) {
                                ForEach(availableLetters(current: fav.letter), id: \.self) { letter in
                                    Text(letter).tag(letter)
                                }
                            }
                            .frame(width: 60)

                            // Private toggle
                            Button {
                                if let idx = settings.favorites.firstIndex(where: { $0.id == fav.id }) {
                                    settings.favorites[idx].isPrivate.toggle()
                                }
                            } label: {
                                Image(systemName: fav.isPrivate ? "eye.slash.fill" : "eye")
                                    .foregroundStyle(fav.isPrivate ? mutedGreen : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(fav.isPrivate ? "Private — preview is blurred" : "Click to mark as private")

                            // Delete
                            Button {
                                settings.favorites.removeAll { $0.id == fav.id }
                                reorderFavorites()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .help("Remove favorite")
                        }
                        .padding(.vertical, 2)
                        .offset(y: isDragging ? favDragOffset : 0)
                        .zIndex(isDragging ? 10 : 0)
                        .opacity(isDragging ? 0.85 : 1)
                        .scaleEffect(isDragging ? 1.02 : 1)
                    }
                }

                Button {
                    let order = settings.favorites.count
                    let letter = settings.nextAvailableLetter
                    let newFav = FavoriteItem(text: "", letter: letter, order: order)
                    settings.favorites.append(newFav)
                } label: {
                    Label("Add Favorite", systemImage: "plus.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(mutedGreen)
                }
                .buttonStyle(.plain)
                .help("Add a new favorite paste item")
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func availableLetters(current: String) -> [String] {
        let used = Set(settings.favorites.map { $0.letter })
        return "abcdefghijklmnopqrstuvwxyz".map { String($0) }
            .filter { $0 == current || !used.contains($0) }
    }

    private func reorderFavorites() {
        for i in 0..<settings.favorites.count {
            settings.favorites[i].order = i
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    // MARK: - History list

    private var historyPanel: some View {
        SettingsSection(title: "HISTORY") {
            if engine.items.isEmpty {
                Text("No clipboard history yet — copy some text!")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(engine.items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 20, alignment: .trailing)

                            if item.isImage, let nsImg = item.nsImage {
                                Image(nsImage: nsImg)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(item.text)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(item.text.prefix(60).replacingOccurrences(of: "\n", with: " "))
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }

                            Spacer()

                            Text(relativeTime(item.date))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            engine.selectItem(item)
                        }
                        .help("Click to copy back to clipboard")

                        if index < engine.items.count - 1 {
                            Divider().padding(.leading, 28)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            if let first = engine.items.first {
                Image(systemName: "clipboard")
                    .foregroundStyle(.secondary)
                Text(first.text.prefix(30).replacingOccurrences(of: "\n", with: " "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Copy text to get started")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !engine.items.isEmpty {
                Button {
                    engine.clearHistory()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear all clipboard history")
            }
        }
        .padding(10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Reusable UI components

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(12)
            .glassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

struct SettingsSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    private var displayValue: Double {
        if format.contains("%%") {
            return value * 100
        }
        return value
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
            Spacer()
            Text(String(format: format, displayValue))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        Slider(value: $value, in: range, step: step)
            .tint(.blue)
    }
}

// MARK: - Shortcut recorder

struct ShortcutRecorderButton: View {
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(isRecording ? "Press key…" : "Change") {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        }
        .font(.callout)
        .foregroundStyle(isRecording ? .orange : .blue)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Escape → cancel
                stopRecording()
                return nil
            }
            let settings = AppSettings.shared
            settings.shortcutKeyCode = event.keyCode
            settings.shortcutModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            stopRecording()
            return nil  // swallow the key
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

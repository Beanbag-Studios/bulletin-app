import SwiftUI
import PhotosUI
import MapKit

struct CreateEventView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var location = ""
    @State private var desc = ""
    @State private var eventDate = Date.now.addingTimeInterval(86400)
    @State private var startTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var endTime = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var selectedCategory: Event.Category = .garageSale

    @State private var bannerItem: PhotosPickerItem?
    @State private var bannerImage: UIImage?
    @State private var galleryItems: [PhotosPickerItem] = []
    @State private var galleryImages: [UIImage] = []
    @State private var isSaving = false
    @State private var errorText: String?

    var existingEvent: Event?
    var onCreate: (Event) -> Void
    var onUpdate: (Event) -> Void

    private var isEditing: Bool { existingEvent != nil }

    /// Combines the selected day with the selected start time.
    private var startsAt: Date {
        let calendar = Calendar.current
        let day = calendar.dateComponents([.year, .month, .day], from: eventDate)
        let time = calendar.dateComponents([.hour, .minute], from: startTime)
        var combined = DateComponents()
        combined.year = day.year
        combined.month = day.month
        combined.day = day.day
        combined.hour = time.hour
        combined.minute = time.minute
        return calendar.date(from: combined) ?? eventDate
    }

    private var hasValidTiming: Bool {
        if endTime <= startTime { return false }
        if !isEditing && startsAt <= Date() { return false }
        return true
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !location.trimmingCharacters(in: .whitespaces).isEmpty &&
        !desc.trimmingCharacters(in: .whitespaces).isEmpty &&
        hasValidTiming
    }

    init(existingEvent: Event? = nil, onCreate: @escaping (Event) -> Void, onUpdate: @escaping (Event) -> Void = { _ in }) {
        self.existingEvent = existingEvent
        self.onCreate = onCreate
        self.onUpdate = onUpdate
        if let e = existingEvent {
            _title = State(initialValue: e.title)
            _location = State(initialValue: e.address)
            _desc = State(initialValue: e.description)
            _eventDate = State(initialValue: e.eventDate)
            let fmt = DateFormatter(); fmt.dateFormat = "h:mm a"
            _startTime = State(initialValue: fmt.date(from: e.timeText.components(separatedBy: "–").first?.trimmingCharacters(in: .whitespaces) ?? "") ?? Date())
            _endTime = State(initialValue: fmt.date(from: e.timeText.components(separatedBy: "–").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? Date())
            _selectedCategory = State(initialValue: e.category)
            _bannerImage = State(initialValue: e.bannerImage)
            _galleryImages = State(initialValue: e.galleryImages)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    bannerPicker
                    galleryPicker

                    VStack(alignment: .leading, spacing: 12) {
                        Text(isEditing ? "Edit Event" : "New Event").font(.headline).foregroundStyle(AppTheme.textPrimary)

                        VStack(alignment: .leading, spacing: 6) { Text("Name").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.textSecondary); TextField("Event name", text: $title).textFieldStyle(.plain).padding(.horizontal, 12).padding(.vertical, 10).background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10)) }
                        VStack(alignment: .leading, spacing: 6) { Text("Where").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.textSecondary); TextField("Address or place", text: $location).textFieldStyle(.plain).padding(.horizontal, 12).padding(.vertical, 10).background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10)) }
                        VStack(alignment: .leading, spacing: 6) { Text("Description").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.textSecondary); TextField("Briefly describe the event", text: $desc, axis: .vertical).lineLimit(3...5).textFieldStyle(.plain).padding(.horizontal, 12).padding(.vertical, 10).background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10)) }

                        Picker("Category", selection: $selectedCategory) { ForEach(Event.Category.allCases.filter { $0 != .all }) { cat in Text(cat.rawValue).tag(cat) } }.pickerStyle(.menu).tint(AppTheme.blueMatte)

                        VStack(alignment: .leading, spacing: 6) { Text("Date").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.textSecondary); DatePicker("", selection: $eventDate, displayedComponents: .date).datePickerStyle(.compact).labelsHidden() }
                        VStack(alignment: .leading, spacing: 6) { Text("Time").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.textSecondary); HStack { DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute).labelsHidden(); Text("—").foregroundStyle(AppTheme.textSecondary); DatePicker("", selection: $endTime, displayedComponents: .hourAndMinute).labelsHidden(); Spacer() }; if endTime <= startTime { Text("End time must be after the start time.").font(.caption2).foregroundStyle(.red) } else if !isEditing && startsAt <= Date() { Text("Choose a date and start time in the future.").font(.caption2).foregroundStyle(.red) } }
                    }.padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                    if let errorText { Text(errorText).font(.caption).foregroundStyle(.red) }

                    Button { Task { await save() } } label: { if isSaving { ProgressView().tint(.white) } else { Label(isEditing ? "Save Changes" : "Create Event", systemImage: "arrow.up.circle.fill").font(.subheadline.weight(.bold)) } }.frame(maxWidth: .infinity).padding(.vertical, 12).background(isValid ? AppTheme.blueMatte : Color.gray, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white).disabled(!isValid || isSaving)
                    Color.clear.frame(height: 20)
                }.padding(.horizontal, 16).padding(.top, 16)
            }.scrollBounceBehavior(.basedOnSize).background(Color(.systemBackground)).navigationTitle(isEditing ? "Edit Event" : "New Event").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private var bannerPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Banner image").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.textSecondary)
            PhotosPicker(selection: $bannerItem, matching: .images, photoLibrary: .shared()) {
                ZStack { RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)).frame(height: 180)
                    if let bannerImage { Image(uiImage: bannerImage).resizable().scaledToFill().frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 12)) }
                    else { VStack(spacing: 8) { Image(systemName: "photo.badge.plus").font(.title2).foregroundStyle(AppTheme.textSecondary); Text("Tap to add banner image").font(.subheadline.weight(.medium)).foregroundStyle(AppTheme.textSecondary) } }
                }.clipShape(RoundedRectangle(cornerRadius: 12))
            }.onChange(of: bannerItem) { _, new in Task { if let data = try? await new?.loadTransferable(type: Data.self), let ui = UIImage(data: data) { bannerImage = ui.compress(to: 800) } } }
            if bannerImage != nil { Button("Remove banner", role: .destructive) { bannerImage = nil; bannerItem = nil }.font(.caption) }
        }
    }

    private var galleryPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pictures").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.textSecondary)
            PhotosPicker(selection: $galleryItems, maxSelectionCount: 4, matching: .images, photoLibrary: .shared()) { HStack { Image(systemName: "plus.circle.fill").foregroundStyle(AppTheme.blueMatte); Text(galleryImages.isEmpty ? "Add up to 4 pictures" : "Add / replace pictures").font(.subheadline.weight(.medium)).foregroundStyle(AppTheme.textPrimary); Spacer(); Text("\(galleryImages.count)/4").font(.caption).foregroundStyle(AppTheme.textSecondary) }.padding(10).background(AppTheme.secondaryBG, in: RoundedRectangle(cornerRadius: 10)) }
            .onChange(of: galleryItems) { _, new in Task { var next: [UIImage] = []; for item in new { if let data = try? await item.loadTransferable(type: Data.self), let ui = UIImage(data: data) { next.append(ui.compress(to: 600)) } }; galleryImages = Array(next.prefix(4)) } }
            if !galleryImages.isEmpty {
                ImageCarouselView(images: galleryImages, height: 140, cornerRadius: 10).frame(height: 140)
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { ForEach(Array(galleryImages.enumerated()), id: \.offset) { _, img in Image(uiImage: img).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8)) } } }
                Button("Clear pictures", role: .destructive) { galleryImages = []; galleryItems = [] }.font(.caption)
            }
        }
    }

    private func save() async {
        guard isValid else {
            if endTime <= startTime {
                errorText = "End time must be after the start time."
            } else if !isEditing && startsAt <= Date() {
                errorText = "Choose a date and start time in the future."
            }
            return
        }
        isSaving = true
        defer { isSaving = false }
        errorText = nil

        // Combine the chosen day with the chosen start time so "past vs
        // upcoming" is accurate later the same day.
        let eventStart = startsAt

        let fmtDate = DateFormatter(); fmtDate.dateFormat = "EEE, MMM d"
        let fmtTime = DateFormatter(); fmtTime.dateFormat = "h:mm a"
        let dateText = fmtDate.string(from: eventStart)
        let timeText = "\(fmtTime.string(from: startTime)) – \(fmtTime.string(from: endTime))"

        let bannerB64 = bannerImage?.jpegData(compressionQuality: 0.6)?.base64EncodedString()
        let galleryB64 = galleryImages.compactMap { $0.jpegData(compressionQuality: 0.5)?.base64EncodedString() }

        let trimmedAddress = location.trimmingCharacters(in: .whitespaces)
        let coordinates = await coordinates(for: trimmedAddress)

        let email = FirebaseManager.shared.userEmail ?? ""
        let fallbackName = email.isEmpty ? "You" : (email.components(separatedBy: "@").first ?? "You")
        let organizerName = existingEvent?.organizerName ?? fallbackName
        let organizerInitials = existingEvent?.organizerInitials
            ?? String(organizerName.prefix(2)).uppercased()

        let event = Event(
            id: existingEvent?.id ?? UUID(),
            title: title.trimmingCharacters(in: .whitespaces),
            category: selectedCategory,
            imageSymbol: selectedCategory.icon,
            bannerBase64: bannerB64,
            galleryBase64: galleryB64,
            address: trimmedAddress,
            neighborhood: trimmedAddress,
            latitude: coordinates?.latitude,
            longitude: coordinates?.longitude,
            distance: existingEvent?.distance ?? "0.0 mi",
            dateText: dateText,
            timeText: timeText,
            eventDate: eventStart,
            organizerName: organizerName,
            organizerInitials: organizerInitials,
            description: desc.trimmingCharacters(in: .whitespaces),
            creatorUid: existingEvent?.creatorUid ?? FirebaseManager.shared.uid,
            isFree: existingEvent?.isFree ?? true,
            attendeeCount: existingEvent?.attendeeCount ?? 1
        )

        do {
            if isEditing {
                try await FirebaseManager.shared.updateEvent(event)
                onUpdate(event)
            } else {
                try await FirebaseManager.shared.createEvent(event)
                onCreate(event)
            }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Looks up the address so distance filters can work. Failures are ignored:
    /// the event still saves, it just won't be distance-filterable.
    private func coordinates(for address: String) async -> CLLocationCoordinate2D? {
        guard !address.isEmpty else { return nil }
        return await LocationManager.shared.coordinate(for: address)
    }
}

private extension UIImage { func compress(to maxDimension: CGFloat) -> UIImage { let maxSide = max(size.width, size.height); guard maxSide > maxDimension else { return self }; let scale = maxDimension / maxSide; let newSize = CGSize(width: size.width * scale, height: size.height * scale); let renderer = UIGraphicsImageRenderer(size: newSize); return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) } } }

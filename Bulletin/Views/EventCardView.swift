import SwiftUI

struct EventCardView: View {
    let event: Event
    var friendsGoing: [ContactFriend] = []

    private var friendsLabel: String {
        let names = friendsGoing.prefix(2).map(\.name)
        let extra = friendsGoing.count - names.count
        if extra > 0 {
            return "\(names.joined(separator: ", ")) +\(extra) going"
        }
        return friendsGoing.count == 1
            ? "\(names[0]) is going"
            : "\(names.joined(separator: " & ")) are going"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Group {
                    if !event.allImages.isEmpty {
                        ImageCarouselView(images: event.allImages, height: 160, cornerRadius: 16)
                    } else {
                        Rectangle().fill(AppTheme.gradient(for: event.category))
                            .frame(height: 160)
                            .overlay { Image(systemName: event.imageSymbol).font(.system(size: 44)).foregroundStyle(.white.opacity(0.9)) }
                    }
                }

                HStack {
                    Label(event.category.rawValue, systemImage: event.category.icon)
                        .font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule()).foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                }.padding(10)

                VStack { Spacer()
                    HStack {
                        Label(event.timeText, systemImage: "clock.fill")
                            .font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.white, in: Capsule()).foregroundStyle(.black).shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                        Spacer()
                    }.padding(10)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title).font(.headline).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                        HStack(spacing: 4) {
                            Image(systemName: "mappin.circle.fill").font(.caption2).foregroundStyle(AppTheme.textSecondary)
                            Text(event.address).font(.caption).foregroundStyle(AppTheme.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }

                Text(event.description).font(.subheadline).foregroundStyle(AppTheme.textSecondary).lineLimit(2)

                HStack(spacing: 8) {
                    ZStack { Circle().fill(AppTheme.blueMatte).frame(width: 28, height: 28)
                        Text(event.organizerInitials).font(.caption2.weight(.bold)).foregroundStyle(.white) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.organizerName).font(.caption.weight(.semibold)).foregroundStyle(AppTheme.textPrimary)
                        HStack(spacing: 4) {
                            Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(AppTheme.textSecondary)
                            Text("\(event.attendeeCount) going").font(.caption2).foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    Spacer()
                    Text(event.isFree ? "Free" : "Paid").font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(AppTheme.secondaryBG, in: Capsule())
                }.padding(.top, 4)

                if !friendsGoing.isEmpty {
                    HStack(spacing: 7) {
                        FriendAvatarStack(friends: friendsGoing, size: 24, maxVisible: 3)
                        Text(friendsLabel)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(AppTheme.blueMatte)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppTheme.blueMatte.opacity(0.1), in: Capsule())
                }

                HStack(spacing: 12) {
                    Label(event.dateText, systemImage: "calendar")
                    Label(event.timeText, systemImage: "clock.fill")
                    Spacer()
                    Text("Tap for details").font(.caption2.weight(.medium)).foregroundStyle(AppTheme.textSecondary)
                }.font(.caption).foregroundStyle(AppTheme.textSecondary).padding(.top, 2)
            }.padding(12)
        }
        .background(AppTheme.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.separator, lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
    }
}

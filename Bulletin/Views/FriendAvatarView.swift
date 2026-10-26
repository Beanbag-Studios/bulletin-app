import SwiftUI
import UIKit

/// A circular contact photo with an initials fallback. Photos are read from the
/// local address book and are never uploaded.
struct FriendAvatarView: View {
    let friend: ContactFriend
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let image = friend.avatarImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle()
                        .fill(AppTheme.blueMatte.opacity(0.16))
                    Text(friend.initials)
                        .font(.system(size: size * 0.34, weight: .bold))
                        .foregroundStyle(AppTheme.blueMatte)
                        .minimumScaleFactor(0.6)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(friend.name)
    }
}

/// Overlapping avatar row used on event cards and in the friends section.
struct FriendAvatarStack: View {
    let friends: [ContactFriend]
    var size: CGFloat = 36
    var maxVisible: Int = 5
    var borderColor: Color = AppTheme.white

    private var visible: [ContactFriend] {
        Array(friends.prefix(maxVisible))
    }

    private var overflow: Int {
        max(0, friends.count - visible.count)
    }

    var body: some View {
        HStack(spacing: -size * 0.28) {
            ForEach(visible) { friend in
                FriendAvatarView(friend: friend, size: size)
                    .overlay(
                        Circle().stroke(borderColor, lineWidth: max(1.5, size * 0.06))
                    )
            }

            if overflow > 0 {
                ZStack {
                    Circle()
                        .fill(AppTheme.blueMatteMid)
                    Text("+\(overflow)")
                        .font(.system(size: size * 0.32, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
                .overlay(
                    Circle().stroke(borderColor, lineWidth: max(1.5, size * 0.06))
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            friends.count == 1
                ? "1 friend going"
                : "\(friends.count) friends going"
        )
    }
}

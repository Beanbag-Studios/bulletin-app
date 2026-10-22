import SwiftUI

struct ImageCarouselView: View {
    let images: [UIImage]
    var height: CGFloat = 160
    var cornerRadius: CGFloat = 16

    @State private var current = 0

    var body: some View {
        if images.isEmpty {
            EmptyView()
        } else if images.count == 1 {
            Image(uiImage: images[0])
                .resizable().scaledToFill()
                .frame(height: height).clipped()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            ZStack(alignment: .bottom) {
                TabView(selection: $current) {
                    ForEach(Array(images.enumerated()), id: \.offset) { idx, img in
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(height: height).clipped()
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                HStack(spacing: 6) {
                    ForEach(0..<images.count, id: \.self) { i in
                        Circle()
                            .fill(i == current ? Color.white : Color.white.opacity(0.45))
                            .frame(width: i == current ? 7 : 5, height: i == current ? 7 : 5)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.black.opacity(0.32), in: Capsule())
                .padding(.bottom, 8)

                VStack {
                    HStack {
                        Spacer()
                        Text("\(current + 1)/\(images.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Color.black.opacity(0.32), in: Capsule())
                            .padding(8)
                    }
                    Spacer()
                }
            }
            .frame(height: height)
            .animation(.easeInOut, value: current)
        }
    }
}

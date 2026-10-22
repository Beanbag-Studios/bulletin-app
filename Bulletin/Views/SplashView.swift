import SwiftUI

struct SplashView: View {
    var onFinished: () -> Void

    @State private var written: [Bool] = Array(repeating: false, count: 8)
    @State private var showMark = false
    @State private var scale: CGFloat = 1
    @State private var opacity: CGFloat = 1
    @State private var blur: CGFloat = 0

    private let name = Array("Bulletin")

    var body: some View {
        ZStack {
            AppTheme.offWhite.ignoresSafeArea()

            VStack(spacing: 28) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.blueMatte)
                        .frame(width: 64, height: 64)
                        .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
                    Image(systemName: "pin.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                }
                .scaleEffect(showMark ? 1 : 0.72)
                .opacity(showMark ? 1 : 0)
                .animation(.spring(response: 0.55, dampingFraction: 0.72), value: showMark)

                HStack(spacing: 1) {
                    ForEach(Array(name.enumerated()), id: \.offset) { idx, ch in
                        Text(String(ch))
                            .font(.system(size: 52, weight: .heavy, design: .rounded))
                            .tracking(-1.2)
                            .foregroundStyle(AppTheme.blueMatte)
                            .opacity(written[idx] ? 1 : 0)
                            .offset(y: written[idx] ? 0 : 8)
                            .animation(.spring(response: 0.34, dampingFraction: 0.78).delay(Double(idx) * 0.075), value: written[idx])
                    }
                }
                .frame(height: 60)
            }
            .padding(.horizontal, 24)
            .scaleEffect(scale)
            .blur(radius: blur)
            .opacity(opacity)
        }
        .onAppear { runSequence() }
    }

    private func runSequence() {
        withAnimation { showMark = true }
        for i in written.indices {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14 + Double(i) * 0.075) { written[i] = true }
        }
        let totalWrite = 0.14 + Double(name.count) * 0.075 + 0.7
        DispatchQueue.main.asyncAfter(deadline: .now() + totalWrite) {
            withAnimation(.easeIn(duration: 0.7)) { scale = 12; blur = 16; opacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.58) { onFinished() }
        }
    }
}

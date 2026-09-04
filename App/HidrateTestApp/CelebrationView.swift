import SwiftUI
import UIKit

/// Confetti and a banner for reaching the daily goal. Dismisses itself after a few
/// seconds or on tap. Honors Reduce Motion by showing just the banner.
struct CelebrationView: View {
    @Binding var isPresented: Bool
    let message: String

    @State private var particles = ConfettiField()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion {
                TimelineView(.animation) { context in
                    Canvas { g, size in
                        particles.step(to: context.date, in: size)
                        for p in particles.items {
                            var t = g
                            t.translateBy(x: p.x, y: p.y)
                            t.rotate(by: .radians(p.rotation))
                            t.opacity = p.opacity
                            let rect = CGRect(x: -p.size / 2, y: -p.size / 3, width: p.size, height: p.size / 1.5)
                            t.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(p.color))
                        }
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            VStack(spacing: 10) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .symbolEffect(.bounce, value: isPresented)
                Text("Goal reached!")
                    .font(.system(.title, design: .rounded).weight(.bold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(radius: 20, y: 8)
            .transition(.scale.combined(with: .opacity))
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .task {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            try? await Task.sleep(for: .seconds(4))
            dismiss()
        }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.3)) { isPresented = false }
    }
}

/// A tiny particle system: pieces burst from the top, tumble under gravity, and fade.
@MainActor
final class ConfettiField {
    struct Piece {
        var x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat
        var rotation: Double, spin: Double
        var size: CGFloat, color: Color, opacity: Double, born: TimeInterval
    }
    private(set) var items: [Piece] = []
    private var lastDate: Date?
    private var spawned = false
    private let palette: [Color] = [.blue, .cyan, .mint, .yellow, .orange, .pink, .purple, .green]

    func step(to date: Date, in size: CGSize) {
        defer { lastDate = date }
        if !spawned {
            spawned = true
            items = (0..<140).map { _ in
                Piece(x: CGFloat.random(in: 0...size.width), y: -CGFloat.random(in: 0...80),
                      vx: CGFloat.random(in: -60...60), vy: CGFloat.random(in: 40...160),
                      rotation: Double.random(in: 0...(2 * .pi)), spin: Double.random(in: -6...6),
                      size: CGFloat.random(in: 6...11), color: palette.randomElement()!,
                      opacity: 1, born: date.timeIntervalSinceReferenceDate)
            }
        }
        guard let lastDate else { return }
        let dt = min(date.timeIntervalSince(lastDate), 0.05)
        let now = date.timeIntervalSinceReferenceDate
        for i in items.indices {
            items[i].vy += 420 * dt
            items[i].vx *= 0.995
            items[i].x += items[i].vx * dt
            items[i].y += items[i].vy * dt
            items[i].rotation += items[i].spin * dt
            let age = now - items[i].born
            items[i].opacity = age > 2.5 ? max(0, 1 - (age - 2.5) / 1.2) : 1
        }
        items.removeAll { $0.y > size.height + 40 || $0.opacity <= 0 }
    }
}

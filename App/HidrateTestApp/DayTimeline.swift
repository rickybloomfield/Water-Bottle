import SwiftUI

/// The days either side of the one being looked at. Scroll it and it settles on a day,
/// which becomes the day on screen — no tap needed, though tapping works too.
struct DayTimeline: View {
    @Namespace private var highlight

    var days: [Date]
    @Binding var selected: Date
    /// Chosen from the strip rather than swiped to; the screen animates it the same way.
    var onPick: (Date) -> Void
    /// 0…1 as the day's drinks scroll up beneath, which fades in the line under the strip.
    var scrolledUnder: CGFloat = 0

    /// Which day the strip has come to rest on. Kept apart from `selected` so a scroll
    /// settling and a page swipe can each drive the other without chasing their own tail.
    @State private var settledOn: Date?

    private var calendar: Calendar { .current }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(days, id: \.self) { day in
                        chip(day).id(day)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 10)
            }
            // Half the width either side, so the first and last days can come to rest in
            // the middle as well. Applied outside the target layout so it doesn't become
            // something the scroll can stop on.
            .safeAreaPadding(.horizontal, proxy.size.width / 2)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $settledOn, anchor: .center)
            .onAppear { settledOn = selected }
            .onChange(of: settledOn) { _, day in
                guard let day, !calendar.isDate(day, inSameDayAs: selected) else { return }
                onPick(day)
            }
            .onChange(of: selected) { _, day in
                guard settledOn.map({ !calendar.isDate($0, inSameDayAs: day) }) ?? true else { return }
                withAnimation(.snappy(duration: 0.25)) { settledOn = day }
            }
        }
        .frame(height: 52)
        // Opaque and the same colour the navigation bar resolves to, rather than a
        // material of its own: two materials over different things do not match, which
        // is what left a seam between the strip and the bar above it.
        .background(Color(.systemBackground))
        // A line under the bottom edge only, arriving as the day's drinks begin to pass
        // beneath it. Nothing goes behind the strip's sides or its top.
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.black.opacity(0.12 * scrolledUnder), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 7)
                .offset(y: 7)
                .allowsHitTesting(false)
        }
    }

    private func chip(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        return Button {
            onPick(day)
        } label: {
            Text(Self.label(day))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    // One capsule for the whole strip, handed from day to day, so it
                    // travels rather than appearing somewhere else.
                    if isSelected {
                        Capsule()
                            .fill(Color.accentColor)
                            .matchedGeometryEffect(id: "selectedDay", in: highlight)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // On the chips rather than the row: the strip's own scrolling animates itself,
        // and driving both from one place made the highlight stutter against it.
        .animation(.snappy(duration: 0.25), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// "Today", "Yesterday", "Sep 2", and the year as well once it isn't this one.
    static func label(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if calendar.component(.year, from: day) == calendar.component(.year, from: Date()) {
            return day.formatted(.dateTime.month(.abbreviated).day())
        }
        return day.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

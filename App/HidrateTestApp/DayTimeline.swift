import SwiftUI

/// The days either side of the one being looked at, so swiping has somewhere visible to
/// go. Newest on the right, which is the direction the Today tab pages in.
struct DayTimeline: View {
    @Namespace private var highlight

    var days: [Date]
    @Binding var selected: Date
    /// Chosen from the strip rather than swiped to; the screen animates it the same way.
    var onPick: (Date) -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(days, id: \.self) { day in
                            chip(day).id(day)
                        }
                    }
                    // Drives the highlight from one day to the next. The page swipe sets
                    // the day without an animation of its own, so this supplies it.
                    .animation(.snappy(duration: 0.25), value: selected)
                    // Half the width either side, so the first and last days can sit in
                    // the middle too. Without it the selected day is stuck against
                    // whichever edge it happens to be near — and the one you are on is
                    // usually today, which is the last.
                    .padding(.horizontal, proxy.size.width / 2)
                    .padding(.vertical, 10)
                }
                .onAppear { scroller.scrollTo(selected, anchor: .center) }
                .onChange(of: selected) { _, day in
                    withAnimation(.snappy) { scroller.scrollTo(day, anchor: .center) }
                }
            }
        }
        .frame(height: 52)
        // The same material the navigation bar uses, so the two read as one surface.
        .background(.bar)
    }

    private func chip(_ day: Date) -> some View {
        let isSelected = Calendar.current.isDate(day, inSameDayAs: selected)
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
                    // slides rather than appearing somewhere else.
                    if isSelected {
                        Capsule()
                            .fill(Color.accentColor)
                            .matchedGeometryEffect(id: "selectedDay", in: highlight)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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

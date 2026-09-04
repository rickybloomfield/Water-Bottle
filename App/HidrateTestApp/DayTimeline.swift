import SwiftUI

/// The days either side of the one being looked at, so swiping has somewhere visible to
/// go. Newest on the right, which is the direction the Today tab pages in.
struct DayTimeline: View {
    var days: [Date]
    @Binding var selected: Date

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(days, id: \.self) { day in
                        chip(day).id(day)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
            .onChange(of: selected) { _, day in
                withAnimation(.snappy) { proxy.scrollTo(day, anchor: .center) }
            }
        }
        .background(.bar)
    }

    private func chip(_ day: Date) -> some View {
        let isSelected = Calendar.current.isDate(day, inSameDayAs: selected)
        return Button {
            withAnimation(.snappy) { selected = day }
        } label: {
            Text(Self.label(day))
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.14),
                            in: Capsule())
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

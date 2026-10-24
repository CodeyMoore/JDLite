import ActivityKit
import SwiftUI
import WidgetKit

@main
struct JDLiteWidgets: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivity()
    }
}

private enum Brand {
    static let cyan = Color(red: 0.17, green: 0.82, blue: 1.0)     // #2BD2FF
    static let blue = Color(red: 0.24, green: 0.42, blue: 0.95)    // #3E6BF2
    static let violet = Color(red: 0.42, green: 0.17, blue: 0.88)  // #6A2BE0
    static let gradient = LinearGradient(colors: [cyan, blue, violet],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

private typealias State = DownloadActivityAttributes.ContentState

private extension DownloadActivityAttributes.ContentState.Phase {
    var glyph: String {
        switch self {
        case .downloading: return "arrow.down"
        case .fetching: return "cloud.fill"
        case .paused: return "pause.fill"
        case .finished: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }

    var color: Color {
        switch self {
        case .downloading: return Brand.blue
        case .fetching: return .purple
        case .paused: return .gray
        case .finished: return .green
        case .failed: return .orange
        }
    }
}

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding(16)
                .activitySystemActionForegroundColor(Brand.blue)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: context.state.phase, size: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.percentText)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        BarView(state: context.state)
                        DetailLine(state: context.state)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.phase == .downloading ? "arrow.down.circle.fill"
                                                                      : context.state.phase.glyph)
                    .foregroundStyle(context.state.phase == .downloading ? Brand.cyan : context.state.phase.color)
            } compactTrailing: {
                Text(context.state.percentText)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
            } minimal: {
                RingView(state: context.state)
            }
            .keylineTint(Brand.cyan)
        }
    }
}

private struct LockScreenView: View {
    let state: State

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            PhaseIcon(phase: state.phase, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(state.percentText)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                BarView(state: state)
                DetailLine(state: state)
            }
        }
    }
}

/// The app icon's look: a rounded square with the glyph for the current phase.
private struct PhaseIcon: View {
    let phase: State.Phase
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(phase == .downloading ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(phase.color))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: phase.glyph)
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

private struct BarView: View {
    let state: State

    var body: some View {
        Group {
            if state.phase == .downloading, let start = state.timerStart, let end = state.timerEnd, start < end {
                ProgressView(timerInterval: start...end, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: min(max(state.progress, 0), 1))
            }
        }
        .progressViewStyle(.linear)
        .tint(state.phase.color)
    }
}

private struct RingView: View {
    let state: State

    var body: some View {
        Group {
            if state.phase == .downloading, let start = state.timerStart, let end = state.timerEnd, start < end {
                ProgressView(timerInterval: start...end, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: min(max(state.progress, 0), 1))
            }
        }
        .progressViewStyle(.circular)
        .tint(state.phase == .downloading ? Brand.cyan : state.phase.color)
    }
}

private struct DetailLine: View {
    let state: State

    var body: some View {
        let now = Date()
        HStack(spacing: 4) {
            Text(state.detail)
                .lineLimit(1)
            if state.phase == .downloading, let end = state.timerEnd, end > now {
                Text("·")
                Text(timerInterval: now...end, countsDown: true)
                    .monospacedDigit()
                Text("left")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DigistbanWidgetBundle: WidgetBundle {
    var body: some Widget {
        UploadLiveActivity()
    }
}

/// A transfer being sent or a file being downloaded: Lock Screen banner and
/// Dynamic Island, with a progress ring around the arrow.
struct UploadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UploadActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: context.state.link))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ProgressRing(state: context.state, kind: context.attributes.kind, size: 46, line: 5)
                        .padding(.leading, 6)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percent(context.state))
                        .font(.title2.weight(.bold).monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(tint(context.state.status))
                        .padding(.trailing, 6)
                        .padding(.top, 10)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.title ?? context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: context.state.fraction)
                            .tint(tint(context.state.status))
                        Text(context.state.detail)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            } compactLeading: {
                ProgressRing(state: context.state, kind: context.attributes.kind, size: 22, line: 3)
            } compactTrailing: {
                Text(percent(context.state))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .contentTransition(.numericText())
                    .foregroundStyle(tint(context.state.status))
            } minimal: {
                ProgressRing(state: context.state, kind: context.attributes.kind, size: 22, line: 3)
            }
            .widgetURL(URL(string: context.state.link))
            .keylineTint(tint(context.state.status))
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<UploadActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ProgressRing(state: context.state, kind: context.attributes.kind, size: 48, line: 5)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(context.state.title ?? context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(percent(context.state))
                        .font(.headline.monospacedDigit())
                        .contentTransition(.numericText())
                }
                ProgressView(value: context.state.fraction)
                    .tint(tint(context.state.status))
                Text("\(context.state.label) · \(context.state.detail)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .foregroundStyle(.white)
    }
}

/// The arrow (or the result) inside a ring that fills with the progress.
private struct ProgressRing: View {
    let state: UploadActivityAttributes.ContentState
    let kind: String
    let size: CGFloat
    let line: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.22), lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.03, state.fraction))
                .stroke(tint(state.status), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: glyph)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(tint(state.status))
        }
        .frame(width: size, height: size)
    }

    private var glyph: String {
        switch state.status {
        case "completed": return "checkmark"
        case "failed": return "exclamationmark"
        case "paused": return "pause.fill"
        case "cancelled": return "xmark"
        default: return kind == "download" ? "arrow.down" : "arrow.up"
        }
    }
}

private func tint(_ status: String) -> Color {
    switch status {
    case "completed": return Color(red: 0.2, green: 0.84, blue: 0.4)
    case "failed", "cancelled": return Color(red: 1, green: 0.32, blue: 0.3)
    case "paused": return Color(red: 1, green: 0.72, blue: 0.2)
    default: return .white
    }
}

private func percent(_ state: UploadActivityAttributes.ContentState) -> String {
    "\(Int((state.fraction * 100).rounded(.down))) %"
}

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DigistbanWidgetBundle: WidgetBundle {
    var body: some Widget {
        UploadLiveActivity()
    }
}

/// A transfer being sent: Lock Screen banner and Dynamic Island.
struct UploadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UploadActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: context.state.link))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusSymbol(status: context.state.status, kind: context.attributes.kind)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percent(context.state))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title ?? context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: context.state.fraction)
                            .tint(.white)
                        Text("\(context.state.label) · \(context.state.detail)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                StatusSymbol(status: context.state.status, kind: context.attributes.kind)
            } compactTrailing: {
                Text(percent(context.state))
                    .font(.caption2.weight(.semibold).monospacedDigit())
            } minimal: {
                Gauge(value: context.state.fraction) {
                    EmptyView()
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(.white)
            }
            .widgetURL(URL(string: context.state.link))
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<UploadActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            StatusSymbol(status: context.state.status, kind: context.attributes.kind)
                .font(.system(size: 30))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(context.state.title ?? context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(percent(context.state))
                        .font(.headline.monospacedDigit())
                }
                ProgressView(value: context.state.fraction)
                    .tint(.white)
                Text("\(context.state.label) · \(context.state.detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .foregroundStyle(.white)
    }
}

private struct StatusSymbol: View {
    let status: String
    let kind: String

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(status == "failed" ? Color.red : Color.white)
    }

    private var symbol: String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.circle.fill"
        case "paused": return "pause.circle.fill"
        case "cancelled": return "xmark.circle.fill"
        default: return kind == "download" ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
        }
    }
}

private func percent(_ state: UploadActivityAttributes.ContentState) -> String {
    "\(Int((state.fraction * 100).rounded(.down))) %"
}

import SwiftUI
import NeoDropCore

/// The activity window: what NeoDrop is doing now, and what it has done recently.
///
/// Layout only. The filtering, the titles and the footer come from `ActivityFeed`, which is where
/// they can be tested — a view that decides what the log means is a view whose mistakes are only
/// visible to whoever is looking at it at the time.
struct SyncActivityView: View {
    @ObservedObject var model: AppModel
    @State private var searchText = ""
    @State private var scope: ActivityFeed.Scope = .you

    private var entries: [ActivityFeed.Row] {
        ActivityFeed.rows(from: model.activity, scope: scope, query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search activity", text: $searchText).textFieldStyle(.plain).font(.title3)
                Button { model.refreshActivity() } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh activity")
            }
            .padding(16)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20).padding(.top, 20)

            HStack(spacing: 28) {
                scopeButton("You", scope: .you)
                scopeButton("Shared", scope: .shared)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 12)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(ActivityFeed.sectionTitle(isBusy: model.isBusy))
                        .font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, 22).padding(.bottom, 10)
                    if let running = ActivityFeed.inFlight(isBusy: model.isBusy, progress: model.progress) {
                        progressRow(running)
                    }
                    if entries.isEmpty {
                        ContentUnavailableView("No recent activity", systemImage: "doc.text",
                                               description: Text("Sync updates and completed work will appear here."))
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        ForEach(entries) { row($0) }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 16)
            }
            Divider()
            HStack(spacing: 12) {
                Image(systemName: model.isBusy ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                    .font(.title2).foregroundStyle(model.isBusy ? Color.accentColor : .secondary)
                Text(model.isBusy ? model.statusTitle : model.lastSyncDescription)
                    .fontWeight(.semibold).lineLimit(1)
                if model.isBusy { Image(systemName: "chevron.down").font(.caption.weight(.bold)) }
                Spacer(minLength: 12)
                Text(ActivityFeed.footer(isBusy: model.isBusy, progress: model.progress, fallback: model.redundancyLine))
                    .fontWeight(.medium).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 22).padding(.vertical, 15).background(.bar)
        }
        .frame(minWidth: 580, idealWidth: 720, minHeight: 460, idealHeight: 690)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .onAppear { model.refreshActivity() }
    }

    private func scopeButton(_ title: String, scope buttonScope: ActivityFeed.Scope) -> some View {
        Button { scope = buttonScope } label: {
            VStack(spacing: 10) {
                Text(title).fontWeight(scope == buttonScope ? .semibold : .regular)
                    .foregroundStyle(scope == buttonScope ? .primary : .secondary)
                Rectangle().fill(scope == buttonScope ? Color.accentColor : .clear).frame(height: 3)
            }.fixedSize()
        }.buttonStyle(.plain)
    }

    private func progressRow(_ running: ActivityFeed.InFlight) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "doc.fill").font(.system(size: 34)).foregroundStyle(.secondary).frame(width: 52)
            VStack(alignment: .leading, spacing: 8) {
                Text(running.title)
                    .fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text(running.detail)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                ProgressView(value: running.fraction).tint(.accentColor)
            }
        }
        .padding(.vertical, 14).accessibilityElement(children: .combine)
    }

    private func row(_ entry: ActivityFeed.Row) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: entry.mark == .problem ? "exclamationmark.doc.fill" : "doc.fill")
                .font(.system(size: 34)).foregroundStyle(.secondary).frame(width: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text(entry.detail)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                if entry.isComplete { ProgressView(value: 1).tint(.accentColor) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13).accessibilityElement(children: .combine)
    }
}

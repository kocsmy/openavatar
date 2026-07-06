import SwiftUI

/// Transparency + control over the compounding memory: see every fact the
/// assistant holds, retire anything wrong, or wipe memory entirely.
struct MemorySettingsTab: View {
    @EnvironmentObject var app: AppState
    @State private var facts: [MemoryFact] = []
    @State private var digests: [String] = []
    @State private var confirmWipe = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What \(SettingsStore.shared.assistantName) knows about you")
                .font(.headline)
            Text("Distilled from your calls, used to detect and plan actions with better context. Everything here is local; retire anything that's wrong.")
                .font(.caption).foregroundStyle(.secondary)

            if facts.isEmpty && digests.isEmpty {
                ContentUnavailableView("No memory yet", systemImage: "brain",
                                       description: Text("Facts appear here after your first call."))
            } else {
                List {
                    ForEach(FactCategory.allCases, id: \.self) { category in
                        let inCategory = facts.filter { $0.category == category }
                        if !inCategory.isEmpty {
                            Section(category.displayName) {
                                ForEach(inCategory) { fact in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(fact.content).font(.callout)
                                            Text("salience \(fact.salience, specifier: "%.1f") · reinforced \(fact.lastReinforcedAt.formatted(date: .abbreviated, time: .omitted))")
                                                .font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                        Button {
                                            try? app.store.retireFact(id: fact.id)
                                            load()
                                        } label: { Image(systemName: "trash") }
                                            .buttonStyle(.borderless)
                                            .help("Retire this fact")
                                    }
                                }
                            }
                        }
                    }
                    if !digests.isEmpty {
                        Section("Recent call digests") {
                            ForEach(digests, id: \.self) { digest in
                                Text(digest).font(.caption)
                            }
                        }
                    }
                }
            }

            HStack {
                Button("Refresh") { load() }
                Spacer()
                Button("Forget everything", role: .destructive) { confirmWipe = true }
            }
        }
        .padding()
        .onAppear { load() }
        .confirmationDialog("Retire all memory facts and digests? Calls, decisions, and metrics are kept.",
                            isPresented: $confirmWipe) {
            Button("Forget everything", role: .destructive) {
                for fact in facts { try? app.store.retireFact(id: fact.id) }
                load()
            }
        }
    }

    private func load() {
        facts = (try? app.store.activeFacts()) ?? []
        digests = (try? app.store.recentDigests(limit: 5)) ?? []
    }
}

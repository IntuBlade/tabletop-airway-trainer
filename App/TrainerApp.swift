import SwiftUI

let trainerActionFill = Color(red: 0, green: 0.36, blue: 0.34)

let trainerTint = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.34, green: 0.83, blue: 0.78, alpha: 1)
        : UIColor(red: 0.00, green: 0.36, blue: 0.34, alpha: 1)
})

@main struct TrainerApp: App {
    init() {
        #if canImport(BaseCamera)
        TrainerBlade.shared.start()
        #endif
    }
    var body: some Scene {
        WindowGroup {
            #if DEBUG && canImport(BaseCamera)
            if ProcessInfo.processInfo.arguments.contains("--blade-setup") {
                NavigationStack { LiveBladeMotion() }
            } else {
                TrainerHome()
            }
            #else
            TrainerHome()
            #endif
        }
    }
}

private struct TrainerHome: View {
    @AppStorage("trainer-reps") private var savedReps = Data()
    @State private var showingClear = false

    private var history: [CompletedRep] {
        (try? JSONDecoder().decode([CompletedRep].self, from: savedReps)) ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image("TrainingTable")
                        .resizable()
                        .scaledToFit()
                        .clipShape(.rect(cornerRadius: 14))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Find the view. Get it back.").font(.title2.bold())
                        Text("Use the blade camera to place the head and practice, or play the recorded exercise.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 12) {
                        #if canImport(BaseCamera)
                        NavigationLink { LiveBladeMotion() } label: {
                            Label("Place head with blade", systemImage: "viewfinder")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent).tint(trainerActionFill)
                        #endif
                        NavigationLink {
                            RecordedPractice { rep in
                                if let data = try? JSONEncoder().encode(Array(([rep] + history).prefix(2))) {
                                    savedReps = data
                                }
                            }
                        } label: {
                            Label("Try recorded practice", systemImage: "play.rectangle")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered)
                    }

                    if !history.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recent practice").font(.headline)
                            ForEach(history) { rep in
                                NavigationLink {
                                    PracticeReview(rep: rep)
                                } label: {
                                    Label(rep.date.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                                        .frame(minHeight: 44)
                                }
                            }
                            Button("Clear practice history", role: .destructive) { showingClear = true }
                                .frame(minHeight: 44)
                        }
                    }
                }
                .frame(maxWidth: 600)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Airway practice")
            .tint(trainerTint)
            .confirmationDialog("Clear the saved practice reps?", isPresented: $showingClear, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) { savedReps = Data() }
            }
        }
    }
}

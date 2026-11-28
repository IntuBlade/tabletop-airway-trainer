import Foundation
import SwiftUI
#if canImport(FirebaseAILogic) && canImport(FirebaseAppCheck)
import FirebaseAILogic
import FirebaseAppCheck
import FirebaseCore
#endif

struct CoachRequest {
    let prompt: String
    let approvedKeys: [String: String]

    init(rep: CompletedRep, path: PracticePath) {
        self.init(result: path.recovery(first: rep.first, last: rep.recovered),
                  references: [path.frames[rep.first].opening, path.frames[rep.recovered].opening],
                  answers: rep.answers)
    }

    /// A guided rep reaches review only after the learner lost a useful view and marked one again.
    init(guided rep: GuidedRep) {
        self.init(result: .recovered, references: [rep.first?.opening, rep.recovered?.opening], answers: rep.answers)
    }

    private init(result: Recovery, references: [Opening?], answers: [StillAnswer]) {
        let first = references[0]?.band ?? "ambiguous"
        let second = references[1]?.band ?? "ambiguous"
        let firstEstimate = answers[0].estimate?.band ?? "unknown"
        let secondEstimate = answers[1].estimate?.band ?? "unknown"
        approvedKeys = [
            "compare": "Compare the marked ranges with the reference for each frame. The first reference is \(first). The second is \(second).",
            "movement": result == .recovered
                ? "The opening disappeared and returned. On the next rep, see if you can recover it at a different angle."
                : "Make the loss of view clear before you mark the return on the next rep."
        ]
        prompt = """
        Choose the best focus for one more synthetic, non-clinical practice rep. Return only one key: compare or movement.
        compare means review the two marked opening ranges. movement means practice losing and recovering the simulated view.
        Movement outcome: \(result.rawValue).
        First mark estimate and reference: \(firstEstimate), \(first).
        Second mark estimate and reference: \(secondEstimate), \(second).
        """
    }
}

struct CoachResult {
    enum Route: String { case onDevice = "On-device coaching", cloud = "Cloud coaching" }
    let text: String
    let route: Route
}

@MainActor enum FirebaseCoach {
    static var isConfigured: Bool {
        #if canImport(FirebaseAILogic) && canImport(FirebaseAppCheck)
        configURL != nil
        #else
        false
        #endif
    }

    static func coach(_ request: CoachRequest, allowCloud: Bool) async -> CoachResult? {
        #if canImport(FirebaseAILogic) && canImport(FirebaseAppCheck)
        guard !Task.isCancelled, let ai else { return nil }
        let system = FirebaseAI.SystemLanguageModel.default
        do {
            let session: GenerativeModelSession
            if allowCloud {
                let cloud = ai.geminiModel(name: "gemini-3.1-flash-lite")
                session = ai.generativeModelSession(model: .hybridModel(primary: system, secondary: cloud))
            } else {
                guard system.isAvailable else { return nil }
                session = ai.generativeModelSession(model: system)
            }
            let response = try await session.respond(to: request.prompt)
            guard !Task.isCancelled,
                  let text = request.approvedKeys[response.content.trimmingCharacters(in: .whitespacesAndNewlines)] else {
                return nil
            }
            let route: CoachResult.Route
            if response.rawResponse.modelVersion == "apple-foundation-models-system-language-model" {
                route = .onDevice
            } else {
                guard allowCloud, response.rawResponse.modelVersion.hasPrefix("gemini-") else { return nil }
                route = .cloud
            }
            return CoachResult(text: text, route: route)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(FirebaseAILogic) && canImport(FirebaseAppCheck)
    private static let projectName = "TrainerResearch"
    private static var configURL: URL? { Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") }

    private static let ai: FirebaseAI? = {
        guard let configURL, let options = FirebaseOptions(contentsOfFile: configURL.path),
              options.bundleID == Bundle.main.bundleIdentifier,
              options.apiKey?.isEmpty == false, options.projectID?.isEmpty == false else { return nil }
        // A research build carries an App Check debug token that is registered in
        // the Firebase console. The debug provider reads it from this defaults key.
        let debugToken = NSDictionary(contentsOf: configURL)?["APP_CHECK_DEBUG_TOKEN"] as? String
        if let debugToken { UserDefaults.standard.set(debugToken, forKey: "GACAppCheckDebugToken") }
        #if targetEnvironment(simulator)
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        if debugToken == nil {
            AppCheck.setAppCheckProviderFactory(AppAttestProviderFactory())
        } else {
            AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        }
        #endif
        FirebaseApp.configure(name: projectName, options: options)
        guard let app = FirebaseApp.app(name: projectName) else { return nil }
        return FirebaseAI.firebaseAI(app: app, backend: .googleAI())
    }()
    #endif
}

struct CoachRequestID: Equatable {
    let allowCloud: Bool
}

/// Coaching for one reviewed rep. The iPhone's own model answers first. The
/// learner has to allow the cloud model separately for each rep.
struct CoachPanel: View {
    let coachRequest: CoachRequest
    @State private var askingCloud = false
    @State private var pending: CoachRequestID?
    @State private var coaching: CoachResult?
    @State private var attempted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let coaching {
                Text(coaching.route.rawValue).font(.subheadline.bold())
                Text(coaching.text)
            } else if attempted {
                Text("Coaching unavailable. Use the next-rep objective above.").foregroundStyle(.secondary)
            }
            if pending != nil { ProgressView("Checking coaching") }
            Button("Coach on this iPhone") { pending = CoachRequestID(allowCloud: false) }
                .disabled(pending != nil)
                .frame(minHeight: 44)
            Button("Allow cloud fallback") { askingCloud = true }
                .disabled(pending != nil)
                .frame(minHeight: 44)
        }
        .task(id: pending) {
            guard let pending else { return }
            let result = await FirebaseCoach.coach(coachRequest, allowCloud: pending.allowCloud)
            guard !Task.isCancelled else { return }
            coaching = result
            attempted = true
            self.pending = nil
        }
        .confirmationDialog("Allow cloud coaching for this rep?", isPresented: $askingCloud, titleVisibility: .visible) {
            Button("Allow for this rep") { pending = CoachRequestID(allowCloud: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If the iPhone model is unavailable, Firebase receives the synthetic practice outcome and the marked and reference ranges.")
        }
    }
}

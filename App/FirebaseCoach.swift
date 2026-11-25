import Foundation
#if canImport(FirebaseAILogic) && canImport(FirebaseAppCheck)
import FirebaseAILogic
import FirebaseAppCheck
import FirebaseCore
#endif

struct CoachRequest {
    let prompt: String
    let approvedKeys: [String: String]

    init(rep: CompletedRep, path: PracticePath) {
        let result = path.recovery(first: rep.first, last: rep.recovered)
        let first = path.frames[rep.first].opening?.band ?? "ambiguous"
        let second = path.frames[rep.recovered].opening?.band ?? "ambiguous"
        let firstEstimate = rep.answers[0].estimate?.band ?? "unknown"
        let secondEstimate = rep.answers[1].estimate?.band ?? "unknown"
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
        #if targetEnvironment(simulator)
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        AppCheck.setAppCheckProviderFactory(AppAttestProviderFactory())
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

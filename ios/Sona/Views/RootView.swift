import SwiftUI

/// Onboarding the first time (existing installs too), then Home. The alert the model asks for lives here, so any
/// screen can use it.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.onboardingDone {
                HomeView()
            } else {
                OnboardingView(start: model.onboardingStart, notesChoice: model.defaultNotesChoice, audioPolicy: model.defaultAudioPolicy)
            }
        }
        .alert("Something went wrong", isPresented: problemShown) {
            Button("OK") { model.problem = nil }
        } message: {
            Text(model.problem ?? "")
        }
    }

    private var problemShown: Binding<Bool> {
        Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
    }
}

import SwiftUI

/// Sona's privacy policy, in the app (App Review 5.1.1(i) wants a link to it inside the app). The text is here, in
/// one place, so it changes with the code.
enum PrivacyPolicy {
    /// Where the policy is published, once it is. Settings shows a web link only once this is set.
    static let url: URL? = URL(string: "https://dinilb.github.io/sona/privacy.html")

    static let updated = "8 November 2026"

    struct Section: Identifiable {
        var title: String
        var body: String
        var id: String { title }
    }

    static let sections: [Section] = [
        Section(title: "In short",
                body: "Sona has no account, no analytics, no ads and no tracking. Your recordings and notes stay on your devices and, if you choose it, in your own iCloud. Nothing about them is sent to us."),
        Section(title: "What stays on this iPhone",
                body: "Your recordings (the audio), the notes Sona writes from them (the text, a title and, if you allow location, a street name), and your settings. Sona turns speech into text on this iPhone with a speech model it downloads once. Titles come from Apple's on-device model where your iPhone has one."),
        Section(title: "Where your notes go",
                body: "You choose. iCloud: notes go into Sona's folder in your own iCloud Drive, where Apple's iCloud terms apply (with Advanced Data Protection they're end-to-end encrypted), and to your other devices signed in to it. On this iPhone: notes stay in a folder on this iPhone, and in its iCloud Backup if that's on. Other folder: a folder you pick in the Files app, which goes wherever that folder goes. If you use Sona for Mac, it copies the notes it finds in iCloud onto your Mac."),
        Section(title: "The app's log",
                body: "Sona keeps a short log of what it did on this iPhone (a recording started or stopped, a note was written, errors by their code), to help work out problems. It never holds your words, titles, file names or places. When your notes go to iCloud, a copy of its newest part (about 256 KB) is kept in Sona's folder in your own iCloud Drive, so you can read it on your Mac or in the Files app. It goes nowhere else, and choosing On this iPhone or another folder deletes that copy from iCloud."),
        Section(title: "What goes over the network",
                body: "Two things. Once, the speech model (about 480 MB) downloads from Hugging Face (huggingface.co), which sees your IP address and the download, never your recordings. And when a note gets a place, its coordinates (no audio and no text) go to Apple's geocoder, which sends back the street name. Nothing else leaves your iPhone, except through iCloud if you chose it."),
        Section(title: "Location",
                body: "Only if you allow it, and only while you use Sona: one fix when a recording starts and one when it stops, kept in that note. You can turn it off in Settings > Apps > Sona > Location; notes then have no place."),
        Section(title: "Microphone",
                body: "Sona listens only while you're recording: from when you tap record (or start it from a widget, Siri or your Apple Watch) until you stop."),
        Section(title: "How long things are kept",
                body: "Audio as you set it in Sona's settings: for 30 days (unless you keep a note's audio), for good, or deleted once it's turned into text. Notes stay until you delete them."),
        Section(title: "Deleting",
                body: "Swipe a note to the left, or use Delete on the note. That deletes its text and audio from this iPhone and from iCloud. A note Sona for Mac already copied stays on the Mac until you delete it there. Deleting the app deletes everything Sona kept on this iPhone."),
        Section(title: "Recording other people",
                body: "Some places need everyone's consent before you record a conversation. Check the rules where you are."),
        Section(title: "Children",
                body: "Sona isn't aimed at children."),
        Section(title: "Changes",
                body: "If this policy changes, the new version comes with the app update, with its date at the top."),
    ]
}

/// The privacy policy, from Settings and the welcome screen.
struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Updated \(PrivacyPolicy.updated)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(PrivacyPolicy.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Text(section.body)
                            .font(.body)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

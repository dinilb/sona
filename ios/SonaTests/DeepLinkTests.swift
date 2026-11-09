import Foundation
import Testing
@testable import Sona

/// The widgets and the complication open links that start and stop a recording, so a link counts only with this
/// device's key. Any app or web page can open `sona://record`; none can read the App Group the key is kept in.
struct DeepLinkTests {
    /// A key store of the test's own, so these don't touch the App Group.
    func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "sona-tests-\(UUID().uuidString)")! }

    @Test func theKeyIsMadeOnceAndKept() {
        let store = freshDefaults()
        let key = LinkKey.current(in: store)
        #expect(!key.isEmpty)
        #expect(LinkKey.current(in: store) == key)
        #expect(store.string(forKey: LinkKey.defaultsKey) == key)
        // Another device has its own.
        #expect(LinkKey.current(in: freshDefaults()) != key)
    }

    @Test func aLostKeyIsMadeAgain() {
        let store = freshDefaults()
        store.set("", forKey: LinkKey.defaultsKey)
        let key = LinkKey.current(in: store)
        #expect(!key.isEmpty)
        #expect(LinkKey.current(in: store) == key)
    }

    @Test func aLinkWithTheKeyGoesRoundAndIsTrusted() {
        let key = LinkKey.current(in: freshDefaults())
        for link in [DeepLink.record, .stop] {
            let url = link.url(key: key)
            #expect(url.scheme == "sona")
            #expect(url.host() == link.rawValue)
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "k", value: key)])
            #expect(DeepLink.trusted(url: url, key: key) == link)
        }
        // Record stays record and stop stays stop.
        #expect(DeepLink.trusted(url: DeepLink.record.url(key: key), key: key) == .record)
        #expect(DeepLink.trusted(url: DeepLink.stop.url(key: key), key: key) == .stop)
    }

    @Test func aLinkWithoutTheRightKeyIsNotTrusted() {
        let key = LinkKey.current(in: freshDefaults())
        let otherDevicesKey = LinkKey.current(in: freshDefaults())
        for link in [DeepLink.record, .stop] {
            let name = link.rawValue
            let refused = [
                "sona://\(name)",  // what a page or another app would open
                "sona://\(name)?k=",
                "sona://\(name)?k=wrong",
                "sona://\(name)?key=\(key)",  // the right value under another name
                "sona://\(name)?x=1",
                "sona://\(name)?k=\(key)&k=\(key)",  // not a link of ours
                "https://\(name)?k=\(key)",  // another scheme
                "other://\(name)?k=\(key)",
            ]
            for text in refused {
                #expect(DeepLink.trusted(url: URL(string: text)!, key: key) == nil, "\(text)")
            }
            #expect(DeepLink.trusted(url: link.url(key: otherDevicesKey), key: key) == nil)
        }
        // Not a link of ours at all, key or not.
        #expect(DeepLink.trusted(url: URL(string: "sona://settings?k=\(key)")!, key: key) == nil)
        // With no key to compare against, nothing passes.
        #expect(DeepLink.trusted(url: DeepLink.record.url(key: ""), key: "") == nil)
    }

    @Test func theLinkAWidgetOpensCarriesThisDevicesKey() {
        // `url` is what the Lock Screen and Home Screen widgets (and the watch's complication) open.
        let key = LinkKey.current()
        for link in [DeepLink.record, .stop] {
            #expect(link.url == link.url(key: key))
            #expect(link.url.absoluteString.contains("k=\(key)"))
            #expect(DeepLink.trusted(url: link.url) == link)
        }
        // The old bare links no longer pass the check the app makes.
        #expect(DeepLink.trusted(url: URL(string: "sona://record")!) == nil)
        #expect(DeepLink.trusted(url: URL(string: "sona://stop")!) == nil)
    }
}

import Foundation
import Testing
@testable import SonaWatch

/// The complication's links start and stop a recording on the watch only with the watch's own key (the same code as
/// the iPhone's, compiled into this app too: see ios/SonaTests/DeepLinkTests.swift for the full list of what's refused).
struct DeepLinkTests {
    @Test func aLinkIsTrustedOnlyWithTheKey() {
        let store = UserDefaults(suiteName: "sona-tests-\(UUID().uuidString)")!
        let key = LinkKey.current(in: store)
        #expect(!key.isEmpty)
        #expect(LinkKey.current(in: store) == key)  // made once, kept
        for link in [DeepLink.record, .stop] {
            #expect(DeepLink.trusted(url: link.url(key: key), key: key) == link)
            #expect(DeepLink.trusted(url: URL(string: "sona://\(link.rawValue)")!, key: key) == nil)
            #expect(DeepLink.trusted(url: link.url(key: "wrong"), key: key) == nil)
            #expect(DeepLink.trusted(url: URL(string: "https://\(link.rawValue)?k=\(key)")!, key: key) == nil)
        }
    }

    @Test func theComplicationsLinkCarriesTheWatchsKey() {
        let key = LinkKey.current()
        for link in [DeepLink.record, .stop] {
            #expect(link.url.absoluteString.contains("k=\(key)"))
            #expect(DeepLink.trusted(url: link.url) == link)
        }
        #expect(DeepLink.trusted(url: URL(string: "sona://record")!) == nil)
    }
}

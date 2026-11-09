import Foundation
import Testing
@testable import Sona

struct NotesStatusTests {
    /// The widgets' status in a test's own UserDefaults suite, counting reloads.
    final class TestStore {
        let defaults = UserDefaults(suiteName: "sona-tests-\(UUID().uuidString)")!
        var reloads = 0

        var store: WidgetStatus.Store {
            WidgetStatus.Store(
                load: {
                    guard let data = self.defaults.data(forKey: SharedStatus.key) else { return SharedStatus() }
                    return (try? JSONDecoder().decode(SharedStatus.self, from: data)) ?? SharedStatus()
                },
                save: { self.defaults.set(try? JSONEncoder().encode($0), forKey: SharedStatus.key) },
                reload: { self.reloads += 1 })
        }
    }

    @Test func updatesNotesFieldsAndKeepsTheRecordersOwn() {
        let test = TestStore()
        let recording = Date(timeIntervalSince1970: 1_793_000_000)
        test.store.save(SharedStatus(recordingSince: recording, waiting: 0))

        let at = Date(timeIntervalSince1970: 1_793_000_500)
        #expect(WidgetStatus.publish(waiting: 2, latestTitle: "Budget for the launch", latestAt: at, store: test.store))
        let status = test.store.load()
        #expect(status.recordingSince == recording)
        #expect(status.waiting == 2)
        #expect(status.latestTitle == "Budget for the launch")
        #expect(status.latestAt == at)
        #expect(test.reloads == 1)

        // The same again: no save, no reload (reloads are budgeted).
        #expect(!WidgetStatus.publish(waiting: 2, latestTitle: "Budget for the launch", latestAt: at, store: test.store))
        #expect(test.reloads == 1)
    }
}

import Foundation

/// Now's two tracks as one transcript: the mic's lines and this Mac's (already on the mic's clock), ordered by when
/// each line began. A line is one speaker's stretch, so two talking over each other stay two whole lines, and a
/// word that came out late lands in its own line wherever that belongs. On a tie the mic's line comes first.
public enum LiveMerge {
    public static func lines(mic: [LiveLine], mac: [LiveLine]) -> [LiveLine] {
        guard !mac.isEmpty else { return mic }
        guard !mic.isEmpty else { return mac }
        var out: [LiveLine] = []
        out.reserveCapacity(mic.count + mac.count)
        var i = 0, j = 0
        while i < mic.count || j < mac.count {
            if j == mac.count || i < mic.count && mic[i].start <= mac[j].start {
                out.append(mic[i])
                i += 1
            } else {
                out.append(mac[j])
                j += 1
            }
        }
        return out
    }
}

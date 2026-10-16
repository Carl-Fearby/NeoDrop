import XCTest
@testable import NeoDropCore

/// The Activity window's judgement, without the window.
///
/// Everything here is what a person reading that list depends on: that the tabs mean what they say,
/// that a search narrows rather than lies, that a line about a file is titled with the file, and
/// that a warning is not drawn like a success.
final class ActivityFeedTests: XCTestCase {

    private func entry(
        _ message: String,
        level: LogLevel = .info,
        scope: LogScope = .local,
        minutesAgo: Double = 0
    ) -> NeoDropLog.LogEntry {
        NeoDropLog.LogEntry(
            date: Date().addingTimeInterval(-minutesAgo * 60), level: level, scope: scope, message: message
        )
    }

    /// The log as `AppModel.activity` hands it over — newest first, with the scope each line was
    /// written with, and worded the way the app words them.
    private func log() -> [NeoDropLog.LogEntry] {
        [
            entry("Documents/alpha.txt: copied to NAS1", level: .success),
            entry("Shared: 2 sent, 1 received", level: .success, scope: .shared),
            entry("NAS2: could not be reached (the volume is not mounted)", level: .warning),
            entry("Verifying 40 files in Photos", minutesAgo: 3),
            entry("Shared: 1 conflict kept as a copy", level: .warning, scope: .shared, minutesAgo: 6),
            entry("Syncing “Shared”", scope: .shared, minutesAgo: 30)
        ]
    }

    // MARK: - Tabs

    func testTheWholeLogIsTheYouTab() {
        let rows = ActivityFeed.rows(from: log(), scope: .you)
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows.first?.title, "Documents/alpha.txt", "newest first, as the window reads")
        XCTAssertEqual(rows.last?.title, "Syncing “Shared”")
    }

    /// "Shared" is the two-way folders, and it is what someone with a vault on a share came to look
    /// at. The line a two-way sync writes — "Shared: 2 sent, 1 received" — says neither "vault" nor
    /// "two-way", and it still belongs here: the tab reads the scope a line was written with, not
    /// words that happen to be in it.
    func testTheSharedTabKeepsTheWorkOnTwoWayFolders() {
        let entries = log()
        let shared = ActivityFeed.rows(from: entries, scope: .shared)
        XCTAssertEqual(shared.map(\.title),
                       ["Shared: 2 sent, 1 received", "Shared: 1 conflict kept as a copy", "Syncing “Shared”"])

        // Nothing is lost or duplicated by the cut: the two tabs are views of one log.
        let you = ActivityFeed.rows(from: entries, scope: .you)
        XCTAssertEqual(you.count, entries.count)
        XCTAssertEqual(Set(shared.map(\.id)).count, shared.count)
        XCTAssertTrue(Set(shared.map(\.id)).isSubset(of: Set(you.map(\.id))))
    }

    /// A word in a message never decides a tab. A replica whose folder is called "Vault-backup" is
    /// still a replica, and this is the bug that made the old text search useless: it both hid the
    /// two-way lines (no keyword) and admitted unrelated ones (keyword).
    func testAWordInAMessageDoesNotPutALineInTheSharedTab() {
        let aboutAFolderCalledVault = [entry("NAS1: copied 12 files into Vault-backup")]
        XCTAssertEqual(ActivityFeed.rows(from: aboutAFolderCalledVault, scope: .shared).count, 0)
        XCTAssertEqual(ActivityFeed.rows(from: aboutAFolderCalledVault, scope: .you).count, 1)

        let twoWay = [entry("Shared: 2 sent, 1 received", scope: .shared)]
        XCTAssertEqual(ActivityFeed.rows(from: twoWay, scope: .shared).count, 1)
        XCTAssertEqual(ActivityFeed.rows(from: twoWay, scope: .you).count, 1, "You is the whole log")
    }

    // MARK: - Search

    func testSearchIsCaseInsensitiveAndNarrowsWithinTheTab() {
        // "COPY" finds the line that says "copy"; "cop" finds that one and the file that was
        // "copied".
        XCTAssertEqual(ActivityFeed.rows(from: log(), scope: .you, query: "COPY").map(\.title),
                       ["Shared: 1 conflict kept as a copy"])
        XCTAssertEqual(ActivityFeed.rows(from: log(), scope: .you, query: "cop").map(\.title),
                       ["Documents/alpha.txt", "Shared: 1 conflict kept as a copy"])

        // A query that matches something the tab hides stays hidden: the two are combined, not
        // swapped for one another.
        XCTAssertEqual(ActivityFeed.rows(from: log(), scope: .shared, query: "NAS1").count, 0)
        XCTAssertEqual(ActivityFeed.rows(from: log(), scope: .you, query: "NAS1").count, 1)
    }

    func testAWhitespaceQueryIsNoQuery() {
        let all = ActivityFeed.rows(from: log(), scope: .you).count
        XCTAssertEqual(ActivityFeed.rows(from: log(), scope: .you, query: "   ").count, all)
        XCTAssertEqual(ActivityFeed.rows(from: log(), scope: .you, query: "").count, all)
    }

    func testAnEmptyLogAndAnUnmatchedQueryProduceNoRows() {
        XCTAssertEqual(ActivityFeed.rows(from: [], scope: .you).count, 0)
        XCTAssertEqual(ActivityFeed.rows(from: [], scope: .shared).count, 0)
        XCTAssertEqual(ActivityFeed.rows(from: log(), scope: .you, query: "nothing like this").count, 0)
    }

    func testOnlyTheNewestRowsAreDrawn() {
        let many = (0..<80).map { entry("file-\(String(format: "%03d", $0)).txt: copied", minutesAgo: Double($0)) }
        let rows = ActivityFeed.rows(from: many, scope: .you)
        XCTAssertEqual(rows.count, ActivityFeed.rowLimit)
        XCTAssertEqual(rows.first?.title, "file-000.txt")
        XCTAssertEqual(rows.last?.title, "file-039.txt", "the tail is dropped, not the head")
    }

    // MARK: - Titles and marks

    func testATitleNamesTheFileWhenTheLineHasOne() {
        XCTAssertEqual(ActivityFeed.fileTitle("Documents/2026/plans.txt: replaced on NAS1"), "Documents/2026/plans.txt")
        XCTAssertEqual(ActivityFeed.fileTitle("vacation.jpg: the copy on the share is not the version NeoDrop wrote"),
                       "vacation.jpg")
        // A line that names no file is its own title, whole: cutting the first two would invent a
        // file name ("Shared", "Could not write the journal"), and cutting the last two would throw
        // away the half that carries the meaning.
        XCTAssertEqual(ActivityFeed.fileTitle("Shared: 2 sent, 1 received"), "Shared: 2 sent, 1 received")
        XCTAssertEqual(ActivityFeed.fileTitle("Syncing “Shared”"), "Syncing “Shared”")
        XCTAssertEqual(ActivityFeed.fileTitle("Could not write the journal: the disk is full"),
                       "Could not write the journal: the disk is full")
        XCTAssertEqual(ActivityFeed.fileTitle("Verifying 40 files"), "Verifying 40 files")
    }

    func testWarningsAndErrorsAreMarkedAndSuccessIsComplete() {
        let rows = ActivityFeed.rows(from: log(), scope: .you)
        XCTAssertEqual(rows[0].mark, .document)
        XCTAssertTrue(rows[0].isComplete, "a copied file shows a finished bar")
        XCTAssertEqual(rows[2].mark, .problem)
        XCTAssertFalse(rows[2].isComplete)
        XCTAssertEqual(rows[3].mark, .document)
        XCTAssertFalse(rows[3].isComplete, "work in progress is not a finished transfer")

        let failure = ActivityFeed.rows(from: [entry("alpha.txt: permission denied", level: .error)], scope: .you)
        XCTAssertEqual(failure.first?.mark, .problem)
    }

    /// A row says the path once, then what happened — never the same line twice.
    func testARowShowsTheOutcomeTheTimeAndTheRestOfTheLine() {
        let rows = ActivityFeed.rows(from: log(), scope: .you)
        let file = rows[0]
        XCTAssertEqual(file.title, "Documents/alpha.txt")
        XCTAssertEqual(file.detail.components(separatedBy: " · ").count, 3, file.detail)
        XCTAssertTrue(file.detail.hasPrefix("Ok · "), file.detail)
        XCTAssertTrue(file.detail.hasSuffix("copied to NAS1"), file.detail)
        XCTAssertFalse(file.detail.contains("Documents/alpha.txt"), "the path is the title, not the detail")

        let shared = rows[1]
        XCTAssertEqual(shared.title, "Shared: 2 sent, 1 received")
        XCTAssertEqual(shared.detail.components(separatedBy: " · ").count, 2, shared.detail)
        XCTAssertTrue(shared.detail.hasPrefix("Ok · "), shared.detail)
    }

    // MARK: - The row for the pass running now

    func testTheRunningRowNamesTheFileAndFallsBackToTheDestination() {
        let moving = SyncProgress(phase: .syncing, replicaName: "Shared", currentFile: "big.iso",
                                  filesTotal: 12, filesDone: 3, bytesTotal: 4096, bytesDone: 1024)
        XCTAssertEqual(ActivityFeed.inFlight(isBusy: true, progress: moving)?.title, "big.iso")
        XCTAssertEqual(ActivityFeed.inFlight(isBusy: true, progress: moving)?.fraction, 0.25)

        let betweenFiles = SyncProgress(phase: .scanning, replicaName: "Shared")
        XCTAssertEqual(ActivityFeed.inFlight(isBusy: true, progress: betweenFiles)?.title, "Shared")

        let nothingYet = SyncProgress(phase: .scanning)
        XCTAssertEqual(ActivityFeed.inFlight(isBusy: true, progress: nothingYet)?.title, "Preparing files…")

        XCTAssertNil(ActivityFeed.inFlight(isBusy: false, progress: moving), "no row when nothing is running")
    }

    func testTheProgressLineReadsPhaseDestinationCountsAndFile() {
        let full = SyncProgress(phase: .syncing, replicaName: "Shared", currentFile: "Documents/a.txt",
                                filesTotal: 40, filesDone: 7)
        XCTAssertEqual(ActivityFeed.progressLine(full), "Mirroring · → Shared · 7/40 files · Documents/a.txt")

        // Nothing it does not know is mentioned, and the phase is always there.
        XCTAssertEqual(ActivityFeed.progressLine(SyncProgress(phase: .verifying)), "Verifying")
        XCTAssertEqual(ActivityFeed.progressLine(SyncProgress(phase: .scanning, replicaName: "NAS1")),
                       "Scanning source · → NAS1")
        XCTAssertEqual(ActivityFeed.progressLine(SyncProgress(phase: .failed("disk full"))), "Error: disk full")
    }

    // MARK: - The footer

    func testTheFooterCountsBytesWhileItIsMoving() {
        let moving = SyncProgress(phase: .syncing, filesTotal: 4, filesDone: 2,
                                  bytesTotal: 4096, bytesDone: 1536)
        XCTAssertEqual(ActivityFeed.footer(isBusy: true, progress: moving, fallback: "2 of 2 replicas online"),
                       "\(Int64(1536).byteDescription) of \(Int64(4096).byteDescription)")
        XCTAssertLessThan(Int64(5_000_000).byteDescription.count, 8, "sizes are shown in units a person reads")
    }

    func testTheFooterFallsBackToFileCountsThenTheStandingSummary() {
        let byFiles = SyncProgress(phase: .syncing, filesTotal: 4, filesDone: 2)
        XCTAssertEqual(ActivityFeed.footer(isBusy: true, progress: byFiles, fallback: "2 of 2 replicas online"),
                       "2 of 4 files")

        let idle = SyncProgress(phase: .idle)
        XCTAssertEqual(ActivityFeed.footer(isBusy: false, progress: idle, fallback: "2 of 2 replicas online"),
                       "2 of 2 replicas online")
        XCTAssertEqual(ActivityFeed.footer(isBusy: true, progress: idle, fallback: "1 of 1 two-way folders"),
                       "1 of 1 two-way folders",
                       "a pass that cannot count anything still says what the setup is")
    }

    // MARK: - Wording the view depends on

    func testTheSectionTitleFollowsWhetherWorkIsRunning() {
        XCTAssertEqual(ActivityFeed.sectionTitle(isBusy: true), "In progress")
        XCTAssertEqual(ActivityFeed.sectionTitle(isBusy: false), "Recent activity")
    }
}

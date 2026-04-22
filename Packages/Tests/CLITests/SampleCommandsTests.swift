@testable import CLI
import Testing

@Suite("Sample CLI Command Parsing")
struct SampleCommandsTests {
    @Test("list-samples accepts sample-db argument")
    func listSamplesParsesSampleDbArgument() throws {
        _ = try Cupertino.parseAsRoot([
            "list-samples",
            "--sample-db", "/tmp/samples.db",
            "--limit", "10",
            "--format", "json",
        ])
    }

    @Test("read-sample accepts sample-db argument")
    func readSampleParsesSampleDbArgument() throws {
        _ = try Cupertino.parseAsRoot([
            "read-sample",
            "tp-cli-sample",
            "--sample-db", "/tmp/samples.db",
            "--format", "json",
        ])
    }

    @Test("read-sample-file accepts sample-db argument")
    func readSampleFileParsesSampleDbArgument() throws {
        _ = try Cupertino.parseAsRoot([
            "read-sample-file",
            "tp-cli-sample",
            "Sources/Feature.swift",
            "--sample-db", "/tmp/samples.db",
            "--format", "json",
        ])
    }
}

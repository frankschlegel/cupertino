@testable import Diagnostics
import Foundation
import Testing

// MARK: - SchemaVersion formatting (#234, lifted to Diagnostics in #245)

@Suite("Diagnostics.SchemaVersion.format")
struct SchemaVersionFormatTests {
    @Test("Zero or negative renders as (unset)")
    func zeroIsUnset() {
        #expect(Diagnostics.SchemaVersion.format(0) == "(unset)")
        #expect(Diagnostics.SchemaVersion.format(-1) == "(unset)")
    }

    @Test("Sane YYYYMMDD value renders as date-style")
    func dateStyle() {
        let formatted = Diagnostics.SchemaVersion.format(20260504)
        #expect(formatted.contains("20260504"))
        #expect(formatted.contains("2026-05-04"))
        #expect(formatted.contains("date-style"))
    }

    @Test("Boundary year 1970 still renders as date-style")
    func boundaryYear() {
        let formatted = Diagnostics.SchemaVersion.format(19700101)
        #expect(formatted.contains("1970-01-01"))
        #expect(formatted.contains("date-style"))
    }

    @Test("Sequential int (legacy) renders without date suffix")
    func sequentialInt() {
        let formatted = Diagnostics.SchemaVersion.format(5)
        #expect(formatted == "5 (sequential)")
    }

    @Test("Implausible date components fall back to sequential")
    func implausibleDate() {
        // Month 13 → not date-style.
        let formatted = Diagnostics.SchemaVersion.format(20261301)
        #expect(formatted.contains("sequential"))
        #expect(!formatted.contains("date-style"))
    }
}

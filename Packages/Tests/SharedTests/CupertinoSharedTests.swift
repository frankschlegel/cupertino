@testable import Shared
import Testing
import TestSupport

@Test func configuration() throws {
    let config = Shared.CrawlerConfiguration()
    #expect(config.maxPages > 0)
}

@Test func searchToolDescriptionsUseUnifiedNaming() {
    let readDocumentDescription = Shared.Constants.Search.toolReadDocumentDescription
    let readSampleDescription = Shared.Constants.Search.toolReadSampleDescription

    #expect(!readDocumentDescription.contains("search_docs"))
    #expect(!readSampleDescription.contains("search_samples"))
}

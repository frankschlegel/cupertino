import Foundation
@testable import Core
import Testing

@Test("AppleJSONToMarkdown renders internal doc references as markdown links")
func appleJSONToMarkdownRendersDocumentationReferenceLinks() throws {
    let jsonObject: [String: Any] = [
        "metadata": [
            "title": "Reducer",
            "role": "symbol",
            "roleHeading": "Protocol",
            "modules": [["name": "ComposableArchitecture"]],
        ],
        "abstract": [
            ["type": "text", "text": "Use "],
            ["type": "reference", "identifier": "doc://ComposableArchitecture/documentation/ComposableArchitecture/Store"],
            ["type": "text", "text": " to power your feature."],
        ],
        "topicSections": [
            [
                "title": "Related Types",
                "identifiers": ["doc://ComposableArchitecture/documentation/ComposableArchitecture/Store"],
            ]
        ],
        "references": [
            "doc://ComposableArchitecture/documentation/ComposableArchitecture/Store": [
                "title": "Store",
                "url": "/documentation/composablearchitecture/store",
            ]
        ],
    ]

    let data = try JSONSerialization.data(withJSONObject: jsonObject)
    let markdown = AppleJSONToMarkdown.convert(data, url: URL(string: "file:///tmp/reducer.json")!)

    #expect(markdown != nil)
    #expect(markdown?.contains("[Store](https://developer.apple.com/documentation/composablearchitecture/store)") == true)
    #expect(markdown?.contains("## Related Types") == true)
}

@Test("AppleJSONToMarkdown resolves tutorial doc identifiers into tutorial links")
func appleJSONToMarkdownRendersTutorialReferenceLinks() throws {
    let jsonObject: [String: Any] = [
        "metadata": [
            "title": "Tutorial Overview",
            "role": "article",
            "roleHeading": "Article",
        ],
        "abstract": [
            ["type": "text", "text": "Continue with "],
            ["type": "reference", "identifier": "doc://ComposableArchitecture/tutorials/composablearchitecture/listsofsyncups"],
            ["type": "text", "text": "."],
        ],
        "references": [
            "doc://ComposableArchitecture/tutorials/composablearchitecture/listsofsyncups": [
                "title": "Lists of sync-ups",
            ]
        ],
    ]

    let data = try JSONSerialization.data(withJSONObject: jsonObject)
    let markdown = AppleJSONToMarkdown.convert(data, url: URL(string: "file:///tmp/tutorial-overview.json")!)

    #expect(markdown != nil)
    #expect(markdown?.contains("[Lists of sync-ups](https://developer.apple.com/tutorials/composablearchitecture/listsofsyncups)") == true)
}

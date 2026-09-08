// SPDX-License-Identifier: AGPL-3.0-only
// The Save to Library sheet's headless parts: the folder name a node's name becomes, and the words
// the sheet shows for a first save versus an update.
import Testing
import SZCore
@testable import SZUI

struct SZSaveToLibraryModelTests {
    @Test func aNameBecomesOneFolderName() {
        #expect(SZLibrarySlug.make("Gaussian Blur") == "gaussian-blur")
        #expect(SZLibrarySlug.make("  My  Node!! ") == "my-node")
        #expect(SZLibrarySlug.make("Blur (v2)") == "blur-v2")
        #expect(SZLibrarySlug.make("Café") == "caf")
        #expect(SZLibrarySlug.make("--") == "node")
        #expect(SZLibrarySlug.make("") == "node")
        #expect(SZLibrarySlug.make("../etc") == "etc")
    }

    @Test func theSheetSaysSaveOrUpdate() {
        #expect(SZSaveToLibraryWording.title(updates: false) == "Save to Library")
        #expect(SZSaveToLibraryWording.button(updates: false) == "Save")
        #expect(SZSaveToLibraryWording.note(updates: false, changes: []) == "The node in this project stays as it is.")
        #expect(SZSaveToLibraryWording.title(updates: true) == "Update Library Entry")
        #expect(SZSaveToLibraryWording.button(updates: true) == "Update Entry")
        #expect(SZSaveToLibraryWording.note(updates: true, changes: ["source changed", "ports changed"])
                == "Replaces the saved copy: source changed, ports changed.")
        #expect(SZSaveToLibraryWording.note(updates: true, changes: []).hasPrefix("The saved copy already matches"))
    }
}

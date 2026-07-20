import Foundation
import Testing

/// Structural integrity checks for the versioned quality corpus under
/// `Tests/QualityCorpus/` (backlog BL-010, acceptance plan section 2).
///
/// These tests deliberately assert *structure and declared invariants only* —
/// they never call a provider and never assert on natural-language content,
/// because quality acceptance is invariant-based rather than byte-for-byte.
/// The corpus is loaded from disk via a `#filePath`-relative path so no
/// SwiftPM resource bundling is required.
private struct CorpusInvariants: Decodable {
    let resultOnly: Bool
    let meaningPreserved: Bool
    let returnedUnchanged: Bool
    let preserveLanguage: Bool?
    let targetLanguage: String?
    let structural: [String]?
    let expectedChanges: [String]?
}

private struct CorpusFixture: Decodable {
    let id: String
    let corpusVersion: Int
    let action: String
    let contentType: String
    let language: String
    let input: String
    let invariants: CorpusInvariants
    let protectedTokens: [String]?
    let notes: String
}

private struct LoadedFixture {
    let fixture: CorpusFixture
    let fileName: String
    let directoryName: String
}

private func corpusDirectory(file: StaticString = #filePath) -> URL {
    // .../Tests/EnLLMCoreTests/QualityCorpusIntegrityTests.swift
    //  -> .../Tests/EnLLMCoreTests -> .../Tests -> .../Tests/QualityCorpus
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("QualityCorpus", isDirectory: true)
}

private func loadCorpus() throws -> [LoadedFixture] {
    let root = corpusDirectory()
    let decoder = JSONDecoder()
    var loaded: [LoadedFixture] = []
    for directory in ["correction", "translation"] {
        let dirURL = root.appendingPathComponent(directory, isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: nil
        )
        for url in entries where url.pathExtension == "json" {
            let data = try Data(contentsOf: url)
            let fixture = try decoder.decode(CorpusFixture.self, from: data)
            loaded.append(
                LoadedFixture(
                    fixture: fixture,
                    fileName: url.deletingPathExtension().lastPathComponent,
                    directoryName: directory
                )
            )
        }
    }
    return loaded
}

private func loadCorpusByID() throws -> [String: CorpusFixture] {
    Dictionary(uniqueKeysWithValues: try loadCorpus().map { ($0.fixture.id, $0.fixture) })
}

@Test func corpusContainsExactlyTheDeclaredTenFixturesWithUniqueIDs() throws {
    let loaded = try loadCorpus()
    let ids = loaded.map { $0.fixture.id }
    let expected: Set<String> = [
        "C-01", "C-02", "C-03", "C-04", "C-05",
        "T-01", "T-02", "T-03", "T-04", "T-05"
    ]
    #expect(Set(ids) == expected)
    #expect(ids.count == expected.count)  // no duplicate IDs
}

@Test func eachFixtureIsWellFormedAndPlacedInTheMatchingActionDirectory() throws {
    for loaded in try loadCorpus() {
        let f = loaded.fixture
        // The file name matches the declared ID.
        #expect(f.id == loaded.fileName)
        // The directory matches the declared action.
        let expectedAction = loaded.directoryName == "correction" ? "correction" : "translation"
        #expect(f.action == expectedAction)
        // A C-* ID lives under correction; a T-* ID lives under translation.
        let expectedPrefix = loaded.directoryName == "correction" ? "C-" : "T-"
        #expect(f.id.hasPrefix(expectedPrefix))
        // Versioned and non-empty.
        #expect(f.corpusVersion >= 1)
        #expect(!f.input.isEmpty)
        #expect(!f.contentType.isEmpty)
        #expect(!f.language.isEmpty)
    }
}

@Test func everyFixtureRequiresResultOnlyOutput() throws {
    // The product contract forbids model commentary in either action, so every
    // fixture must declare result-only output.
    for loaded in try loadCorpus() {
        #expect(loaded.fixture.invariants.resultOnly == true, "\(loaded.fixture.id) must declare resultOnly")
    }
}

@Test func corpusVersionIsConsistentAcrossFixtures() throws {
    let versions = Set(try loadCorpus().map { $0.fixture.corpusVersion })
    #expect(versions.count == 1, "All fixtures must share one corpus version; found \(versions)")
}

@Test func declaredProtectedTokensLiterallyAppearInTheirInput() throws {
    // A protected-token declaration is only meaningful if the token is actually
    // present in the source text the action receives.
    for loaded in try loadCorpus() {
        let f = loaded.fixture
        for token in f.protectedTokens ?? [] {
            #expect(
                f.input.contains(token),
                "\(f.id): declared protected token is absent from input: \(token)"
            )
        }
    }
}

@Test func technicalAndStructuralFixturesDeclareTheExpectedInvariants() throws {
    let byID = try loadCorpusByID()

    // Fixtures with protected tokens: technical / structural content.
    for id in ["C-05", "T-03"] {
        let f = try #require(byID[id])
        #expect(!(f.protectedTokens ?? []).isEmpty, "\(id) must declare protected tokens")
    }

    // Structural fixtures must declare structural invariants.
    for id in ["C-04", "C-05", "T-02", "T-03", "T-04"] {
        let f = try #require(byID[id])
        #expect(!(f.invariants.structural ?? []).isEmpty, "\(id) must declare structural invariants")
    }

    // Correction fixtures must preserve their source language.
    for (id, f) in byID where f.action == "correction" {
        #expect(f.invariants.preserveLanguage == true, "\(id) correction must declare preserveLanguage")
    }

    // Translation fixtures must target Ukrainian.
    for (id, f) in byID where f.action == "translation" {
        #expect(f.invariants.targetLanguage == "uk", "\(id) translation must target uk")
    }
}

@Test func alreadyCorrectAndAlreadyUkrainianFixturesAreReturnedUnchanged() throws {
    let byID = try loadCorpusByID()
    for id in ["C-03", "T-05"] {
        let f = try #require(byID[id])
        #expect(f.invariants.returnedUnchanged == true, "\(id) must declare returnedUnchanged")
    }
    // The error-bearing / translatable fixtures must NOT claim unchanged output.
    for id in ["C-01", "C-02", "C-04", "C-05", "T-01", "T-02", "T-03", "T-04"] {
        let f = try #require(byID[id])
        #expect(f.invariants.returnedUnchanged == false, "\(id) must not declare returnedUnchanged")
    }
}

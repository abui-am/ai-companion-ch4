import XCTest
@testable import Misaki

final class MisakiTests: XCTestCase {
    func testNumberToWords() {
        XCTAssertEqual(NumberToWords.cardinal(42), "forty-two")
        XCTAssertEqual(NumberToWords.cardinal(1_234), "one thousand two hundred thirty-four")
        XCTAssertEqual(NumberToWords.ordinal(42), "forty-second")
        XCTAssertEqual(NumberToWords.ordinal(101), "one hundred first")
        XCTAssertEqual(NumberToWords.year(1984), "nineteen eighty-four")
        XCTAssertEqual(NumberToWords.year(1905), "nineteen oh-five")
        XCTAssertEqual(NumberToWords.year(2001), "two thousand one")
    }

    func testExampleFromPythonUsage() throws {
        let g2p = try G2P()
        let result = g2p("[Misaki](/misˈɑki/) is a G2P engine designed for [Kokoro](/kˈOkəɹO/) models.")
        XCTAssertEqual(result.phonemes, "misˈɑki ɪz ɐ ʤˈitəpˈi ˈɛnʤən dəzˈInd fɔɹ kˈOkəɹO mˈɑdᵊlz.")
    }

    func testDefiniteArticleContext() throws {
        let g2p = try G2P()
        XCTAssertEqual(g2p("the apple").phonemes, "ði ˈæpᵊl")
        XCTAssertEqual(g2p("the banana").phonemes, "ðə bənˈænə")
    }

    func testToContextReduction() throws {
        let g2p = try G2P()
        XCTAssertEqual(g2p("to apple").phonemes, "tʊ ˈæpᵊl")
        XCTAssertEqual(g2p("to banana").phonemes, "tə bənˈænə")
    }

    func testAcronymDigitCompound() throws {
        let g2p = try G2P()
        let result = g2p("G2P")
        XCTAssertEqual(result.phonemes, "ʤˈitəpˈi")
    }

    func testCurrencySmokeTest() throws {
        let g2p = try G2P()
        let result = g2p("$12.50")
        XCTAssertFalse(result.phonemes.contains("❓"))
        XCTAssertTrue(result.phonemes.contains("dˈɑləɹ"))
        XCTAssertTrue(result.phonemes.contains("sˈɛnt"))
    }

    func testUppercaseNumericSuffixesStayNumeric() throws {
        let lexicon = try Lexicon()

        let ordinalToken = MToken(
            text: "42ND",
            tag: "CD",
            whitespace: "",
            underscore: MToken.Underscore(isHead: true, numFlags: "", prespace: false)
        )
        let pluralYearToken = MToken(
            text: "1990S",
            tag: "CD",
            whitespace: "",
            underscore: MToken.Underscore(isHead: true, numFlags: "", prespace: false)
        )

        XCTAssertNotNil(lexicon(ordinalToken, ctx: TokenContext()).0)
        XCTAssertNotNil(lexicon(pluralYearToken, ctx: TokenContext()).0)
    }

    func testDecimalStressFeatureParsing() throws {
        let processed = G2P.preprocess("[hello](1.0)")
        let g2p = try G2P()
        let tokens = g2p.tokenize(processed.text, featureSpans: processed.featureSpans)
        XCTAssertEqual(tokens.first?.underscore?.stress, 1.0)
    }
}

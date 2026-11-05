import XCTest
@testable import LifeRecorderMac

/// Fixing a name from a day's page writes into the same Markdown tables the glossary editor shows.
final class GlossaryTests: XCTestCase {
    private let file = """
    # Glossary

    ## 提示詞用

    Robert, Alice

    ## 人名

    | 正確 | 角色 | 常見誤轉 |
    |---|---|---|
    | Robert | PM | Rob, Bop |
    | Alice | | |

    ## 職稱與縮寫

    | 正確 | 常見誤轉 |
    |---|---|
    | RD | Artie |

    ## 待確認

    - 還不確定的名字
    """

    func testAMishearingIsAddedToTheNamesEntry() throws {
        var glossary = Glossary(file)
        XCTAssertTrue(glossary.learn(heard: "Bobby", means: "robert", in: "人名"))
        XCTAssertTrue(glossary.text.contains("| Robert | PM | Rob, Bop, Bobby |"))
        XCTAssertTrue(glossary.learn(heard: "Alis", means: "Alice", in: "人名"))
        XCTAssertTrue(glossary.text.contains("| Alice |  | Alis |"))
        XCTAssertEqual(glossary.entry(matching: "alis")?.name, "Alice")
    }

    func testANewNameStartsAnEntryInTheChosenTable() throws {
        var glossary = Glossary(file)
        XCTAssertTrue(glossary.learn(heard: "陳偉", means: "陳瑋", note: "訪客", in: "人名"))
        let people = try XCTUnwrap(glossary.sections.first { $0.title == "人名" })
        XCTAssertEqual(people.rows.last?.cells, ["陳瑋", "訪客", "陳偉"])
        // Nothing outside that table moves.
        XCTAssertTrue(glossary.text.hasSuffix("## 待確認\n\n- 還不確定的名字"))
        XCTAssertEqual(glossary.sections.first { $0.title == "職稱與縮寫" }?.rows.count, 1)
    }

    func testWhatIsAlreadyKnownChangesNothing() {
        var glossary = Glossary(file)
        XCTAssertFalse(glossary.learn(heard: "Bop", means: "Robert", in: "人名"))
        XCTAssertFalse(glossary.learn(heard: "Alice", means: "Alice", in: "人名"))
        XCTAssertFalse(glossary.learn(heard: "", means: "RD", in: "人名"))
        XCTAssertEqual(glossary.text, file)
    }

    func testAConfirmedNewNameHasNoMishearing() throws {
        var glossary = Glossary(file)
        XCTAssertTrue(glossary.learn(heard: "Model7", means: "Model7", in: "職稱與縮寫"))
        let titles = try XCTUnwrap(glossary.sections.first { $0.title == "職稱與縮寫" })
        XCTAssertEqual(titles.rows.last?.cells, ["Model7", ""])
    }

    func testAHighlightLosesTheQuestionMarkAndPunctuationAroundIt() {
        XCTAssertEqual(NameFix.clean(" 陳偉（?）"), "陳偉")
        XCTAssertEqual(NameFix.clean("A40 (?)，"), "A40")
        XCTAssertEqual(NameFix.clean("Node.js"), "Node.js")
    }
}

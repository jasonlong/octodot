import Testing
@testable import Octodot

struct SemanticVersionTests {
    @Test func parsesVersionWithVPrefix() {
        let v = SemanticVersion("v1.2.3")
        #expect(v != nil)
        #expect(v?.major == 1)
        #expect(v?.minor == 2)
        #expect(v?.patch == 3)
    }

    @Test func parsesVersionWithoutPrefix() {
        let v = SemanticVersion("0.3.2")
        #expect(v != nil)
        #expect(v?.major == 0)
        #expect(v?.minor == 3)
        #expect(v?.patch == 2)
    }

    @Test func rejectsInvalidStrings() {
        #expect(SemanticVersion("abc") == nil)
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("v1") == nil)
        #expect(SemanticVersion("1.2") == nil)
        #expect(SemanticVersion("1.2.3.4") == nil)
    }

    @Test func rejectsNegativeComponents() {
        #expect(SemanticVersion("-1.0.0") == nil)
    }

    @Test func comparison() {
        let v030 = SemanticVersion("0.3.0")!
        let v031 = SemanticVersion("0.3.1")!
        let v040 = SemanticVersion("0.4.0")!
        let v100 = SemanticVersion("1.0.0")!

        #expect(v030 < v031)
        #expect(v031 < v040)
        #expect(v040 < v100)
        #expect(v030 == SemanticVersion("v0.3.0")!)
    }

    @Test func description() {
        let v = SemanticVersion("v1.2.3")!
        #expect(v.description == "1.2.3")
    }
}

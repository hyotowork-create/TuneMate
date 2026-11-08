import Testing
@testable import TuneMateCore

@Test func versionIsSet() {
    #expect(!TuneMateInfo.version.isEmpty)
}

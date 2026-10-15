import Testing
@testable import WifiDoctorCore

@Test func coreSchemaVersionIsOne() {
    #expect(CoreInfo.schemaVersion == 1)
}

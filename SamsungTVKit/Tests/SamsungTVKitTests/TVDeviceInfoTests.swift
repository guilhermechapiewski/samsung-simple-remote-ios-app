import Foundation
import Testing
@testable import SamsungTVKit

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test func decodesOnTV() throws {
    let info = try TVDeviceInfo.decode(fixture("info-on"), host: "10.0.0.5")
    #expect(info.id == TVID(rawValue: "uuid:00000000-0000-4000-8000-000000000001"))
    #expect(info.host == "10.0.0.5")
    #expect(info.name == "65\" Test TV")
    #expect(info.modelName == "QN00XX00XAFXZA")
    #expect(info.modelCode == "24_TEST_QTV")
    #expect(info.networkType == "wireless")
    #expect(info.powerState == .on)
    #expect(info.wifiMAC?.description == "02:00:00:00:00:01")
    #expect(info.tokenAuthSupported)
}

@Test func emptyPowerStateIsStandby() throws {
    #expect(try TVDeviceInfo.decode(fixture("info-asleep"), host: "10.0.0.5").powerState == .standby)
}

@Test func absentPowerStateIsOn() throws {
    // Older TVs omit PowerState entirely, and only answer while on.
    var json = try #require(String(data: fixture("info-on"), encoding: .utf8))
    json = json.replacingOccurrences(of: "\"PowerState\":\"on\",", with: "")
    #expect(!json.contains("PowerState"))
    #expect(try TVDeviceInfo.decode(Data(json.utf8), host: "10.0.0.5").powerState == .on)
}

@Test func explicitStandbyAndOtherPowerStates() throws {
    let json = try #require(String(data: fixture("info-on"), encoding: .utf8))
    func decode(_ value: String) throws -> TVPowerState {
        let edited = json.replacingOccurrences(of: "\"PowerState\":\"on\"", with: "\"PowerState\":\"\(value)\"")
        return try TVDeviceInfo.decode(Data(edited.utf8), host: "10.0.0.5").powerState
    }
    #expect(try decode("") == .standby)
    #expect(try decode("standby") == .standby)
    #expect(try decode("dimmed") == .unknown("dimmed"))
}

@Test func rejectsNonTizen() {
    #expect(throws: TVInfoError.notSamsungTizen) { try TVDeviceInfo.decode(fixture("info-non-tizen"), host: "10.0.0.5") }
}

@Test func rejectsGarbage() {
    #expect(throws: TVInfoError.malformed) { try TVDeviceInfo.decode(Data("<html>".utf8), host: "10.0.0.5") }
}

@Test func decodesDetails() throws {
    let details = try TVDeviceInfo.decode(fixture("info-on"), host: "10.0.0.5").details
    #expect(details.resolution == "3840x2160")
    #expect(details.language == "en_US")
    #expect(details.countryCode == "US")
    #expect(details.accessPoint?.description == "02:00:00:00:00:99")
    #expect(details.frameTV == false)
    #expect(details.voice == true)
    #expect(details.gamePad == true)
    #expect(details.keyboardSync == true)
    #expect(details.developerMode == false)
    #expect(details.firmwareVersion == nil) // the TV says "Unknown"
    #expect(details.apiVersion == "2.0.25")
    #expect(details.modelYear == 2024)
}

@Test func detailsAreOptional() throws {
    let json = #"{"device":{"id":"uuid:x","type":"Samsung SmartTV","OS":"Tizen"}}"#
    let details = try TVDeviceInfo.decode(Data(json.utf8), host: "10.0.0.5").details
    #expect(details == TVDeviceDetails())
}

@Test func detailsTrimAndRejectOddValues() throws {
    let json = try #require(String(data: fixture("info-on"), encoding: .utf8))
        .replacingOccurrences(of: #""firmwareVersion":"Unknown""#, with: #""firmwareVersion":" T-KSU2EAUC-1234.5 ""#)
        .replacingOccurrences(of: #""developerMode":"0""#, with: #""developerMode":"1""#)
        .replacingOccurrences(of: #""ssid":"02:00:00:00:00:99""#, with: #""ssid":"Home Wi-Fi""#)
        .replacingOccurrences(of: #""FrameTVSupport":"false""#, with: #""FrameTVSupport":"maybe""#)
    let details = try TVDeviceInfo.decode(Data(json.utf8), host: "10.0.0.5").details
    #expect(details.firmwareVersion == "T-KSU2EAUC-1234.5")
    #expect(details.developerMode == true)
    #expect(details.accessPoint == nil) // only a MAC (BSSID) is shown
    #expect(details.frameTV == nil)
}

@Test func modelYearFromModelCode() {
    #expect(TVDeviceDetails.modelYear(fromModelCode: "22_PONTUSM_FTV") == 2022)
    #expect(TVDeviceDetails.modelYear(fromModelCode: "16_JAZZM_UHD") == 2016)
    #expect(TVDeviceDetails.modelYear(fromModelCode: "26_RSM_MTV") == 2026)
    #expect(TVDeviceDetails.modelYear(fromModelCode: "") == nil)
    #expect(TVDeviceDetails.modelYear(fromModelCode: "QN90B") == nil)
    #expect(TVDeviceDetails.modelYear(fromModelCode: "99_X") == nil) // out of range
    #expect(TVDeviceDetails.modelYear(fromModelCode: "1_X") == nil)
}

@Test func textFromTheTVIsCleanedAndCapped() throws {
    let long = String(repeating: "A", count: 500)
    let json = try #require(String(data: fixture("info-on"), encoding: .utf8))
        .replacingOccurrences(of: #""modelName":"QN00XX00XAFXZA""#, with: "\"modelName\":\"\(long)\"")
        .replacingOccurrences(of: #""networkType":"wireless""#, with: #""networkType":"  wire\u0000less\n ""#)
        .replacingOccurrences(of: #""name":"65&quot; Test TV","networkType""#,
                              with: #""name":"Den‮vt.exe","networkType""#)
    let info = try TVDeviceInfo.decode(Data(json.utf8), host: "10.0.0.5")
    #expect(info.modelName.count == TVDeviceInfo.maxTextLength)
    #expect(info.networkType == "wireless")
    #expect(info.name == "Denvt.exe") // the right-to-left override is dropped
    #expect(TVDeviceInfo.text("  \t ") == nil)
    #expect(TVDeviceInfo.text("Café ✓") == "Café ✓")
}

@Test func olderTVsNamePrefixIsDropped() throws {
    // 2019 models report e.g. "[TV] Samsung Q50 Series (32)"; newer ones have no prefix.
    func name(_ reported: String) throws -> String {
        let json = try #require(String(data: fixture("info-on"), encoding: .utf8))
            .replacingOccurrences(of: #""name":"65&quot; Test TV","networkType""#,
                                  with: "\"name\":\"\(reported)\",\"networkType\"")
        return try TVDeviceInfo.decode(Data(json.utf8), host: "10.0.0.5").name
    }
    #expect(try name("[TV] Samsung Q50 Series (32)") == "Samsung Q50 Series (32)")
    #expect(try name("[TV]Den") == "Den")
    #expect(try name("Den [TV]") == "Den [TV]") // only a leading prefix
    #expect(try name("[TV]") == "[TV]") // nothing would be left
}

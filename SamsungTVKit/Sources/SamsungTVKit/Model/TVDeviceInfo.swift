import Foundation

public enum TVPowerState: Equatable, Sendable {
    case on
    case standby
    case unknown(String)
}

public enum TVInfoError: Error, Equatable {
    case malformed
    case notSamsungTizen
    case tooLarge
    case unreachable
    case notLocalAddress
}

/// Extra, informational facts a TV reports about itself. Every field is optional: models differ in
/// what they report, and nothing here is needed to control the TV.
public struct TVDeviceDetails: Equatable, Sendable {
    /// Model year, from the model code's two-digit prefix ("22_…" is 2022).
    public var modelYear: Int?
    /// Panel resolution, such as "3840x2160".
    public var resolution: String?
    /// Menu language as a locale identifier, such as "en_US".
    public var language: String?
    /// Country the TV is set to, such as "US".
    public var countryCode: String?
    /// The Wi-Fi access point (BSSID) the TV is connected to, when the TV reports one.
    public var accessPoint: MACAddress?
    public var frameTV: Bool?
    public var voice: Bool?
    public var gamePad: Bool?
    /// The TV can sync its on-screen keyboard with a phone.
    public var keyboardSync: Bool?
    public var developerMode: Bool?
    /// Omitted when the TV says "Unknown" (most do).
    public var firmwareVersion: String?
    /// Version of the TV's remote-control API, such as "2.0.25".
    public var apiVersion: String?

    public init(
        modelYear: Int? = nil, resolution: String? = nil, language: String? = nil, countryCode: String? = nil,
        accessPoint: MACAddress? = nil, frameTV: Bool? = nil, voice: Bool? = nil, gamePad: Bool? = nil,
        keyboardSync: Bool? = nil, developerMode: Bool? = nil, firmwareVersion: String? = nil,
        apiVersion: String? = nil
    ) {
        self.modelYear = modelYear
        self.resolution = resolution
        self.language = language
        self.countryCode = countryCode
        self.accessPoint = accessPoint
        self.frameTV = frameTV
        self.voice = voice
        self.gamePad = gamePad
        self.keyboardSync = keyboardSync
        self.developerMode = developerMode
        self.firmwareVersion = firmwareVersion
        self.apiVersion = apiVersion
    }

    /// The model year from a model code like "22_PONTUSM_FTV"; nil unless the code starts with two
    /// digits and an underscore, for a year from 2015 to 2040.
    public static func modelYear(fromModelCode code: String) -> Int? {
        let parts = code.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[0].allSatisfy(\.isASCII),
              let short = Int(parts[0]), (15...40).contains(short) else { return nil }
        return 2000 + short
    }
}

/// Facts about a TV from `GET http://<host>:8001/api/v2/`.
public struct TVDeviceInfo: Equatable, Sendable {
    public var id: TVID
    public var host: String
    public var name: String
    public var modelName: String
    public var modelCode: String
    public var wifiMAC: MACAddress?
    public var networkType: String
    public var powerState: TVPowerState
    public var tokenAuthSupported: Bool
    public var details: TVDeviceDetails

    public init(
        id: TVID, host: String, name: String, modelName: String, modelCode: String,
        wifiMAC: MACAddress?, networkType: String, powerState: TVPowerState, tokenAuthSupported: Bool,
        details: TVDeviceDetails = TVDeviceDetails()
    ) {
        self.details = details
        self.id = id
        self.host = host
        self.name = name
        self.modelName = modelName
        self.modelCode = modelCode
        self.wifiMAC = wifiMAC
        self.networkType = networkType
        self.powerState = powerState
        self.tokenAuthSupported = tokenAuthSupported
    }

    public static func decode(_ data: Data, host: String) throws(TVInfoError) -> TVDeviceInfo {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw .malformed
        }
        let device = response.device
        guard device.type == "Samsung SmartTV", device.OS == "Tizen" else { throw .notSamsungTizen }

        // Absent: older TVs omit the field and only answer while on.
        let power: TVPowerState
        switch device.PowerState {
        case "on", nil: power = .on
        case "", "standby": power = .standby
        case let other?: power = .unknown(other)
        }

        return TVDeviceInfo(
            id: TVID(rawValue: device.id),
            host: host,
            name: displayName(text(HTMLEntities.decode(device.name ?? response.name ?? "")) ?? ""),
            modelName: text(device.modelName) ?? "",
            modelCode: text(device.model) ?? "",
            wifiMAC: device.wifiMac.flatMap(MACAddress.init),
            networkType: text(device.networkType) ?? "",
            powerState: power,
            tokenAuthSupported: device.TokenAuthSupport == "true",
            details: TVDeviceDetails(
                modelYear: device.model.flatMap(TVDeviceDetails.modelYear(fromModelCode:)),
                resolution: text(device.resolution),
                language: text(device.Language),
                countryCode: text(device.countryCode),
                accessPoint: device.ssid.flatMap(MACAddress.init),
                frameTV: flag(device.FrameTVSupport),
                voice: flag(device.VoiceSupport),
                gamePad: flag(device.GamePadSupport),
                keyboardSync: flag(device.ImeSyncedSupport),
                developerMode: device.developerMode.flatMap { ["1": true, "0": false][$0] },
                firmwareVersion: text(device.firmwareVersion).flatMap { $0.lowercased() == "unknown" ? nil : $0 },
                apiVersion: text(response.version)
            )
        )
    }

    /// Longest text kept from the TV for any one field.
    static let maxTextLength = 100

    /// A display-safe value: control and formatting characters (such as bidi overrides, which could
    /// make a name read misleadingly) removed, trimmed, capped at `maxTextLength`; nil when empty.
    /// The TV is not trusted to be brief or well-formed.
    static func text(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = String(String.UnicodeScalarView(value.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: false
            default: true
            }
        }))
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxTextLength))
    }

    /// Older TVs (2019 models in testing) start their name with "[TV] "; it is dropped unless nothing would be
    /// left.
    static func displayName(_ name: String) -> String {
        guard name.hasPrefix("[TV]") else { return name }
        let rest = name.dropFirst(4).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }

    private static func flag(_ value: String?) -> Bool? {
        switch value {
        case "true": true
        case "false": false
        default: nil
        }
    }

    private struct Response: Decodable {
        let name: String?
        let version: String?
        let device: Device
    }

    // Property names mirror the TV's JSON keys.
    private struct Device: Decodable {
        let id: String
        let name: String?
        let type: String?
        let OS: String?
        let model: String?
        let modelName: String?
        let wifiMac: String?
        let networkType: String?
        let PowerState: String?
        let TokenAuthSupport: String?
        let resolution: String?
        let Language: String?
        let countryCode: String?
        let ssid: String?
        let FrameTVSupport: String?
        let VoiceSupport: String?
        let GamePadSupport: String?
        let ImeSyncedSupport: String?
        let developerMode: String?
        let firmwareVersion: String?
    }
}

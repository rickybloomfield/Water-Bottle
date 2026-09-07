import CoreBluetooth
import Foundation

/// Every GATT UUID known to be exposed by HidrateSpark bottles, plus the
/// advertising name prefix used to find them.
///
/// All of this comes from community reverse engineering (decompiled Android
/// app for the Spark 3; GATT exploration of PRO firmware 80.18 on the
/// nRF52832). Nothing here is vendor documented. See `docs/PROTOCOL.md`.
public enum HidrateUUID {
    /// Bottles advertise a local name starting with this prefix, e.g. `h2oDB618BB`.
    public static let advertisedNamePrefix = "h2o"

    // MARK: - Services

    /// "User" service. Hosts the modern sip-record characteristic on newer firmware.
    public static let userService = "BF2D1BA0-C473-49F2-9571-0CE69036C642"
    /// "Reference" service. Hosts the legacy sip-record and set-point characteristics.
    public static let referenceService = "45855422-6565-4CD7-A2A9-FE8AF41B85E8"
    /// Debug service (Spark 3 placement of the debug characteristic).
    public static let debugService = "593F756E-FAFC-49BA-8695-B39CA851B00B"
    /// Sensor service: accelerometer axes and, on PRO firmware, the weight stream.
    public static let sensorService = "F65399A1-D953-472D-8CA9-1AC71C4FFCB8"
    /// LED control service.
    public static let ledService = "4F817071-4180-434A-982B-422B4C9E6611"
    public static let batteryService = "180F"
    public static let deviceInformationService = "180A"
    public static let environmentalSensingService = "181A"
    public static let nordicUARTService = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    /// Nordic Secure DFU service. Its presence tells us how firmware updates are delivered.
    public static let nordicDFUService = "FE59"
    /// Telink OTA service (PRO 2, firmware 100.x): the puck is a Telink SoC, not a Nordic one.
    public static let telinkOTAService = "00010203-0405-0607-0809-0A0B0C0D1912"
    /// PRO 2: nine read-only characteristics `6AA5000x`, contents unknown (calibration/vendor data?).
    public static let vendorInfoService = "87290102-3C51-43B1-A1A9-11B9DC38478B"
    /// PRO 2: unknown command-style service A (one write, one read/write characteristic).
    public static let commandServiceA = "3BBD83E0-09BD-4B2D-A4E2-03E37694252B"
    /// PRO 2: unknown command-style service B (same shape as A).
    public static let commandServiceB = "3BBD83F0-09BD-4B2D-A4E2-03E37694252B"
    public static let txPowerService = "1804"

    // MARK: - Characteristics

    /// Modern sip-record channel: notify + write. Write `0x57` to drain one record.
    public static let userData = "BF2D1BA1-C473-49F2-9571-0CE69036C642"
    /// Legacy sip-record channel (present on firmware 80.18): notify + write.
    public static let dataPoint = "016E11B1-6C8A-4074-9E5A-076053F93784"
    /// Set-point / configuration writes (time of day, reminder schedule, glow).
    public static let setPoint = "B44B03F0-B850-4090-86EB-72863FB3618D"
    /// Debug writes during the handshake; also notifies cap open/close state.
    public static let debug = "E3578B0D-CAA7-46D6-B7C2-7331C08DE044"
    /// Weight stream: 2-byte big-endian value, roughly every 2 seconds.
    public static let weight = "1807A063-4E2D-4636-981A-35E93D1C7B94"
    public static let accelerometerX = "68485D94-DF75-441C-A457-0AF3DB0BD987"
    public static let accelerometerY = "13220723-6D7D-4056-8D92-85DE2109B5F5"
    public static let accelerometerZ = "603FC2C1-FA8E-4EAD-B4A2-E4EA82A78990"
    /// LED control: write a single pattern byte (see `LEDPattern`).
    public static let ledControl = "A1D9A5BF-F5D8-49F3-A440-E6BF27440CB0"
    public static let batteryLevel = "2A19"
    public static let temperature = "2A6E"
    public static let manufacturerName = "2A29"
    public static let modelNumber = "2A24"
    public static let serialNumber = "2A25"
    public static let firmwareRevision = "2A26"
    public static let hardwareRevision = "2A27"
    public static let softwareRevision = "2A28"
    public static let nordicUARTTX = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    public static let nordicDFUControlPoint = "8EC90001-F315-4F60-9FB8-838830DAEA50"
    public static let nordicButtonlessDFU = "8EC90003-F315-4F60-9FB8-838830DAEA50"
    /// Telink OTA control/data characteristic (read, write-without-response, notify).
    public static let telinkOTA = "00010203-0405-0607-0809-0A0B0C0D2B12"
    /// PRO 2: second sensor characteristic next to weight (read, notify). Meaning unknown.
    public static let sensorSecondary = "2007A063-4E2D-4636-981A-35E93D1C7B94"
    /// Reference service: 6 bytes read/write; bytes 0..1 = bottle capacity in mL (LE).
    public static let referenceConfig = "316C4914-1F59-462E-AF06-185418674C0C"
    /// LED service: state read-back.
    public static let ledState = "B810E826-CF05-4B46-A725-07BC0FA2E5D9"
    public static let commandA1 = "3BBD83E1-09BD-4B2D-A4E2-03E37694252B"
    public static let commandA2 = "3BBD83E2-09BD-4B2D-A4E2-03E37694252B"
    public static let commandB1 = "3BBD83F1-09BD-4B2D-A4E2-03E37694252B"
    public static let commandB2 = "3BBD83F2-09BD-4B2D-A4E2-03E37694252B"
    public static let txPowerLevel = "2A07"

    /// Device Information characteristics worth reading once per connection.
    public static let deviceInformationCharacteristics = [
        manufacturerName, modelNumber, serialNumber, firmwareRevision, hardwareRevision, softwareRevision,
    ]

    /// Canonical form used as dictionary keys everywhere in the SDK.
    public static func normalize(_ uuid: String) -> String {
        CBUUID(string: uuid).uuidString
    }

    /// Human-readable name for a known UUID, or nil.
    public static func name(for uuid: String) -> String? {
        names[normalize(uuid)]
    }

    private static let names: [String: String] = {
        var table: [String: String] = [
            userService: "Hidrate User Service",
            referenceService: "Hidrate Reference Service",
            debugService: "Hidrate Debug Service",
            sensorService: "Hidrate Sensor Service",
            ledService: "Hidrate LED Service",
            batteryService: "Battery Service",
            deviceInformationService: "Device Information",
            environmentalSensingService: "Environmental Sensing",
            nordicUARTService: "Nordic UART Service",
            nordicDFUService: "Nordic Secure DFU",
            userData: "User Data (sip records, modern)",
            dataPoint: "Data Point (sip records, legacy)",
            setPoint: "Set Point (config writes)",
            debug: "Debug (handshake writes / cap state notify)",
            weight: "Weight (u16 BE)",
            accelerometerX: "Accelerometer X",
            accelerometerY: "Accelerometer Y",
            accelerometerZ: "Accelerometer Z",
            ledControl: "LED Control",
            batteryLevel: "Battery Level",
            temperature: "Temperature",
            manufacturerName: "Manufacturer Name",
            modelNumber: "Model Number",
            serialNumber: "Serial Number",
            firmwareRevision: "Firmware Revision",
            hardwareRevision: "Hardware Revision",
            softwareRevision: "Software Revision",
            nordicUARTTX: "Nordic UART TX",
            nordicDFUControlPoint: "DFU Control Point",
            nordicButtonlessDFU: "Buttonless DFU",
            telinkOTAService: "Telink OTA Service",
            telinkOTA: "Telink OTA",
            vendorInfoService: "Vendor Info Service (PRO 2)",
            commandServiceA: "Command Service A (PRO 2, unknown)",
            commandServiceB: "Command Service B (PRO 2, unknown)",
            commandA1: "Command A1 (write)",
            commandA2: "Command A2 (read/write)",
            commandB1: "Command B1 (write)",
            commandB2: "Command B2 (read/write)",
            sensorSecondary: "Light activity (01 blue, 03 red, 00 off)",
            referenceConfig: "Bottle Config (capacity mL)",
            ledState: "LED State",
            txPowerService: "Tx Power",
            txPowerLevel: "Tx Power Level",
        ]
        let vendorNames = [
            1: "Vendor Info 1 (id / address?)", 2: "Vendor Info 2 (manufacturer string)",
            3: "Vendor Info 3 (product string)", 5: "Vendor Info 5", 6: "Vendor Info 6",
            7: "Vendor Info 7 (firmware version bytes)", 8: "Vendor Info 8 (hardware version?)",
            9: "Vendor Info 9", 10: "Vendor Info 10",
        ]
        for i in 1...10 {
            table[String(format: "6AA5%04X-6352-4D57-A7B4-003A416FBB0B", i)] = vendorNames[i] ?? "Vendor Info \(i)"
        }
        table = Dictionary(uniqueKeysWithValues: table.map { (normalize($0.key), $0.value) })
        return table
    }()
}

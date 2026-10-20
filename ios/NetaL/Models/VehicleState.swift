import Foundation

/// 统一车况模型。
///
/// 原 APK 有两套车况来源：
///   1. BLE 408 字节二进制报文 → 45 项信号
///   2. 云端 JSON → vehicleBasic / vehicleExtend / vehicleConnection 等分组
/// 两者通过 `CloudVehicleData.toVehicleState()` 归一到同一个 `VehicleState`。
/// Swift 端沿用这一设计。
struct VehicleState {

    // MARK: 车门与车身

    enum DoorState: String { case open = "开", closed = "关", unknown = "未知" }
    enum LockState: String { case locked = "已锁", unlocked = "未锁", unknown = "未知" }
    enum WindowState: String { case open = "开", closed = "关", unknown = "未知" }

    /// 前舱盖（theHoodState）
    var hood: DoorState = .unknown
    /// 尾门（trunkState）
    var trunk: DoorState = .unknown
    /// 主驾门（drivingDoorState）
    var driverDoor: DoorState = .unknown
    /// 副驾门（passengerDoorState）
    var passengerDoor: DoorState = .unknown
    /// 左后门（leftRearDoorState）
    var leftRearDoor: DoorState = .unknown
    /// 右后门（rightRearDoorState）
    var rightRearDoor: DoorState = .unknown
    /// 门锁总状态（doorsLockState）
    var doorsLock: LockState = .unknown
    /// 示宽灯（parkingLightsState）
    var parkingLights: Bool?
    /// 天窗（skylightState）
    var skylight: DoorState = .unknown

    // MARK: 车窗

    var frontLeftWindow: WindowState = .unknown
    var frontRightWindow: WindowState = .unknown
    var rearLeftWindow: WindowState = .unknown
    var rearRightWindow: WindowState = .unknown

    // MARK: 空调

    var airConditioningOn: Bool?
    /// 风量档位（airConditionWindState）
    var airWindLevel: Int?
    /// PTC 加热器（PTCState）
    var ptcOn: Bool?
    /// 主驾设定温度 ℃（driverSetTemperature）
    var driverSetTemperature: Double?
    /// 副驾设定温度 ℃（passengerSetTemperature）
    var passengerSetTemperature: Double?
    /// 车外温度 ℃（outdoorTemperature）
    var outdoorTemperature: Double?
    /// 车内温度 ℃（indoorTemperature）
    var indoorTemperature: Double?
    /// 车外温度有效标志（outdoorTemperatureAvailability）
    var outdoorTemperatureValid: Bool?
    /// 车内温度有效标志（indoorTemperatureAvailability）
    var indoorTemperatureValid: Bool?

    // MARK: 电池与充电

    enum ChargingState: String { case charging = "充电中", idle = "未充", fault = "故障", unknown = "未知" }

    var charging: ChargingState = .unknown
    /// 充电口连接（chargingConnectState）
    var chargePortConnected: Bool?
    /// 电量 %（batterySoc）
    var batterySOC: Double?
    /// 剩余充电时间 min（remainingChargingTime）
    var remainingChargingMinutes: Int?
    /// 电池最高温度 ℃（batteryMaxTemperature）
    var batteryMaxTemperature: Double?
    /// 低压模式（lowVoltageMode）
    var lowVoltageMode: Bool?

    // MARK: 里程

    /// 续航里程 km（availableMileage）
    var availableMileage: Double?
    /// 总行驶里程 km（totalMileage）
    var totalMileage: Double?

    // MARK: 座椅

    enum SeatHeatLevel: String { case off = "关", low = "低", mid = "中", high = "高", unknown = "未知" }
    enum SeatVentLevel: String { case off = "关", low = "低", mid = "中", high = "高", unknown = "未知" }

    var driverSeatHeating: SeatHeatLevel = .unknown
    var passengerSeatHeating: SeatHeatLevel = .unknown
    var driverSeatVentilation: SeatVentLevel = .unknown
    var passengerSeatVentilation: SeatVentLevel = .unknown
    /// 左座椅加热故障（leftSeatHeatingBreakdown）
    var leftSeatHeatingFault: Bool?
    /// 右座椅加热故障（rightSeatHeatingBreakdown）
    var rightSeatHeatingFault: Bool?

    // MARK: 轮胎（四轮独立）

    struct Tire: Equatable {
        var pressure: Double?      // 胎压，原文未标单位（通常 kPa 或 bar）
        var temperature: Double?   // ℃
    }

    var frontLeftTire = Tire()
    var frontRightTire = Tire()
    var rearLeftTire = Tire()
    var rearRightTire = Tire()

    // MARK: 驾驶

    enum Gear: String {
        case park = "P", reverse = "R", neutral = "N", drive = "D", unknown = "未知"
    }

    var gear: Gear = .unknown
    /// 自动驾驶状态（autoState）
    var drivingMode: String?

    // MARK: 连接

    /// BLE 连接状态（bleStatus / bleConnectionState）
    var bluetoothConnected: Bool?

    var isEmpty: Bool {
        hood == .unknown && trunk == .unknown && batterySOC == nil
            && outdoorTemperature == nil && totalMileage == nil
    }
}

// MARK: - BLE 408 字节报文解析

/// 解析车端推送的 408 字节车况报文。
///
/// 协议元信息（来自 `car_config.json` → `vehicleStatus.meta`，已确认）：
/// ```
/// version 1.0, length 408, headerLength 0, littleEndian 0
/// ```
/// 即固定 408 字节、**大端序**、无头部偏移。
///
/// ⚠️ 【待补全】各信号的字节偏移与位宽未知。
/// `car_config.json` 的 `items[]` 只提供了 key 名，没有 offset/length。
/// 需要抓取 BLE 实际报文并对照信号变化来确定下表。
/// 下面的偏移全部是占位值 0，**不要直接用于生产**。
struct VehicleStatusParser {

    static let expectedLength = 408
    static let isBigEndian = true

    enum ParseError: Error {
        case tooShort(actual: Int)
    }

    /// 已知信号名，与 car_config.json 的 items[] 一一对应（45 项，已确认）。
    static let signalNames: [String] = [
        "theHoodState", "trunkState", "drivingDoorState", "passengerDoorState",
        "leftRearDoorState", "rightRearDoorState", "parkingLightsState",
        "doorsLockState", "lowVoltageMode", "skylightState", "chargingConnectState",
        "gearState", "airConditionState", "autoState", "outdoorTemperatureAvailability",
        "outdoorTemperature", "driverSetTemperature", "passengerSetTemperature",
        "airConditionWindState", "PTCState", "baseState", "batteryChargingState",
        "remainingChargingTime", "batterySoc", "availableMileage", "totalMileage",
        "indoorTemperatureAvailability", "indoorTemperature",
        "flWindow", "frWindow", "rlWindow", "rrWindow",
        "driverSeatHeatingState", "passengerSeatHeatingState",
        "leftSeatHeatingBreakdown", "rightSeatHeatingBreakdown",
        "rlTirePressure", "rlTireTemperature", "rrTirePressure", "rrTireTemperature",
        "flTirePressure", "flTireTemperature", "frTirePressure", "frTireTemperature",
        "batteryMaxTemperature"
    ]

    /// 信号偏移表。
    ///
    /// ⚠️ 【全部为占位值，必须抓包后校准】
    ///
    /// 定位方法：
    /// ```
    /// 1. 录多组不同状态的报文（开后备箱 / 关后备箱 / 空调开 / 空调关 / 充电中…）
    /// 2. 把 408 字节按位 dump，逐组 diff
    /// 3. 会变化的位就是该信号的位置；不变但有意义的位通常是常量定义
    /// 4. 注意位域：状态类多为 1 字节或半字节，温度/电量/里程多为 2 字节有符号
    /// ```
    ///
    /// 填好这张表后，解析逻辑无需改动。
    struct SignalLayout {

        // 枚举类：通常 1 字节
        var theHoodState: Int = 0
        var trunkState: Int = 0
        var drivingDoorState: Int = 0
        var passengerDoorState: Int = 0
        var leftRearDoorState: Int = 0
        var rightRearDoorState: Int = 0
        var parkingLightsState: Int = 0
        var doorsLockState: Int = 0
        var skylightState: Int = 0
        var chargingConnectState: Int = 0
        var gearState: Int = 0
        var airConditionState: Int = 0
        var autoState: Int = 0
        var airConditionWindState: Int = 0
        var ptcState: Int = 0
        var batteryChargingState: Int = 0

        // 布尔：1 字节
        var lowVoltageState: Int = 0
        var outdoorTemperatureValid: Int = 0
        var indoorTemperatureValid: Int = 0
        var leftSeatHeatingFault: Int = 0
        var rightSeatHeatingFault: Int = 0

        // 座椅：1 字节
        var driverSeatHeating: Int = 0
        var passengerSeatHeating: Int = 0

        // 车窗：1 字节
        var frontLeftWindow: Int = 0
        var frontRightWindow: Int = 0
        var rearLeftWindow: Int = 0
        var rearRightWindow: Int = 0

        // 温度：2 字节有符号，通常除以 10
        var outdoorTemperature: Int = 0
        var indoorTemperature: Int = 0
        var driverSetTemperature: Int = 0
        var passengerSetTemperature: Int = 0
        var batteryMaxTemperature: Int = 0

        // 数值：2 字节
        var batterySoc: Int = 0
        var availableMileage: Int = 0
        var totalMileage: Int = 0
        var remainingChargingTime: Int = 0

        // 胎压/胎温：2 字节
        var frontLeftTirePressure: Int = 0
        var frontLeftTireTemperature: Int = 0
        var frontRightTirePressure: Int = 0
        var frontRightTireTemperature: Int = 0
        var rearLeftTirePressure: Int = 0
        var rearLeftTireTemperature: Int = 0
        var rearRightTirePressure: Int = 0
        var rearRightTireTemperature: Int = 0

        /// 温度/电量等带缩放系数的信号除数
        var temperatureScale: Double = 10
        var socScale: Double = 100
        var mileageScale: Double = 1

        /// 是否有任何偏移被校准过。
        /// 若全为 0，解析结果无意义，调用方应据此判断。
        var isCalibrated: Bool {
            theHoodState != 0 || trunkState != 0 || batterySoc != 0
                || outdoorTemperature != 0
        }
    }

    /// 偏移表（校准后替换默认值）
    var layout = SignalLayout()

    func parse(_ data: Data) throws -> VehicleState {
        guard data.count >= Self.expectedLength else {
            throw ParseError.tooShort(actual: data.count)
        }

        var state = VehicleState()

        // ⚠️ 以下偏移全部来自未校准的 SignalLayout，默认全 0，
        // 抓包校准前解析结果不可信。layout.isCalibrated 可用于判断。
        let l = layout

        // 大端序读取工具
        func u8(_ off: Int) -> UInt8? {
            guard off >= 0, off + 1 <= data.count else { return nil }
            return data[off]
        }
        func i16(_ off: Int) -> Int? {
            guard off >= 0, off + 2 <= data.count else { return nil }
            return Int(Int16(bitPattern: UInt16(data[off]) << 8 | UInt16(data[off + 1])))
        }
        func u16(_ off: Int) -> Int? {
            guard off >= 0, off + 2 <= data.count else { return nil }
            return Int(UInt16(data[off]) << 8 | UInt16(data[off + 1]))
        }

        // 车门
        state.hood      = Self.mapDoor(u8(l.theHoodState))
        state.trunk     = Self.mapDoor(u8(l.trunkState))
        state.driverDoor = Self.mapDoor(u8(l.drivingDoorState))
        state.passengerDoor = Self.mapDoor(u8(l.passengerDoorState))
        state.leftRearDoor = Self.mapDoor(u8(l.leftRearDoorState))
        state.rightRearDoor = Self.mapDoor(u8(l.rightRearDoorState))
        state.doorsLock = Self.mapLock(u8(l.doorsLockState))
        state.skylight  = Self.mapDoor(u8(l.skylightState))
        state.parkingLights = Self.mapBool(u8(l.parkingLightsState))

        // 车窗
        state.frontLeftWindow  = Self.mapWindow(u8(l.frontLeftWindow))
        state.frontRightWindow = Self.mapWindow(u8(l.frontRightWindow))
        state.rearLeftWindow   = Self.mapWindow(u8(l.rearLeftWindow))
        state.rearRightWindow  = Self.mapWindow(u8(l.rearRightWindow))

        // 空调
        state.airConditioningOn = Self.mapBool(u8(l.airConditionState))
        state.airWindLevel = u8(l.airConditionWindState).map(Int.init)
        state.ptcOn = Self.mapBool(u8(l.ptcState))

        // 温度
        state.outdoorTemperature = i16(l.outdoorTemperature).map { Double($0) / l.temperatureScale }
        state.indoorTemperature  = i16(l.indoorTemperature).map { Double($0) / l.temperatureScale }
        state.driverSetTemperature = i16(l.driverSetTemperature).map { Double($0) / l.temperatureScale }
        state.passengerSetTemperature = i16(l.passengerSetTemperature).map { Double($0) / l.temperatureScale }
        state.batteryMaxTemperature = i16(l.batteryMaxTemperature).map { Double($0) / l.temperatureScale }
        state.outdoorTemperatureValid = Self.mapBool(u8(l.outdoorTemperatureValid))
        state.indoorTemperatureValid = Self.mapBool(u8(l.indoorTemperatureValid))

        // 电池
        state.batterySOC = u16(l.batterySoc).map { Double($0) / l.socScale }
        state.remainingChargingMinutes = u16(l.remainingChargingTime)
        state.charging = Self.mapCharging(u8(l.batteryChargingState))
        state.chargePortConnected = Self.mapBool(u8(l.chargingConnectState))
        state.lowVoltageMode = Self.mapBool(u8(l.lowVoltageState))

        // 里程
        state.availableMileage = u16(l.availableMileage).map { Double($0) / l.mileageScale }
        state.totalMileage = u16(l.totalMileage).map { Double($0) / l.mileageScale }

        // 座椅
        state.driverSeatHeating = Self.mapSeatHeat(u8(l.driverSeatHeating))
        state.passengerSeatHeating = Self.mapSeatHeat(u8(l.passengerSeatHeating))
        state.leftSeatHeatingFault = Self.mapBool(u8(l.leftSeatHeatingFault))
        state.rightSeatHeatingFault = Self.mapBool(u8(l.rightSeatHeatingFault))

        // 轮胎
        state.frontLeftTire  = VehicleState.Tire(
            pressure: u16(l.frontLeftTirePressure).map { Double($0) },
            temperature: i16(l.frontLeftTireTemperature).map { Double($0) / l.temperatureScale })
        state.frontRightTire = VehicleState.Tire(
            pressure: u16(l.frontRightTirePressure).map { Double($0) },
            temperature: i16(l.frontRightTireTemperature).map { Double($0) / l.temperatureScale })
        state.rearLeftTire = VehicleState.Tire(
            pressure: u16(l.rearLeftTirePressure).map { Double($0) },
            temperature: i16(l.rearLeftTireTemperature).map { Double($0) / l.temperatureScale })
        state.rearRightTire = VehicleState.Tire(
            pressure: u16(l.rearRightTirePressure).map { Double($0) },
            temperature: i16(l.rearRightTireTemperature).map { Double($0) / l.temperatureScale })

        return state
    }

    // MARK: 枚举映射（取值范围需抓包校准）

    private static func mapDoor(_ raw: UInt8?) -> VehicleState.DoorState {
        switch raw {
        case 1: return .open
        case 2: return .closed
        default: return .unknown
        }
    }

    private static func mapWindow(_ raw: UInt8?) -> VehicleState.WindowState {
        switch raw {
        case 1: return .open
        case 2: return .closed
        default: return .unknown
        }
    }

    private static func mapLock(_ raw: UInt8?) -> VehicleState.LockState {
        switch raw {
        case 1: return .locked
        case 2: return .unlocked
        default: return .unknown
        }
    }

    private static func mapBool(_ raw: UInt8?) -> Bool? {
        switch raw {
        case 0: return false
        case 1: return true
        default: return nil
        }
    }

    private static func mapSeatHeat(_ raw: UInt8?) -> VehicleState.SeatHeatLevel {
        switch raw {
        case 0: return .off
        case 1: return .low
        case 2: return .mid
        case 3: return .high
        default: return .unknown
        }
    }

    private static func mapCharging(_ raw: UInt8?) -> VehicleState.ChargingState {
        switch raw {
        case 0: return .idle
        case 1: return .charging
        case 2: return .fault
        default: return .unknown
        }
    }
}

// MARK: - 云端车况 JSON

/// 云端返回的车况 DTO。
///
/// 字段名从 APK DEX 提取（已确认）。分组结构：
/// `vehicleBasic` / `vehicleExtend` / `vehicleConnection` / `carBoarStatus`
///
/// ⚠️ 字段的 JSON 类型与嵌套关系需抓包验证，此处按最可能的形式定义。
struct CloudVehicleData: Codable {
    var vehicleBasic: Basic?
    var airconditionStatus: Aircondition?
    var vehicleConnection: Connection?
    var lockStatus: Lock?
    var doorCoverStatus: DoorCover?
    var windowStatus: Win?
    var enduranceStatus: Endurance?

    struct Basic: Codable {
        var soc: Double?               // 电量百分比
        var mileage: Double?           // 总里程 ×10
        var speed: Double?
        var totalVoltage: Double?
    }
    struct Aircondition: Codable {
        var airWindLevel: Int?
        var airOutTemp: Double?        // ×10
        var airInTemp: Double?         // ×10
        var airTemp: Double?
    }
    struct Connection: Codable {
        var online: Bool?
        var onlineStatus: Int?
    }
    struct Lock: Codable {
        var driverSizeDoorLockStatus: Int?
        var coDriverSizeDoorLockStatus: Int?
        var leftAfterDoorLockStatus: Int?
        var rightAfterDoorLockStatus: Int?
    }
    struct DoorCover: Codable {
        var driverSizeDoorStatus: Int?
        var coDriverSizeDoorStatus: Int?
        var leftAfterDoorStatus: Int?
        var rightAfterDoorStatus: Int?
    }
    struct Win: Codable {
        var driverSizeWinStatus: Int?
        var coDriverSizeWinStatus: Int?
    }
    struct Endurance: Codable {
        var fuelMileageRemaining: Double?  // ×10 km
        var estimateFuelPercent: Double?
        var powerPercentage: Double?
    }

    func toVehicleState() -> VehicleState {
        var s = VehicleState()
        if let b = vehicleBasic {
            s.batterySOC = b.soc
            s.totalMileage = b.mileage.map { $0 / 10.0 }
        }
        if let a = airconditionStatus {
            s.outdoorTemperature = a.airOutTemp.map { $0 / 10.0 }
            s.indoorTemperature = a.airInTemp.map { $0 / 10.0 }
            s.airWindLevel = a.airWindLevel
        }
        if let e = enduranceStatus {
            s.availableMileage = e.fuelMileageRemaining.map { $0 / 10.0 }
        }
        if let l = lockStatus {
            // 0=已锁 1=未开（推断，待校准）
            let anyUnlocked = [l.driverSizeDoorLockStatus, l.coDriverSizeDoorLockStatus,
                               l.leftAfterDoorLockStatus, l.rightAfterDoorLockStatus]
                .contains(where: { $0 == 1 || $0 == 2 })
            s.doorsLock = anyUnlocked ? .unlocked : .locked
        }
        if let d = doorCoverStatus {
            s.driverDoor = d.driverSizeDoorStatus == 1 ? .open : .closed
            s.passengerDoor = d.coDriverSizeDoorStatus == 1 ? .open : .closed
            s.leftRearDoor = d.leftAfterDoorStatus == 1 ? .open : .closed
            s.rightRearDoor = d.rightAfterDoorStatus == 1 ? .open : .closed
        }
        if let w = windowStatus {
            s.frontLeftWindow = w.driverSizeWinStatus == 0 ? .closed : .open
            s.frontRightWindow = w.coDriverSizeWinStatus == 0 ? .closed : .open
        }
        return s
    }

    // MARK: 枚举映射（需抓包校准）

    private func mapDoor(_ raw: String?) -> VehicleState.DoorState {
        switch raw?.lowercased() {
        case "open", "opened", "1", "开":     return .open
        case "close", "closed", "0", "关":    return .closed
        default:                              return .unknown
        }
    }

    private func mapLock(_ raw: String?) -> VehicleState.LockState {
        switch raw?.lowercased() {
        case "lock", "locked", "1", "已锁":    return .locked
        case "unlock", "unlocked", "0", "未锁": return .unlocked
        default:                               return .unknown
        }
    }

    private func mapWindow(_ raw: String?) -> VehicleState.WindowState {
        switch raw?.lowercased() {
        case "open", "opened", "1", "开":  return .open
        case "close", "closed", "0", "关": return .closed
        default:                           return .unknown
        }
    }

    private func mapBool(_ raw: String?) -> Bool? {
        switch raw?.lowercased() {
        case "1", "true", "connected", "yes":  return true
        case "0", "false", "disconnected", "no": return false
        default:                                return nil
        }
    }
}
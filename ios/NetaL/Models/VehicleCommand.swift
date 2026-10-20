import Foundation

/// 车控指令。
///
/// 数据来源：`assets/car_config.json`（车型 EP30 / 哪吒 L）。
/// 46 条指令的编码值、tag、超时、iOS 接口名均为 APK 内明文，已确认。
enum VehicleCommand: UInt8, CaseIterable {

    case doorUnlock        = 1
    case doorLock          = 2
    case trunkUnlock       = 3
    case trunkLock         = 4
    case sunroofClose      = 5
    case sunroofOpen       = 6
    case sunroofVentilate  = 7
    case carSearch         = 8
    case startCharge       = 9
    case stopCharge        = 10
    case powerOn           = 11
    case powerOff          = 12
    case topLeftWindowOpen   = 13
    case topLeftWindowClose  = 14
    case topRightWindowOpen  = 15
    case topRightWindowClose = 16
    case bottomLeftWindowOpen   = 17
    case bottomLeftWindowClose  = 18
    case bottomRightWindowOpen  = 19
    case bottomRightWindowClose = 20
    case rearviewMirrorOpen  = 21
    case rearviewMirrorClose = 22
    case airConditionerOpen      = 23
    case airConditionerClose     = 24
    case airConditionerRefrigeration = 25
    case airConditionerHeating      = 26
    case parkingStart = 27
    case parkingStop  = 28
    case windowOpen    = 29
    case windowClose   = 30
    case ventilateClose     = 31
    case ventilateTenPercent = 32
    case accControlOn   = 33
    case accControlOff  = 34
    case remoteHeatingOn  = 35
    case remoteHeatingOff = 36
    case windSpeedLevel1  = 37
    case windSpeedLevel2  = 38
    case windSpeedLevel3  = 39
    case windSpeedLevel4  = 40
    case windSpeedLevel5  = 41
    case windSpeedLevel6  = 42
    case windSpeedLevel7  = 43
    case windSpeedLevel8  = 44
    case windSpeedLevel9  = 45
    case windSpeedLevel10 = 46

    /// 六位十六进制编码 `[功能组:状态:动作]`，APK 内明文，已确认。
    var value: String {
        switch self {
        case .doorUnlock:            return "010101"
        case .doorLock:              return "010100"
        case .trunkUnlock:           return "090101"
        case .trunkLock:             return "090100"
        case .sunroofClose:          return "030100"
        case .sunroofOpen:           return "030101"
        case .sunroofVentilate:      return "030102"
        case .carSearch:             return "150101"
        case .startCharge:           return "250101"
        case .stopCharge:            return "250100"
        case .powerOn:               return "260101"
        case .powerOff:              return "260100"
        case .topLeftWindowOpen:     return "270101"
        case .topLeftWindowClose:    return "270100"
        case .topRightWindowOpen:    return "280101"
        case .topRightWindowClose:   return "280100"
        case .bottomLeftWindowOpen:  return "290101"
        case .bottomLeftWindowClose: return "290100"
        case .bottomRightWindowOpen:   return "300101"
        case .bottomRightWindowClose:  return "300100"
        case .rearviewMirrorOpen:    return "200101"
        case .rearviewMirrorClose:   return "200100"
        case .airConditionerOpen:      return "040101"
        case .airConditionerClose:     return "040100"
        case .airConditionerRefrigeration: return "050100"
        case .airConditionerHeating:      return "050101"
        case .parkingStart:          return "1A0101"
        case .parkingStop:           return "1A0100"
        case .windowOpen:            return "310101"
        case .windowClose:           return "310100"
        case .ventilateClose:        return "320100"
        case .ventilateTenPercent:   return "320101"
        case .accControlOn:          return "330101"
        case .accControlOff:         return "330102"
        case .remoteHeatingOn:       return "340101"
        case .remoteHeatingOff:      return "340102"
        case .windSpeedLevel1:       return "350101"
        case .windSpeedLevel2:       return "350102"
        case .windSpeedLevel3:       return "350103"
        case .windSpeedLevel4:       return "350104"
        case .windSpeedLevel5:       return "350105"
        case .windSpeedLevel6:       return "350106"
        case .windSpeedLevel7:       return "350107"
        case .windSpeedLevel8:       return "350108"
        case .windSpeedLevel9:       return "350109"
        case .windSpeedLevel10:      return "35010A"
        }
    }

    /// 功能组（编码首段）。同一 tag 的指令共享分组标识。
    var tag: UInt8 {
        UInt8(value.prefix(2), radix: 16) ?? 0
    }

    /// 执行超时（秒），来自 car_config.json，已确认。
    var timeout: TimeInterval {
        switch self {
        case .doorUnlock, .doorLock:
            return 3
        case .trunkUnlock, .trunkLock:
            return 10
        case .sunroofClose, .sunroofOpen, .sunroofVentilate:
            return 15
        default:
            return 5
        }
    }

    /// 中文名，已确认。
    var displayName: String {
        switch self {
        case .doorUnlock:            return "解锁车门"
        case .doorLock:              return "闭锁车门"
        case .trunkUnlock:           return "开后备箱"
        case .trunkLock:             return "关后备箱"
        case .sunroofClose:          return "关闭天窗"
        case .sunroofOpen:           return "开启天窗"
        case .sunroofVentilate:      return "天窗通风"
        case .carSearch:             return "寻车"
        case .startCharge:           return "开始充电"
        case .stopCharge:            return "停止充电"
        case .powerOn:               return "一键上电"
        case .powerOff:              return "一键下电"
        case .topLeftWindowOpen:     return "左前车窗-开启"
        case .topLeftWindowClose:    return "左前车窗-关闭"
        case .topRightWindowOpen:    return "右前车窗-开启"
        case .topRightWindowClose:   return "右前车窗-关闭"
        case .bottomLeftWindowOpen:  return "左后车窗-开启"
        case .bottomLeftWindowClose: return "左后车窗-关闭"
        case .bottomRightWindowOpen:   return "右后车窗-开启"
        case .bottomRightWindowClose:  return "右后车窗-关闭"
        case .rearviewMirrorOpen:    return "后视镜-开启"
        case .rearviewMirrorClose:   return "后视镜-关闭"
        case .airConditionerOpen:      return "空调-开启"
        case .airConditionerClose:     return "空调-关闭"
        case .airConditionerRefrigeration: return "空调-制冷"
        case .airConditionerHeating:      return "空调-制热"
        case .parkingStart:          return "泊车-开启"
        case .parkingStop:           return "泊车-停止"
        case .windowOpen:            return "一键车窗控制-开启"
        case .windowClose:           return "一键车窗控制-关闭"
        case .ventilateClose:        return "一键通风-关闭"
        case .ventilateTenPercent:   return "一键通风-10%"
        case .accControlOn:          return "A/C控制指令-On"
        case .accControlOff:         return "A/C控制指令-Off"
        case .remoteHeatingOn:       return "远程加热指令-On"
        case .remoteHeatingOff:      return "远程加热指令-Off"
        case .windSpeedLevel1:       return "远程风速-Level1"
        case .windSpeedLevel2:       return "远程风速-Level2"
        case .windSpeedLevel3:       return "远程风速-Level3"
        case .windSpeedLevel4:       return "远程风速-Level4"
        case .windSpeedLevel5:       return "远程风速-Level5"
        case .windSpeedLevel6:       return "远程风速-Level6"
        case .windSpeedLevel7:       return "远程风速-Level7"
        case .windSpeedLevel8:       return "远程风速-Level8"
        case .windSpeedLevel9:       return "远程风速-Level9"
        case .windSpeedLevel10:      return "远程风速-Level10"
        }
    }

    /// 官方 iOS SDK 接口名。
    ///
    /// 第 1–28 条为 APK 内明文（已确认）；第 29–46 条被 R8 压缩，
    /// 此处按命名规律推断，仅作参考标识，实际调用需对照官方 iOS SDK。
    var iOSApiName: String {
        switch self {
        case .doorUnlock:            return "IngeekCommandDoorUnlock"
        case .doorLock:              return "IngeekCommandDoorLock"
        case .trunkUnlock:           return "IngeekCommandTrunkUnlock"
        case .trunkLock:             return "IngeekCommandTrunkLock"
        case .sunroofClose:          return "IngeekCommandSunRoofClose"
        case .sunroofOpen:           return "IngeekCommandSunRoofOpen"
        case .sunroofVentilate:      return "IngeekCommandSunRoofVentilate"
        case .carSearch:             return "IngeekCommandCarSearch"
        case .startCharge:           return "IngeekCommandStartCharge"
        case .stopCharge:            return "IngeekCommandStopCharge"
        case .powerOn:               return "IngeekCommandPowerOn"
        case .powerOff:              return "IngeekCommandPowerOff"
        case .topLeftWindowOpen:     return "IngeekCommandTopLeftWindowOpen"
        case .topLeftWindowClose:    return "IngeekCommandTopLeftWindowClose"
        case .topRightWindowOpen:    return "IngeekCommandTopRightWindowOpen"
        case .topRightWindowClose:   return "IngeekCommandTopRightWindowClose"
        case .bottomLeftWindowOpen:  return "IngeekCommandBottomLeftWindowOpen"
        case .bottomLeftWindowClose: return "IngeekCommandBottomLeftWindowClose"
        case .bottomRightWindowOpen:   return "IngeekCommandBottomRightWindowOpen"
        case .bottomRightWindowClose:  return "IngeekCommandBottomRightWindowClose"
        case .rearviewMirrorOpen:    return "IngeekCommandRearviewMirrorOpen"
        case .rearviewMirrorClose:   return "IngeekCommandRearviewMirrorClose"
        case .airConditionerOpen:      return "IngeekCommandAirConditionerOpen"
        case .airConditionerClose:     return "IngeekCommandAirConditionerClose"
        case .airConditionerRefrigeration: return "IngeekCommandAirConditionerRefrigeration"
        case .airConditionerHeating:      return "IngeekCommandAirConditionerHeating"
        case .parkingStart:          return "IngeekCommandParkingStart"
        case .parkingStop:           return "IngeekCommandParkingStop"
        case .windowOpen:            return "IngeekCommandWindowOpen"
        case .windowClose:           return "IngeekCommandWindowClose"
        case .ventilateClose:        return "IngeekCommandVentilateClose"
        case .ventilateTenPercent:   return "IngeekCommandVentilateTenPercent"
        case .accControlOn:          return "IngeekCommandAccControlOn"
        case .accControlOff:         return "IngeekCommandAccControlOff"
        case .remoteHeatingOn:       return "IngeekCommandRemoteHeatingOn"
        case .remoteHeatingOff:      return "IngeekCommandRemoteHeatingOff"
        case .windSpeedLevel1:       return "IngeekCommandRemoteWindspeedLevel1"
        case .windSpeedLevel2:       return "IngeekCommandRemoteWindspeedLevel2"
        case .windSpeedLevel3:       return "IngeekCommandRemoteWindspeedLevel3"
        case .windSpeedLevel4:       return "IngeekCommandRemoteWindspeedLevel4"
        case .windSpeedLevel5:       return "IngeekCommandRemoteWindspeedLevel5"
        case .windSpeedLevel6:       return "IngeekCommandRemoteWindspeedLevel6"
        case .windSpeedLevel7:       return "IngeekCommandRemoteWindspeedLevel7"
        case .windSpeedLevel8:       return "IngeekCommandRemoteWindspeedLevel8"
        case .windSpeedLevel9:       return "IngeekCommandRemoteWindspeedLevel9"
        case .windSpeedLevel10:      return "IngeekCommandRemoteWindspeedLevel10"
        }
    }

    /// 该指令是否有近场（BLE）实现。
    ///
    /// APK 中文文案显示并非所有动作都支持近场：
    /// 「该动作没有近场命令」「只支持网络的动作仍走网络」。
    /// 逐条的实际支持情况需抓包确认，此处按车厂常见做法给出保守默认。
    var supportsNearField: Bool {
        switch self {
        case .windowOpen, .windowClose,
             .ventilateClose, .ventilateTenPercent,
             .accControlOn, .accControlOff,
             .remoteHeatingOn, .remoteHeatingOff,
             .windSpeedLevel1, .windSpeedLevel2, .windSpeedLevel3,
             .windSpeedLevel4, .windSpeedLevel5, .windSpeedLevel6,
             .windSpeedLevel7, .windSpeedLevel8, .windSpeedLevel9,
             .windSpeedLevel10:
            // 这些批量/精细控制项文案归类为「按官方默认值一次下发」，
            // 更可能走网络通道。若抓包确认有近场实现，改为 true。
            return false
        default:
            return true
        }
    }

    /// 下发报文中的 command 字段。
    ///
    /// 字段名 `command` / `command_id` / `commandId` 均在 DEX 中出现（已确认），
    /// 但具体传数字编号还是 hex 值待抓包验证。
    var cloudPayload: [String: String] {
        [
            "command_id": String(rawValue),
            "command": value,
            "parameter": "0"
        ]
    }
}

// MARK: - 车控通道策略

/// 车控通道选择。原 APK 的三种模式，中文文案已确认。
enum ControlChannel: String, CaseIterable {
    /// 蓝牙已连接优先 BLE，未连接或下发失败回退网络
    case automatic
    /// 已按设置只走蓝牙，不发网络请求
    case bluetoothOnly
    /// 只经服务端下发
    case networkOnly

    var displayName: String {
        switch self {
        case .automatic:      return "自动"
        case .bluetoothOnly:  return "仅蓝牙"
        case .networkOnly:    return "仅网络"
        }
    }
}
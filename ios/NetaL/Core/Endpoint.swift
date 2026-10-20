import Foundation

/// 服务端 API 端点。
///
/// ## ⚠️ 全部来自 APK 静态提取的真实路径
///
/// 关键发现：API 路径规则是 `/pivot/<域>/<版本>/<方法>`，
/// 与最初猜测的 `/api/account/...` 完全不同。
/// 这批路径从 `classes.dex` 字符串池直接提取，共 14 个。
enum Endpoint {

    // MARK: 账号（登录/验证码）

    /// 发送验证码并校验签名。
    ///
    /// 对应中文文案：`验证码已发送`、`获取验证码`
    static let sendCode = "/pivot/account/2.0/sendCodeAndSignCheck"

    /// 注册或登录（未校验版本）。
    ///
    /// 对应中文文案：`登录哪吒汽车`、`登录失败`、`登录已过期`
    ///
    /// 注意：这是**注册与登录合一**的接口，不是分开两个。
    /// 参数中的 `login_channel` 决定行为。
    static let login = "/pivot/account/2.0/accountSafe/registerOrLoginUncheck"

    /// 刷新 API token。
    static let refreshToken = "/customer/account/info/refreshApiToken"

    // MARK: 车况

    /// 获取 App 端车辆数据。
    ///
    /// 对应中文文案：`车况获取失败`、`当前数据源没有可显示的其余车辆状态`
    static let vehicleStatus = "/pivot/veh-status/vehicle-status-control/1.0/getAppVehicleData"

    // MARK: 车控（RVC = Remote Vehicle Control）

    /// 下发车控指令。
    static let rvcSend = "/pivot/rvc-api/remoteControl/1.0/rvcCombined"

    /// 全部指令下发。
    static let rvcAll = "/pivot/rvc-api/remoteControl/1.0/rvcAll"

    /// 查询单条指令结果。
    static let rvcQuery = "/pivot/rvc-api/remoteControl/1.0/queryResult"

    /// 查询组合指令结果。
    static let rvcQueryCombined = "/pivot/rvc-api/remoteControl/1.0/queryCombinedResult"

    // MARK: 数字钥匙

    /// 上传 ECC 公钥。
    ///
    /// 对应中文文案：`上传公钥成功`、`上传公钥失败`
    static let eccPubkeyUpload = "/pivot/digitalkey/digitalkey/mobile/eccPubkeyUpload"

    /// 申请车主钥匙。
    ///
    /// 对应中文文案：`申请车主钥匙成功`、`申请车主钥匙失败`
    static let ownerKeyRequest = "/pivot/digitalkey/digitalkey/mobile/ownerKeyRequest"

    /// 激活钥匙。
    ///
    /// 对应中文文案：`激活钥匙失败`
    static let activeKey = "/pivot/digitalkey/digitalkey/mobile/activeKeyByID"

    /// 获取钥匙列表。
    ///
    /// 对应中文文案：`取钥匙列表失败`
    static let keyList = "/pivot/digitalkey/digitalkey/mobile/getKeyListByUserName"

    /// 下载钥匙原文。
    ///
    /// 对应中文文案：`下载钥匙原文成功`、`下载钥匙原文失败`
    static let downloadKeyRaw = "/pivot/digitalkey/digitalkey/mobile/downloadKeyRawDataByKeyIDList"

    /// 获取白名单（按 VIN 列表）。
    ///
    /// 对应中文文案：`白名单同步被车端拒绝`、`取白名单失败`
    static let whiteList = "/pivot/digitalkey/digitalkey/mobile/getWhiteListByVINList"

    // MARK: 证书

    /// 申请设备证书。
    static let applyCert = "/pivot/security-api/pki/cert/1.0/applyCert"

    // MARK: 外部服务

    /// 高德逆地理编码。
    static func amapRegeo(key: String) -> String {
        "https://restapi.amap.com/v3/geocode/regeo?key=\(key)&coord_type=bd09ll&src=neta-l-control"
    }
}
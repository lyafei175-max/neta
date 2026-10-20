# 哪吒L.apk 完整静态分析报告

**分析对象**：`D:\QQ文档\哪吒L.apk.1`
**分析时间**：2026-10-20
**分析方式**：静态分析（未安装、未运行、无网络请求）

---

## 一、文件指纹

| 项目 | 值 |
|---|---|
| 文件大小 | 1,581,846 字节（1.51 MB） |
| 压缩包条目 | 88 |
| 解压后总大小 | 2.86 MB |
| 格式 | 有效 ZIP/APK（`PK\x03\x04`） |
| SHA-256 | `a74d6dd8078914b4d22c1c613f8518d4dc082adaede4f8e0cec346463fdca641` |
| MD5 | `57d7264c7d6b9b7ccabd7d45140cb274` |
| SHA-1 | `68457993e185b0808e7785b80c5bb7b1ca855073` |

> 注意：扩展名是 `.apk.1`（QQ 下载产生的临时后缀），实际内容是标准 APK，可直接改名安装。

---

## 二、应用身份

| 项目 | 值 |
|---|---|
| 包名 | `app.netal` |
| 应用名 | 哪吒L |
| 版本号 | `0.1.4`（versionCode = 5） |
| minSdkVersion | 23（Android 6.0） |
| targetSdkVersion | 36（Android 16） |
| compileSdkVersion | 36 |
| 平台构建 | platformBuildVersionCode 36 / Name "16" |

### 构建工具链

- Android Gradle Plugin **8.7.3**
- Gradle **8.9**
- Kotlin Gradle Plugin **2.0.21**
- JVM 目标：**17**
- 启用 HMPP（Kotlin 跨模块）、未启用 KPM
- `appComponentFactory = androidx.core.app.CoreComponentFactory`
- VCS 版本号（Git）：`ec8170cb81e60898bef6ce34980f27a927590652`

---

## 三、签名情况（重要发现）

| 项目 | 值 |
|---|---|
| 签名方案 | **V1 + V2 已启用，V3 未启用** |
| 签名者 Subject | `CN=Android Debug, O=Android, C=US` |
| 签名者 Issuer | `CN=Android Debug, O=Android, C=US`（自签名） |
| 序列号 | `1` |
| 有效期 | 2026-10-17 05:46:10 UTC → 2056-10-09 05:46:10 UTC |
| 签名算法 | SHA256withRSA |
| 摘要算法 | SHA-256 |
| 打包工具 | Signflinger |

### 结论：这是二次打包（重签名）产物

依据三条互相印证的证据：

1. **证书是 Android 默认调试证书**（`Android Debug` / `O=Android`），有效期起点 2026-10-17，属于典型的本地调试签名，不是厂商正式发布证书。
2. **包名与配置来源不一致**：`assets/car_config.json` 头部标注 `source = com.hezhong.nezha assets/sdkConfig.json`（哪吒官方应用），但实际包名被改为 `app.netal`。
3. **应用名被改写**为「哪吒L」，与哪吒官方 App 命名体系不一致。

也就是说：这是从官方哪吒应用/SDK 抽取后，改包名、改应用名、用调试证书重签名打包的产物。

---

## 四、体积构成

| 路径 | 数量 | 大小 | 说明 |
|---|---|---|---|
| `classes.dex` | 1 | 2,650 KB | 唯一的 DEX，占绝大部分 |
| `resources.arsc` | 1 | 122 KB | 资源表 |
| `lib/` | 4 | 36.5 KB | 原生库（4 个 ABI） |
| `assets/` | 6 | 35.5 KB | 业务配置与证书 |
| `kotlin/` | 7 | 29.2 KB | Kotlin 内建元数据 |
| `META-INF/` | 52 | 20.2 KB | 依赖版本戳 + 签名 |
| `res/` | 14 | 19.3 KB | 图片与 XML |
| `AndroidManifest.xml` | 9.0 KB | | |
| `DebugProbesKt.bin` | 1.7 KB | | Compose 调试探针 |

### 原生库

仅一个库，四个 ABI：仅 armeabi-v7a / arm64-v8a / x86 / x86_64
`libandroidx.graphics.path.so`（7.1–10.8 KB）

这是 AndroidX Graphics 的矢量路径解析库，**不包含任何厂商自研 native 代码**。所有车控业务逻辑均在 Java/Kotlin 层。

---

## 五、权限清单（18 项）

### 蓝牙（4+2）

| 权限 | 备注 |
|---|---|
| `BLUETOOTH` | maxSdkVersion=30 |
| `BLUETOOTH_ADMIN` | maxSdkVersion=30 |
| `BLUETOOTH_CONNECT` | |
| `BLUETOOTH_SCAN` | |
| `BLUETOOTH_ADVERTISE` | |

配合 `<uses-feature android:name="android.hardware.bluetooth" android:required="false"/>`，蓝牙非必需硬件。

### 定位（3）

`ACCESS_FINE_LOCATION`、`ACCESS_COARSE_LOCATION`、`ACCESS_BACKGROUND_LOCATION`

### 网络与系统（5）

`INTERNET`、`RECEIVE_BOOT_COMPLETED`、`WAKE_LOCK`、`POST_NOTIFICATIONS`、
`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_CONNECTED_DEVICE`、`FOREGROUND_SERVICE_LOCATION`

### 自定义（1）

`app.netal.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`（protectionLevel=signature）
这是 AndroidX 自动生成的动态广播保护权限，用于收紧内部 receiver 导出范围。

### 权限风险评估

- **无** 通讯录、短信、电话、相机、麦克风、存储、设备管理员、开机无交互自启之外的敏感权限。
- 中文文案中提到「会向你填写的手机号发送一条真实短信」，但那是**云端短信网关**发送验证码，App 本身**没有** `SEND_SMS` 权限。
- 无 `READ_PHONE_STATE` 等设备指纹权限。
- 需要系统级或用户级授权的只有定位、蓝牙、通知，属车控场景合理需求。

---

## 六、组件清单

| 类型 | 类名 | 导出 | 要点 |
|---|---|---|---|
| Activity | `app.netal.MainActivity` | ✅ exported | 唯一 Launcher，Compose 界面，继承 `Lb/m;`（ComponentActivity 混淆） |
| Service | `app.netal.ble.tboe.ProximityUnlockService` | ❌ | 蓝牙近场自动解锁前台服务，`foregroundServiceType=0x18`（CONNECTED_DEVICE + LOCATION） |
| Receiver | `app.netal.ble.tboe.ProximityUnlockBootReceiver` | ✅ exported | 监听 `BOOT_COMPLETED`，开机自启 |
| Provider | `androidx.startup.InitializationProvider` | ❌ | AndroidX Startup 初始化 |
| Receiver | `androidx.profileinstaller.ProfileInstallReceiver` | ✅ | 基线配置安装 |

**核心业务代码只有 3 个类**（`app.netal.*`），其余 3,434 个类全部是 AndroidX / Kotlin / 混淆后的依赖库。

### 关键 Action

`app.netal.action.PROXIMITY_NOTIFICATION_COMMAND` — 状态栏通知上的操作按钮指令。

---

## 七、业务功能全景

从 DEX 中的 401 条中文字符串可以完整还原业务逻辑，这是一个**哪吒汽车（NETA / Hozon）车控演示应用**。

### 功能模块

| 模块 | 能力 |
|---|---|
| 账号登录 | 手机号 + 短信验证码登录，token 刷新，登录态过期检测 |
| 车辆绑定 | 绑定车辆、车辆列表、退出登录 |
| 云端车控 | 通过 HTTPS 下发车控指令 |
| 蓝牙近场车控 | BLE GATT 直连车机，近场控制 |
| 数字钥匙 | 钥匙申请、激活、同步、过期管理 |
| 靠近自动解锁 | RSSI 测距 + 阈值策略，靠近自动开锁 |
| 车况读取 | 45 项车辆状态信号解析 |
| 位置服务 | 高德逆地理编码、驻车位置导航 |
| 通道管理 | 车控通道设置（蓝牙 / 网络 / 自动） |

### 车控通道策略（中文文案还原）

应用有三种通道模式，可在设置中切换：

- **自动（默认）**：蓝牙已连接时优先使用蓝牙，未连接或下发失败时回退网络
- **仅蓝牙**：已按设置只走蓝牙
- **仅网络**：只经服务端下发

### 靠近自动解锁机制

从 DEX 数据类字符串可还原参数模型：

```
BleProximityMeasurement(averageRssi=..., ...)
BleProximityPolicy(enterThresholdDbm=..., ...)
NotificationSnapshot(isBluetoothConnected=...)
```

工作流程（依据中文状态文案还原）：

1. 后台周期扫描 BLE 设备（`后台周期扫描`）
2. 计算平均 RSSI（`$BleProximityMeasurement(averageRssi=`）
3. 与进入阈值比较（`enterThresholdDbm`）
4. 距离判定（`距驻车位置超过门限`、`距当前位置`）
5. 触发解锁（`此操作将解锁所有车门`、`确定执行`、`注意人身及车辆安全`）
6. 起扫前复核（`起扫前复核为远`）— 防抖设计
7. 状态栏通知显示（需 `允许通知后才能在状态栏查看自动开锁状态`）

日志标签：`ProximityUnlockService`、`BleScanCoordinator`

---

## 八、BLE 近场协议（TBOE）

### GATT 服务与特征

| UUID | 用途 |
|---|---|
| `0000fff1-0000-1000-8000-00805f9b34fb` | 主要特征（读写通道） |
| `0000fff2-0000-1000-8000-00805f9b34fb` | 次要特征 |
| `00002902-0000-1000-8000-00805f9b34fb` | CCCD（客户端特征配置，订阅通知） |

`0000fff1` / `0000fff2` 是典型的自定义透传模组 UUID（非 Nordic 标准串口服务），说明车端使用 BLE 透传模组传输自定义协议。

### 传输与分片

- `MTU=` 协商
- `车端报文分片丢失` — 支持分片
- `定长字段越界`、`收到不合法帧`、`响应不是合法`
- `TboeBleTransport.TboeSession` — 会话对象

### 握手与认证流程

从文案与字符串还原完整状态机：

```
连接请求 → 车端下发挑战码(Challenge) → 验签 → 连接应答验签 → 建立会话
```

涉及错误分支：

- `等待车端挑战码`、`挑战码为空`、`挑战码报文没有`、`挑战码报文解析失败`、`挑战码验签失败`
- `重试连接应答`、`连接应答没有`、`连接应答解析失败`、`连接应答验签失败`
- `车端拒绝连接`、`连接认证失败`、`连接抛异常`、`蓝牙连接失败`
- `会话类型不匹配`、`蓝牙会话已断开`

### 白名单机制

`白名单同步被车端拒绝`、`白名单同步没有回应`、`取白名单失败`、`缺少白名单且云端取不到`

---

## 九、云端 API 与认证

### 服务端点

| 端点 | 用途 |
|---|---|
| `https://appapi-pki.chehezhi.cn:18443` | 主 API（PKI/认证服务），端口 18443 |
| `https://restapi.amap.com/v3/geocode/regeo?key=` | 高德逆地理编码 |
| `*/pivot/security-api/pki/cert/1.0/applyCert` | 证书签发接口 |

> `chehezhi.cn` = 哪吒汽车（合众新能源）官方服务域名。

### 硬编码凭据（高危发现）

DEX 中完整保留了 `NetaApiConfig` 对象的 toString 输出：

```
NetaApiConfig(
  baseUrl=https://appapi-pki.chehezhi.cn:18443,
  appId=HOZON-B-xKrgEvMt,
  appKey=e0ae89fb37b6151889c6de3ba6b84e0d3a67f52cd5767758d4186fefff8f763c,
  appSecret=8b53846c4eb40e3f58df334a2f2ca0af6fba86f7999afd0b2ba794edc450b937,
  appVersion=6.4.2,
  channel=android,
  loginChannel=1
)
```

签名串格式：`cappid:HOZON-B-xKrgEvMtappkey:e0ae89fb...nonce:`

**这是完整的第三方应用级密钥对（appKey + appSecret），明文暴露，任何人提取后即可伪造合法客户端身份调用厂商 API。** 虽然是调试/演示密钥，但仍是严重的信息泄露。

### 高德地图 Key

`restapi.amap.com/v3/geocode/regeo?key=` — Key 值在运行时拼接，静态未取到完整值。`本进程不再使用高德` 表明支持定位服务切换。

### 认证要素

- `accessToken` / `access_token` / `refreshToken` / `isTokenInvalid`
- `/customer/account/info/refreshApiToken` — token 刷新端点
- `登录已过期`、`登录状态已变化`、`需要重新登录`
- `deviceID` / `device_id` / `deviceModel` / `deviceSysVersion`
- 请求体格式：`application/x-www-form-urlencoded;charset=utf-8`

---

## 十、加密与证书体系

### 密码学库

使用 **Google Tink**（多语言同源密码库），支持：

| 算法 | 用途 |
|---|---|
| `AES128_CTR_HMAC_SHA256` / `AES256_CTR_HMAC_SHA256` | 密钥材料加密 |
| `AES-GCM` / `AES-EAX` / `AES-SIV` / `AES-GCM-SIV` / `AES-CMAC` | AEAD 与 MAC |
| `ChaCha20Poly1305` / `XChaCha20Poly1305` | 流密码 |
| `HMAC-SHA256/384/512` | 完整性校验 |

依赖版本：`androidx.security:security-crypto:1.1.0-alpha06`（version 文件标记 14）

### 签名算法

- `SHA256withECDSA` — 设备/车辆密钥对（`eccPubkey`）
- `SHA256withRSA` — X.509 证书链

### 内置证书资产

| 文件 | 内容 |
|---|---|
| `assets/pki/hozon-ca.pem` | 哪吒根 CA（`CN=HOZON Root CA`，有效期 2022-05-24 → 2052-05-16，ECDSA P-256，SHA-384） |
| `assets/pki/preset.crt.pem` | 预置演示证书 `CN=Preset-demo`（`O=HOZON_CA, OU=Preset`），2022-06-04 → 2032-06-01，**由 HOZON Sub CA Preset 签发** |
| `assets/pki/preset.key.pem` | ⚠️ **预置证书的私钥明文** |

### 高危发现：预置私钥明文分发

`preset.key.pem` 包含完整的 RSA-2048 私钥（PKCS#8，1704 字节 Base64）。这是厂商分发给集成方的测试证书私钥，随包分发意味着：

- 任何拿到 APK 的人都能用它签发伪造的设备/车辆凭证
- 配合内置的 `hozon-ca.pem` 根证书，可构造一条受信任的伪造证书链
- 若服务端未做额外校验（如证书指纹白名单、车辆绑定校验），存在被冒用车辆身份的风险

### 证书申请与密钥材料流程

```
申请设备证书 → 组装设备证书 → 上传公钥(mobilePubkey) → 车端下载钥匙原文
→ 车端返回 vehiclePubkey → 密钥材料比对校验 → 申请车主钥匙 → 激活钥匙
```

相关文案：`申请设备证书失败`、`设备证书组装失败`、`客户端证书资产为空`、`车控将缺少客户端证书`、
`上传公钥成功/失败`、`下载钥匙原文成功/失败`、`车端公钥与钥匙材料不匹配`、
`申请车主钥匙成功/失败`、`激活钥匙失败`、`蓝牙钥匙已过期`、`取钥匙列表失败`

数据模型字段：`certificatePem`、`privateKeyPem`、`publicKeyPem`、`eccPubkey`、`mobilePubkey`、`vehiclePubkey`、
`keyDataVer`、`keyId`、`keyVersion`、`accessToken`、`refreshToken`

本地存储键：`neta_session`、`neta_device`、`neta_device_cert`、`neta_tboe_key`、`neta_cmd_params`、`neta_quick_slots`

---

## 十一、车控指令表（46 条）

来源：`assets/car_config.json`，车型 **EP30**（哪吒 L），appId `3bdd8886a6261935`

指令编码规律为 `[功能组:状态:动作]` 三段式六位十六进制。

### 车门与开闭（tag 1 / 9）

| # | 描述 | 值 | tag | 超时 |
|---|---|---|---|---|
| 1 | 解锁车门 | `010101` | 1 | 3s |
| 2 | 闭锁车门 | `010100` | 1 | 3s |
| 3 | 开后备箱 | `090101` | 9 | 10s |
| 4 | 关后备箱 | `090100` | 9 | 10s |

### 天窗（tag 3）

| # | 描述 | 值 | 超时 |
|---|---|---|---|
| 5 | 关闭天窗 | `030100` | 15s |
| 6 | 开启天窗 | `030101` | 15s |
| 7 | 天窗通风 | `030102` | 15s |

### 寻车与充电（tag 21 / 37）

| # | 描述 | 值 | 超时 |
|---|---|---|---|
| 8 | 寻车 | `150101` | 5s |
| 9 | 开始充电 | `250101` | 5s |
| 10 | 停止充电 | `250100` | 5s |

### 电源（tag 38）

| # | 描述 | 值 | 超时 |
|---|---|---|---|
| 11 | 一键上电 | `260101` | 5s |
| 12 | 一键下电 | `260100` | 5s |

### 车窗（四门独立，tag 39/40/41/48）

| # | 描述 | 值 | tag |
|---|---|---|---|
| 13/14 | 左前车窗 开/关 | `270101` / `270100` | 39 |
| 15/16 | 右前车窗 开/关 | `280101` / `280100` | 40 |
| 17/18 | 左后车窗 开/关 | `290101` / `290100` | 41 |
| 19/20 | 右后车窗 开/关 | `300101` / `300100` | 48 |

### 后视镜（tag 32）

`REARVIEW_MIRROR_OPEN` = `200101`，`CLOSE` = `200100`

### 空调（tag 4 / 5）

| # | 描述 | 值 | tag |
|---|---|---|---|
| 23/24 | 空调 开/关 | `040101` / `040100` | 4 |
| 25/26 | 制冷/制热 | `050100` / `050101` | 5 |

### 泊车（tag 26）

`PARKING_STARTING` = `1A0101`，`PARKING_STOP` = `1A0100`

### 批量控制

| # | 描述 | 值 | tag |
|---|---|---|---|
| 29/30 | 一键车窗 开/关 | `310101` / `310100` | 49 |
| 31/32 | 一键通风 关闭/10% | `320100` / `320101` | 50 |

### A/C 与加热（tag 51 / 52）

| # | 描述 | 值 | tag |
|---|---|---|---|
| 33/34 | ACC 控制 On/Off | `330101` / `330102` | 51 |
| 35/36 | 远程加热 On/Off | `340101` / `340102` | 52 |

### 风速档位（tag 53，10 档）

`REMOTE_WINDSPEED_LEVEL1` ~ `LEVEL10` = `350101` ~ `35010A`

> 注意：Level10 用十六进制 `A` 表示 10。

### 执行结果

每次下发有独立超时（3–15s），超时报错：`但没等到车端执行结果`、`车端未回报执行结果`、
`车端条件不满足`、`车门或尾门未关`、`车窗未全开`、`车锁未锁`、`加油口盖未锁`

---

## 十二、车况信号（45 项）

来自 `car_config.json` → `vehicleStatus`，协议定义：`version 1.0`，`length 408` 字节，`headerLength 0`，`littleEndian 0`（大端）

即车况以固定 **408 字节**二进制报文传输，按此长度解析各信号字段。

### 车门与车身状态

`theHoodState`（前舱盖）、`trunkState`（尾门）、`drivingDoorState`（主驾门）、
`passengerDoorState`（副驾门）、`leftRearDoorState`、`rightRearDoorState`、
`doorsLockState`（门锁）、`parkingLightsState`（示宽灯）、`skylightState`（天窗）、
`flWindow` / `frWindow` / `rlWindow` / `rrWindow`（四门车窗）

### 空调与温度

`airConditionState`、`airConditionWindState`（风量）、`PTCState`（加热器）、
`driverSetTemperature`（主驾设定温度 ℃）、`passengerSetTemperature`（副驾设定温度 ℃）、
`outdoorTemperature`（车外温度 ℃）、`outdoorTemperatureAvailability`、
`indoorTemperature`（车内温度 ℃）、`indoorTemperatureAvailability`

### 电池与充电

`batteryChargingState`、`batterySoc`（电量 %）、`remainingChargingTime`（剩余充电时间 min）、
`chargingConnectState`（充电口连接状态）、`baseState`、`lowVoltageMode`（低压模式）、
`batteryMaxTemperature`（电池最高温度 ℃）

### 里程与能量

`availableMileage`（续航里程 km）、`totalMileage`（总行驶里程 km）

### 座椅

`driverSeatHeatingState`、`passengerSeatHeatingState`、
`leftSeatHeatingBreakdown`、`rightSeatHeatingBreakdown`（座椅加热故障分解）

### 轮胎（4 轮独立）

`flTirePressure` / `flTireTemperature` / `frTirePressure` / `frTireTemperature` /
`rlTirePressure` / `rlTireTemperature` / `rrTirePressure` / `rrTireTemperature`

### 驾驶状态

`gearState`（挡位）、`autoState`（自动驾驶状态）

### 故障状态

中文文案中的故障类别：`充电故障`、`休眠故障`、`低压电源`、`等待故障`、`故障状态提醒`

---

## 十三、地图与定位集成

通过 `<queries>` 声明查询以下地图应用（用于检测是否安装、走系统 Intent 跳转）：

| 包名 | 应用 |
|---|---|
| `com.autonavi.minimap` | 高德地图 |
| `com.baidu.BaiduMap` | 百度地图 |
| `com.tencent.map` | 腾讯地图 |
| `com.google.android.apps.maps` | Google Maps |

功能：高德逆地理编码（`高德逆地理命中`、`高德逆地理失败`、`解析驻车地址`）、
驻车位置导航（`导航去驻车位置`、`无驻车坐标`）

坐标系：`coord_type=bd09ll`（百度坐标），`src=neta-l-control`

隐私处理：`不读取或保存经纬度` — 明确声明不持久化位置数据。

---

## 十四、网络安全配置

`res/8G.xml` → `network-security-config`：

```xml
<network-security-config>
  <base-config cleartextTrafficPermitted="false">
    <trust-anchors>
      <certificates src="system"/>
      <certificates src="user"/>
    </trust-anchors>
  </base-config>
</network-security-config>
```

评估：

- ✅ 禁止明文 HTTP（`cleartextTrafficPermitted="false"`），与 `https://` 端点一致
- ⚠️ **信任用户证书**（`certificates src="user"`）—— 这允许用用户安装的 CA 做中间人代理抓包。调试用途常见，发布版通常应移除，否则 HTTPS 保护形同虚设
- 应用声明 `allowBackup="false"`（禁止备份）✅

---

## 十五、混淆分析

| 指标 | 值 |
|---|---|
| DEX 类总数 | 3,437 |
| 业务类（`app.netal.*`） | 3 |
| 混淆包（单/双字母） | 168 个根包、3,197 个类 |
| 明文类名 | 业务 3 个全保留，其余全混淆 |
| 资源名混淆 | ✅ 已混淆（`res/22.xml`、`res/o-.png` 等随机名） |
| 未混淆依赖 | androidx / kotlin（正常，依赖库通常保留） |

混淆工具特征：单字母包名 + 类名（如 `A/a`、`A/b`、`b/m`、`u1/s`）+ 方法名字母化（`a`、`b`、`c`），
典型 **R8 + resource shrinking/obfuscation** 配置。

对逆向的影响：资源名映射被打乱，二进制 XML 需通过资源表 ID 反查；但**字符串常量全部保留明文**，
且业务包名 `app.netal.*` 未混淆，因此业务逻辑与协议分析基本未受影响。

---

## 十六、第三方依赖清单

| 库 | 版本 | 用途 |
|---|---|---|
| androidx.compose.* | 1.7.x 系列 | Jetpack Compose UI（96 类） |
| androidx.lifecycle | 2.8.x | 生命周期（47 类） |
| androidx.core | 1.13+ | 核心兼容 |
| androidx.security:security-crypto | 1.1.0-alpha06 | Tink 加密封装 |
| androidx.profileinstaller | 1.4 | 基线配置 |
| androidx.startup | 1.2 | 初始化 |
| com.google.* | 71 类 | Tink 密码库 + protobuf |
| kotlinx.coroutines | 1.8+ | 协程 |
| Kotlin stdlib | 2.0.21 | 运行时 |

无 OkHttp / Retrofit（网络层应为原生 `HttpURLConnection`，DEX 中可见 `Ljava/net/HttpURLConnection;`）。

---

## 十七、风险与问题汇总

### 高危

| # | 问题 | 详情 |
|---|---|---|
| 1 | **appKey / appSecret 明文硬编码** | `HOZON-B-xKrgEvMt` 的完整密钥对写入 DEX 字符串池，任何人可提取伪造客户端身份调用厂商 API |
| 2 | **预置证书私钥明文分发** | `assets/pki/preset.key.pem` 包含完整 RSA-2048 私钥，配合内置 `hozon-ca.pem` 根证书可构造受信任的伪造凭证链 |
| 3 | **调试证书签名的正式功能包** | 使用 `Android Debug` 证书，无法通过任何正式渠道发布；也意味着无法验证原始厂商签名 |

### 中危

| # | 问题 | 详情 |
|---|---|---|
| 4 | 信任用户证书 | `network-security-config` 含 `certificates src="user"`，HTTPS 可被用户主动 MITM（调试便利但削弱防护） |
| 5 | 高精度后台定位 | `ACCESS_BACKGROUND_LOCATION` + `ACCESS_FINE_LOCATION` + 前台服务 LOCATION 类型，后台持续扫描 BLE 需要精确定位支撑 |
| 6 | 开机自启 + 常驻前台服务 | `BOOT_COMPLETED` 触发 + `WAKE_LOCK` + 常驻前台服务，电量与隐私持续消耗 |

### 低危 / 提示

| # | 问题 | 详情 |
|---|---|---|
| 7 | 车门控制安全提示不足 | 文案有「注意人身及车辆安全」「此操作将解锁所有车门」「确定执行」，但仅靠 UI 提示，无二次验证 |
| 8 | 位置服务硬依赖 | 文案显示「原厂连接流程要求系统位置服务开启」，体验依赖系统设置 |
| 9 | 无反调试/防篡改 | 未见 root 检测、完整性校验、签名自校验 |

### 合规观察

- 权限最小化做得较好，无通讯录/短信/相机/麦克风/存储越权
- 明确声明「不读取或保存经纬度」，位置数据仅用于实时逆地理
- 短信验证码由云端网关发送，App 无 `SEND_SMS` 权限
- 应用名「哪吒L」+ 调试签名 + 修改包名的组合，**不具备官方发布资质**，若对外分发存在商标与合规风险

---

## 十八、总结

### 这是什么

一款**哪吒汽车（Neta L / 车型代号 EP30）的车控功能演示应用**，完整实现了官方车控 SDK 的核心能力：云端车控 + 蓝牙近场控制 + 数字钥匙 + 靠近自动解锁。

### 技术画像

- Kotlin + Jetpack Compose 现代 Android 应用
- 单 DEX、2.65 MB、无厂商 native 库（纯 Kotlin 层实现）
- R8 全量混淆（业务包名未混淆）
- 依赖 Google Tink 做端到端加密，X.509 证书链做设备身份
- BLE 自定义透传协议（TBOE）+ HTTP 云端协议双通道

### 三句话结论

1. **功能真实且完整**——不是壳应用，46 条车控指令、45 项车况信号、BLE 握手验签状态机、RSSI 靠近解锁策略全部实装。
2. **是重打包产物**——Android Debug 证书 + 包名从 `com.hezhong.nezha` 改为 `app.netal` + 应用名改「哪吒L」，三处证据确证。
3. **存在真实的密钥泄露**——厂商 appKey/appSecret 与预置证书私钥均明文随包分发，这是本次分析中最值得注意的问题。

---

*本报告基于纯静态分析生成，未安装运行应用，未发起任何网络请求。所有数据均从 APK 文件本身提取。*
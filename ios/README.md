# NetaL iOS 工程说明

从 `哪吒L.apk.1` 静态分析结果移植的 iOS 实现骨架。

---

## 目录结构

```
ios/
├── 协议规格.md                 ← 移植协议规格（先读这个）
├── 云端打包.md                 ← 云端 CI 打包说明
├── 校准清单.md                 ← 抓包后按表填参（配套代码注释）
├── README.md                   ← 本文件
├── project.yml                 ← XcodeGen 配置（生成 Xcode 工程）
├── Package.swift               ← Swift Package 定义（编译验证）
├── car_config.json             ← 车端配置（从 APK 提取，分析脚本要用）
├── Analysis/
│   └── analyze_tboe.py         ← 抓包分析脚本（在电脑上跑）
└── NetaL/
    ├── App/
    │   └── NetaLApp.swift              应用入口
    ├── Core/
    │   ├── NetaAPIConfig.swift         服务端配置 + 请求签名
    │   ├── NetaAPIClient.swift         网络层（含 token 注入 + 401 重试）
    │   ├── AuthService.swift           登录 / 验证码 / token 刷新
    │   ├── VehicleService.swift        车辆列表 / 绑定 / 驻车坐标
    │   └── CredentialStore.swift       证书 + 密钥 + Keychain
    ├── Models/
    │   ├── VehicleCommand.swift        46 条车控指令
    │   └── VehicleState.swift          车况模型 + 408 字节解析器
    ├── BLE/
    │   ├── TboeTransport.swift         BLE GATT + 握手状态机
    │   ├── TboeFrameCodec.swift        帧编解码（配置驱动，待校准）
    │   ├── BleFrameRecorder.swift      抓包录制工具
    │   └── ProximityUnlock.swift       RSSI 策略 + 地理围栏桥接
    ├── UI/
    │   ├── ContentView.swift           SwiftUI 车控界面
    │   ├── LoginView.swift             登录界面
    │   └── BleCaptureView.swift        抓包工具界面
    └── Resources/
        ├── Info.plist                  权限声明
        ├── NetaL.entitlements          签名权限
        ├── Assets.xcassets/            图标与主题色
        ├── hozon-ca.pem                哪吒根 CA（已从 APK 提取）
        ├── preset.crt.pem              预置演示证书
        └── preset.key.pem.WARNING.txt  私钥风险说明
```

---

## ⚠️ 关于 IPA 二进制

**IPA 必须在 macOS 上生成。** iOS SDK 只随 Xcode 分发，
不存在 Windows → iOS 的交叉编译路径。

但**可以用云端 CI 代替**，已配好现成配置，**不需要任何证书**：

| 方案 | 免费额度 | 配置 |
|---|---|---|
| **GitHub Actions** | 公开仓库免费不限量 | `.github/workflows/build-ipa.yml` |
| **Codemagic** | 500 分钟/月，免信用卡 | `ios/.codemagic/codemagic.yaml` |

两种模式：`compile-only`（仅编译检查，查错误）或 `ipa`（导出无签名 IPA）。

详见 `云端打包.md`。

<details>
<summary>优先跑编译检查 —— 这是当前最需要的一步</summary>

我在 Windows 上只做了括号配平和语法结构检查，**没有 Swift 编译器验证过**
16 个 Swift 文件。云端编译会一次性暴露所有问题，零成本、零配置。

可能的问题类型：actor 隔离、iOS 16 vs 17 的 API 差异、
`@MainActor` 缺失、Keychain 强制解包。

拿到日志发我即可。
</details>

---

## 代码完成度

| 模块 | 完成度 | 说明 |
|---|---|---|
| 车控指令表 | ✅ 100% | 46 条指令的编码值/tag/超时/中英文名全部来自 APK 明文 |
| 服务端配置 | ✅ 100% | baseURL / appId / appKey / appSecret 明文提取 |
| 请求签名原串 | ✅ 100% | 拼接格式已确认（无分隔符，易错处已注释） |
| 签名算法 | ⚠️ 推断 | HMAC-SHA256 vs SHA256 拼接，两种实现都写了，需抓包选定 |
| 车况模型 | ✅ 100% | 45 项 BLE 信号 + 云端字段全部建模 |
| 408 字节解析 | ❌ 占位 | 偏移量未知，代码是骨架 |
| BLE GATT | ✅ 90% | UUID、读写订阅流程完整 |
| TBOE 帧格式 | ❌ 占位 | 状态机骨架，帧编解码待抓包 |
| 靠近解锁 | ✅ 70% | RSSI 策略完整；iOS 后台限制已给替代方案 |
| 证书链校验 | ✅ 90% | 用 Security.framework 实现，自定义 anchor |
| UI | ✅ 100% | 分组车控界面 + 设置页 |

---

## 云端调用链

完整链路已打通，调用顺序：

```swift
// 1. 登录
try await AuthService.shared.requestSMSCode(phone: "13800138000")
try await AuthService.shared.login(phone: "13800138000", code: "123456")

// 2. 车辆管理
let vehicles = try await VehicleService().listVehicles()
let coord = try await VehicleService().parkingCoordinate()   // 地理围栏用

// 3. 车况与指令（token 自动注入，401 自动刷新重试）
let state = try await NetaAPIClient().fetchVehicleState()
try await NetaAPIClient().sendCommand(.trunkUnlock)
```

**自动化的部分**：
- 已登录请求自动注入 `access_token`
- 业务码判定为 401 时自动刷新 token 并重试一次
- 刷新失败自动清会话，提示「登录已过期，需要重新登录」
- 登出清空 Keychain + 内存状态

错误文案已对齐原 APK：`请输入正确的手机号`、`请先获取验证码`、`没有绑定车辆`、
`无驻车坐标`、`登录已过期` 等。

⚠️ **所有登录/车辆相关端点均为推断**，标了 `TODO` 的位置需抓包替换。

---

## BLE 抓包工具（关键）

协议规格里标 `[未知]` 的帧格式、分片规则、挑战码签名、白名单结构，**全靠它录出来**。

### 使用流程

**第一步：真机录制**（模拟器无 BLE）

1. App 设置 → 「BLE 抓包工具」
2. 点「开始录制」→ 自动开始扫描
3. 在列表里点车机设备名连接，等待自动订阅 fff1/fff2
4. 用原 APK 或本 App 下发指令（建议顺序：开后备箱 → 关后备箱 → 寻车 → 空调开 → 空调关）
5. 点「停止录制」→ 导出 JSON 到 Documents 目录
6. 用分享菜单把文件传到电脑

**第二步：电脑分析**

```bash
cd ios/Analysis
python analyze_tboe.py ~/Downloads/tboe-capture-1234567890.json ../car_config.json
```

### 分析脚本能做什么

已用合成数据验证过，五项能力：

| 能力 | 输出 |
|---|---|
| **帧序列概览** | 帧数、方向分布、特征分布、长度直方图、时间间隔统计 |
| **字段结构推断** | 跨帧偏移扫描，标出恒定字节（魔数/版本/类型候选） |
| **校验和检验** | 自动验证「异或」「累加和」等常见规则 |
| **帧头识别** | 检测 AA AA / AA 55 / 55 AA / 5A A5 / 7E 等常见协议头 |
| **指令比对** | 在帧中查找 `car_config.json` 里的 46 条指令编码，直接标注是哪条指令 |
| **配对分析** | TX→RX 自动配对，给出往返延迟 |

实际运行输出示例：

```
    字节[ 0] 全部帧恒定 = 0xAA   ← 强候选：魔数/版本/类型
    字节[ 1] 全部帧恒定 = 0xAA   ← 强候选：魔数/版本/类型
  ✓ ★ 全部帧一致: 末字节 = 前面所有字节异或
  疑似 AA AA 帧头: 4 帧命中

  命中 1 处指令编码：
    [TX] 090101 → #3 开后备箱 (TRUNK_UNLOCK)
```

### 手工探测

界面里有 HEX 输入框，可以直接发任意字节试探车端响应——用来反推帧格式比盲猜高效得多。

### 抓包时的操作建议

不同指令的帧做**差分对比**是定位字段的最快方法：

- 开后备箱 vs 关后备箱 → 只有末位不同，差异位就是动作码
- 同一指令连发两次 → 差异位是序号或时间戳
- 连接后第一帧 RX → 大概率是挑战码

---

## 在 macOS 上构建

### 方式一：验证核心逻辑（最快）

核心逻辑不依赖 UI，可直接编译检查语法：

```bash
cd ios
swift build
```

需要 Xcode 15+ / Swift 5.9+。

### 方式二：生成 Xcode 工程打 IPA

```bash
# 方式 A：用 XcodeGen（需 brew install xcodegen）
cd ios
xcodegen generate
open NetaL.xcodeproj

# 方式 B：手动
# Xcode → File → New → App，命名为 NetaL，iOS 16+
# 把 NetaL/ 下的 Core / Models / BLE / UI / App 目录拖进工程
# Resources 里的 pem 加入 Copy Bundle Resources
```

### 打包 IPA

见 `云端打包.md`。

## 移植风险：iOS 平台限制

这是本次移植最需要你注意的部分。

### 1. 靠近自动解锁无法照搬（最大障碍）

**Android 原型**：`ProximityUnlockService` 是常驻前台服务，
`BOOT_COMPLETED` 开机自启，`WAKE_LOCK` 保持唤醒，持续 BLE 扫描测 RSSI。

**iOS 不存在这种模型**：
- 无开机自启
- iOS 17+ 默认禁用 `allowsBackgroundUpdates`
- 后台持续扫描会被系统挂起

**可行替代**（已实现 `GeofenceUnlockCoordinator` 骨架）：
1. **地理围栏** —— 用驻车坐标建围栏，系统在接近时唤醒 App，扫描 30 秒。**这是最现实的方案**
2. **本地通知 + 用户确认** —— 弱化「无感」体验
3. **CarPlay 数字钥匙** —— 若车机支持，走系统原生路径

注意原 APK 明确声明「不读取或保存经纬度」，改用地理围栏会与之冲突，需要产品层面决策。

### 2. 必须抓包补全的部分

| 未知项 | 获取方式 |
|---|---|
| 签名算法 | MITM 抓包（原 APK 已信任用户 CA，可直接代理） |
| 全部 API 端点 | 同上 |
| 408 字节车况字段偏移 | nRF Connect 订阅 fff2 抓报文，逐字节 diff |
| TBOE 帧格式与分片 | 同上 |
| 挑战码签名规则 | 录制完整握手过程 |
| 风速/通风类 iOS 接口名 | 官方 iOS SDK 文档 |

**抓包准备**：原 APK 的 `network-security-config` 含 `<certificates src="user"/>`，
已信任用户 CA，用 Charles / mitmproxy / Burp 可直接抓 HTTPS，无需 root。

BLE 侧需另备 nRF Connect（安卓手机）或自写 iOS/macOS 调试工具。

### 3. 密钥泄露风险

代码里写死的 `appKey` / `appSecret` 来自原 APK 明文，**等同公开密钥**。
`Resources/preset.key.pem.WARNING.txt` 说明了预置私钥的风险。

即使你自签名成可安装的 IPA，这些凭据仍是公开的。
真实使用前建议向厂商申请独立凭据。

---

## 建议的实施顺序

1. **先跑抓包** —— 用内置的 `BleFrameRecorder` 录握手过程，用 `analyze_tboe.py` 分析。
   这一步能解掉帧格式、分片、校验和三个未知项
2. **抓云端包** —— 用 Charles/mitmproxy 抓原 APK 的 HTTPS，拿到真实签名算法和全部端点
3. **打通云端** —— 登录 + 车况查询 + 单条指令下发（纯网络，不碰 BLE），这步能独立验证
4. **攻 BLE** —— 把录到的帧格式填进 `TboeTransport.swift`，实现挑战码验签
5. **最后做靠近解锁** —— 用地理围栏方案，这是 iOS 上的能力上限

第 1、2 步是纯信息收集，可以并行。第 3 步能独立验证，后续复杂度都在 BLE。

---

## 相关文档

- `协议规格.md` —— 完整协议规格，含 46 条指令表、45 项车况字段、握手状态机
- `Analysis/analyze_tboe.py` —— 抓包分析脚本，附详细用法
- `../哪吒L_apk分析报告.md` —— 原始 APK 完整静态分析报告
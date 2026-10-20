# NetaL — 哪吒汽车 iOS 客户端

从 `哪吒L.apk` 静态分析移植的 iOS 实现。

## 结构

- `ios/` — Swift 工程（16 个源文件）
- `ios/协议规格.md` — 移植协议规格
- `ios/校准清单.md` — 抓包后填参指引
- `ios/云端打包.md` — GitHub Actions 打包说明
- `哪吒L_apk分析报告.md` — 原始 APK 分析报告

## 打包

Actions → Build IPA → Run workflow

- `compile-only` 仅编译检查
- `ipa` 导出无签名 IPA

无需证书配置。

# HotelFlow

HotelFlow 是使用 SwiftUI、SwiftData、PDFKit 和 Vision 的原生 iPhone 清扫助手。最低运行版本为 iOS 17。iOS 26 的系统 TabView 使用系统玻璃外观。酒店名称、担当者与已确认别名可在「今日 → 设置」填写。公开构建默认留空。定制的私有构建可通过 Xcode 构建设置 `HOTELFLOW_HOTEL` 与 `HOTELFLOW_EMPLOYEE` 提供默认值。

## 导入与校对

1. 使用「导入今日清扫 PDF」，或在 LINE 已下载 PDF 的系统分享菜单选择 HotelFlow。
2. 扩展复制文件到 App Group 后显示回到 HotelFlow 的提示。打开主 App，进入该文件的校对页。
3. 检查日期、房号、担当者、任务、入住人数和备注。点击 PDF 位置可查看原文，缺少的房间可手动添加。
4. 同日修订会先展示差异。确认后保留既有工作状态、耗时和人工修改历史。
5. 在房间中依次记录清扫和检查步骤。备品页可查看合计，房间详情可勾选已准备数量。

原始 PDF、识别结果与历史均保存在本机。备份包含 PDF 和工作记录，请保存到受控位置。选择恢复备份会替换现有工作记录。

## 云端构建

在 Actions 中运行 **HotelFlow iOS**。Push 和 Pull Request 也触发构建。macOS Runner 会选择装有 iOS 26 SDK 的 Xcode，通过 XcodeGen 生成工程，运行 XCTest，再编译 iPhone Release 主程序及分享扩展。

**HotelFlow-unsigned-IPA** 包含设备端 IPA，需要签名后才能安装。**HotelFlow-build-and-test-logs** 包含 XCTest 结果和日志。

可选签名仅在 main 分支手动运行。配置变量 `HOTELFLOW_SIGN_ENABLED=true`、`HOTELFLOW_BUNDLE_ID` 与 `HOTELFLOW_APP_GROUP`，并添加下列 Secrets。

| Secret | 内容 |
| --- | --- |
| `HOTELFLOW_TEAM` | Apple Developer Team ID |
| `HOTELFLOW_CERTIFICATE` | Base64 编码 p12 |
| `HOTELFLOW_CERTIFICATE_PASSWORD` | p12 密码 |
| `HOTELFLOW_APP_PROFILE` | 主 App 描述文件，Base64 |
| `HOTELFLOW_SHARE_PROFILE` | 分享扩展描述文件，Base64 |

两个描述文件都必须允许同一个 App Group，扩展的显式 Bundle ID 为主 App ID 加 `.share`。签名产物由 **HotelFlow-signed-IPA** 提供。开发及 Ad Hoc 安装依赖描述文件内已注册的设备，App Store 签名需要通过 Apple 分发。

## 验收状态

当前自动化用例使用合成文本和程序生成的 PDF。真实酒店 2026-11-17 文件未提供，真实 PDF 准确率及 LINE 分享尚待真机验收。发现低置信度、未知布局或缺失页面时，请根据原始 PDF 校对。没有真实样本可验证合并单元格和复杂跨行表格。

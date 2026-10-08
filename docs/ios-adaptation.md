# iPhone 适配与安装

此分支为现有 Flutter 应用补充 iOS 15+ 工程；Android 应用与已有账号数据继续保留。iOS 的 Bundle ID 为 `com.xmum.attendance-assistant`。应用版本沿用 0.7.4，首次 iOS 发布前可统一调整版本。

## 已接入的功能

| 功能 | iPhone 实现 |
| --- | --- |
| 账号管理、签到流程、课表 | 复用 Dart 业务逻辑与现有界面，保留安全区和返回拦截 |
| 密码和课表缓存 | iOS Keychain，`unlocked_this_device`，不通过 iCloud 同步 |
| Student-5G 系统确认 | `NEHotspotConfiguration` + PEAP，身份及外层身份同时更新，服务器名称限学校域名 |
| Student-5G 手动模式 | 提示用户在“设置 → Wi-Fi”修改身份和密码，观察离开应用并返回后核验 |
| Student 网页认证 | 共用 Dart 注销、挑战值、登录与实际身份检查，iOS 通道执行 HTTPS 请求与重连提示 |
| 校园请求 | 检查 Wi-Fi 名称、IPv4 和连接变化；URLSession 禁止蜂窝网络，并在请求前后检查连接 |
| 教务/CAS 会话 | 每次新建独立临时 URLSession 与 Cookie 存储；结束时清除 Cookie 并关闭会话 |
| 账号文件 | CryptoKit AES-256-GCM + CommonCrypto PBKDF2-SHA256；兼容原 Android `.xmumaccounts` 格式 |
| 文件选择 | iOS “文件”选择器，支持本机及 iCloud 文件位置；临时导出仅保存已加密的内容 |

所有签到成功条件、提交前再查询、提交后核验以及禁止自动重发的规则保持一致。课表获取使用独立 AC 会话，可使用正常互联网连接；签到/CAS 和校园认证通道禁止蜂窝回退。没有增加后台定时签到。

## iOS 与 Android 的差异

- iOS 没有公开的 Android `networkHandle` 或全进程 Wi-Fi 路由绑定 API。本实现的 `handle` 是观察到的 Wi-Fi 路径、SSID、BSSID、IP 或安全类型变化的代数，不伪造“新连接”。系统确认模式要求苹果明确接受配置更新，手动模式要求应用观察到用户离开并返回；两种模式均等待前台稳定连接，再要求学校连续两次确认本机 IP 的实际 Campus ID。配置成功和连接 Wi-Fi 都不直接算作身份核验成功。
- iOS 的 `alreadyAssociated` 错误不算更新成功，避免把旧身份当作新配置；请重试或改为手动模式。学校/MDM 安装的网络描述文件可能阻止应用更新同名配置，此时按学校要求手动配置。
- 苹果公开接口无法直接打开系统 Wi-Fi 子页面。应用使用重连提示，请自行打开“设置 → Wi-Fi”；不使用 `App-Prefs:` 等私有 URL。手动切换需实际离开应用并返回。
- 苹果公开 EAP API 未提供 PEAP 第二阶段选择器。自动模式使用 PEAP 默认内层认证；需要 GTC 时使用学校配置或手动模式。不要将 TTLS 的内层配置冒充 PEAP 设置。
- SSID 读取依赖 Access Wi-Fi Information entitlement 和精确位置授权；应用只检查权限及网络信息，不启动位置坐标采集。iOS 的本地网络授权也可能影响校园认证服务。拒绝权限或无法读取真实 SSID 时停止。
- Wi-Fi、学校证书与真实账号切换需要实体 iPhone，模拟器不适用于校园网络验收。

## 在 Mac 上编译并安装

1. 安装 Flutter 3.47.4（Dart 3.13.3）或满足 `pubspec.lock` 的兼容版本、Xcode 及 iOS 开发组件。
2. 在仓库 `mobile_app` 目录运行：

   ```sh
   flutter config --enable-swift-package-manager
   flutter pub get --enforce-lockfile
   flutter analyze
   flutter test
   flutter build ios --simulator --debug
   open ios/Runner.xcworkspace
   ```

   此工程使用 Flutter 生成的 Swift Package Manager 插件集成，无需手工创建 Pods 或把生成文件提交到仓库。
3. 在 Xcode 的 Runner → Signing & Capabilities 中选择自己的开发团队，保持 Automatically manage signing；如该 Bundle ID 无法注册，改成自己团队的唯一 ID。确保签名配置包含 **Hotspot Configuration、Access Wi-Fi Information、Keychain Sharing**。仓库的 `Runner.entitlements` 已声明相关权限。没有在源码中填入他人的 Team ID、证书或签名密码；团队必须有这些能力的授权。
4. 连接并信任 iPhone，按系统要求开启 Developer Mode，选择该设备运行，或执行 `flutter run -d <iphone-device-id>`。iPhone 与 Mac 需使用匹配的开发签名配置。
5. 启动后先保存虚构账号，确认钥匙串读写和界面；真实使用时按提示允许“使用 App 期间”和精确位置，允许本地网络，再连接校园 Wi-Fi。

用于 TestFlight/App Store 时，需要有效 Apple Developer Program 团队及 App Store Connect 应用记录。准备好签名后在 Mac 执行 `flutter build ipa --release`，通过 Xcode/Transporter 上传。仓库源码和未签名模拟器构建不能直接安装在普通 iPhone 上。

官方依据：[Flutter iOS 发布](https://docs.flutter.dev/deployment/ios)、[苹果 Wi-Fi 系统配置](https://developer.apple.com/documentation/networkextension/nehotspotconfigurationmanager/apply(_:completionhandler:))、[SSID 读取条件](https://developer.apple.com/documentation/networkextension/nehotspotnetwork/fetchcurrent(completionhandler:))、[EAP 服务器名称校验](https://developer.apple.com/documentation/networkextension/nehotspoteapsettings/trustedservernames)。

## 验证

`.github/workflows/ios.yml` 在 macOS 执行 Flutter 分析、全部单元/界面测试、未签名 iOS 模拟器编译和 RunnerTests 原生加密测试。`test/fixtures/archive-interop.json` 使用独立 .NET 实现生成，只含虚构账号和公开测试密码，验证 Unicode 传输密码及 Android ciphertext+tag 格式。

真机离线测试请使用独立 QA Bundle ID，如 `com.xmum.attendance-assistant.qa`，在专用测试副本中调整 Xcode Bundle ID 并用自己团队签名；不要让 Flutter 默认卸载正式包。测试命令：

```sh
flutter test integration_test/smoke_test.dart -d <iphone-device-id> --no-uninstall
flutter test integration_test/archive_crypto_test.dart -d <iphone-device-id> --no-uninstall
```

`smoke_test` 使用独立 iOS Keychain `accountName=attendance_qa_only`，不读取/清理正式账号；档案测试仅操作虚构文件，文件选择器测试需要人工选择保存及打开位置。不要运行 Android 专用的 `integration_test/campus_network_test.dart` 来验收 iOS。RunnerTests 可直接用 Xcode → Product → Test。

校园真机验收顺序：

1. 账号新增、编辑、冷启动后读取、删除，确认 Keychain 持久化。
2. Android 导出到 iPhone、iPhone 导出到 Android；分别检查签到密码、校园网密码及 AC 密码，测试错误传输密码和损坏文件。
3. Student-5G 系统确认及手动模式：取消操作、权限拒绝、已关联、错误密码、身份不匹配均停止；相同 IP 的账号切换必须由学校连续两次核验当前学生身份。
4. Student 旧版：注销当前账号、手动重连、确认离线并登录目标账号；认证页的 AC 参数必须来自当前网络，不能写死。
5. 使用账号菜单“测试登录 / 查询（不签到）”，先确认 CAS 登录、课程查询及清理；再验证 AC 课表。
6. 由本人在场，在学校实际开放签到时验证一次提交与学校记录确认；断网或失败不自动重发。

Flutter 测试、模拟器构建和原生加密测试不代表学校真实签到或 iPhone 校园网络已验收。App Store 发布前还应按实际数据处理填写隐私说明和加密出口合规信息。

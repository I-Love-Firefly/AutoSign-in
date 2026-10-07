# AutoSign-in

厦门大学马来西亚分校签到助手：Flutter Android 应用，支持账号安全存储、校园网认证切换、课程查询、签到结果核验、AC 系统课表和加密账号导入导出。

应用版本、使用方式、开发命令与已知限制见 [mobile_app/README.md](mobile_app/README.md)。接口依据见 [mobile_app/API_NOTES.md](mobile_app/API_NOTES.md) 和 [AC 登录接口记录](docs/ac-login-api.md)。

## 开发

安装 Flutter SDK 和 Android 开发环境，在 `mobile_app` 下执行：

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --debug --flavor production
```

开发机首次构建若缺少 Android Gradle wrapper，可在 `mobile_app` 下运行 `flutter create --platforms=android .` 生成本地工具文件；请检查生成后的差异，保留现有原生通道及 production/qa 配置。

真机测试使用独立 QA 包，详细命令及避免卸载正式应用的说明见应用 README。`scripts/test-device.ps1` 的 Flutter 路径需要按本机环境调整。

## 验证范围

测试覆盖业务规则和接口契约，真实环境已核验登录及课程查询；真实签到提交仍需在学校开放签到时由本人验证。课表、网络探测或客户端测试不能代表学校确认出勤。请仅用于本人在场且符合学校要求的操作。

## 仓库内容

本仓库仅包含项目源码、测试和开发文档。本地抓包、第三方前端资源、设备截图、个人网络诊断、构建产物、签名密钥和账号档案不上传。

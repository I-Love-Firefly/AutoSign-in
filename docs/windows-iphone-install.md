# 使用 Windows 获取和安装 iPhone 版

Windows 可以下载安装包并协助安装；iOS 编译由 GitHub Actions 的 macOS 环境完成，无需自己拥有 Mac。此版本支持 iOS 15 及以上。

## 先确认签名条件

这个签到助手需要 **Access Wi-Fi Information** 和 **Hotspot Configuration**。苹果的[官方权限支持表](https://developer.apple.com/help/account/reference/supported-capabilities-ios)将这两项列为付费开发团队支持的能力，普通免费开发者账号不支持。

因此，普通 Apple 账号通过 Sideloadly/AltStore 重新签名，可能因权限拒绝而安装失败，也可能删掉这些权限后安装成功，但校园 Wi-Fi 核验及系统配置无法正常工作。应用会停止相关流程，不能把“装上了”当作完整功能可用。免费侧载通常还需每 7 天续签，参见 [Sideloadly 官方 FAQ](https://sideloadly.io/faq)。不要删除 Wi-Fi 核验来绕过权限限制。

对目前只有普通 Apple 账号的使用者，完整使用的路径是：由拥有付费 Apple Developer Program 的开发者签名发布，再邀请你通过 **TestFlight** 安装。使用者不需要购买开发者会员；发布者需要会员、证书、匹配权限的描述文件及 App Store Connect 配置。此仓库尚未配置这些凭据或上传 TestFlight。

## 从 Windows 获取真机安装包

1. 打开仓库 [Actions → iOS checks](https://github.com/I-Love-Firefly/AutoSign-in/actions/workflows/ios.yml)，选择 `codex/iphone-support` 分支对应的成功运行。
2. 下载页面底部 `iPhone-unsigned-needs-developer-signing` artifact ZIP 并解压。
3. ZIP 中的 `AutoSign-in-iPhone-unsigned.ipa` 是 **ARM64 真机 Release 构建，尚未签名，不能直接安装**。`Required-entitlements.plist` 列出签名需要保留的权限；另附本说明。
4. 将源码或未签名包交给自己的签名团队。团队应注册匹配的 Bundle ID、启用上述两项 Wi-Fi 能力以及 Keychain Sharing，为包内应用和 Frameworks 正确签名。最终应用的签名 entitlement 和 embedded provisioning profile 必须匹配；不得仅移除声明来让安装通过。

构建产物保存 14 天。主分支合入后可在 Actions 中手动运行工作流重新生成。模拟器 `.app` 不能改名为 IPA 安装到真机。

## 安装已经正确签名的版本

- **TestFlight（普通账号推荐）**：签名团队先完成归档、上传及所需审核，向你提供邀请链接；你在 iPhone 安装苹果 TestFlight 并接受邀请即可。Windows 可用于访问仓库和管理邀请，安装在手机端完成。
- **开发 / Ad Hoc 包**：签名团队先将你的 iPhone UDID 加入描述文件，再生成匹配的 IPA。通过支持保留已有签名及描述文件的 Windows 设备部署工具安装；如果安装工具重新签名，必须重新检查两项 Wi-Fi entitlement、Keychain group 和设备授权，不能默认普通账号重签可用。按苹果要求信任电脑及启用 Developer Mode。安装工具和签名方式应由签名团队确认。

如果使用 Windows 侧载工具做界面试用，可从 [Sideloadly 官方网站](https://sideloadly.io/)获取工具，按其官方说明安装 Apple 设备驱动、连接 USB、在手机上信任电脑，并在工具内完成 Apple 登录。不要把 Apple 密码、证书私钥或描述文件上传到公开仓库或聊天。界面试用不等于校园签到可用。

安装后的真机核验步骤见 [iPhone 适配与安装](ios-adaptation.md)。模拟器已验证的功能不能代替学校现场的 Wi-Fi、身份切换和实际签到验收。

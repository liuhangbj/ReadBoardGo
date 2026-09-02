# ReadBoard Go

ReadBoard Go 是 ReadBoard 的独立远程客户端，面向 iPhone、iPad 和 Mac。抓取、数据库、处理任务和平台授权仍运行在 ReadBoard 服务端；Go 只通过版本化 API 访问服务。

## 当前能力

- Bonjour 自动发现局域网服务器
- 首次固定服务器 TLS 证书并使用访问密码登录
- 一次性配对码作为备用连接方式
- Keychain 保存设备凭据
- 读取服务能力与设备权限
- 支持搜索、筛选和游标分页的内容列表
- 原文、译文和转录切换，支持已读与收藏状态同步
- 与 ReadBoard 一致的纸墨设计系统和低饱和状态标签
- macOS 侧栏、内容列表、正文三层阅读布局，iOS/iPadOS 自适应触控导航
- 订阅源和运行状态界面
- iOS 17+ 与 macOS 14+ 工程

## 开发

```sh
xcodegen generate
swift test
open ReadBoardGo.xcodeproj
```

macOS 本地构建并启动：

```sh
./script/build_and_run.sh --verify
```

当前通过 `CoreVersion.env` 锁定一个不可漂移的 ReadBoard Core 提交。更新共享内核时，
先修改该文件，再执行 `./script/update_core_ref.sh <commit>`；脚本会同步 SwiftPM、
XcodeGen 与已提交的 Xcode 工程。命令行联合开发可显式设置
`READBOARD_CORE_PATH=../readboard` 使用本地 Core；普通构建、干净克隆与 CI 使用
锁定的远程提交。

所有 ReadBoard API 连接均强制使用 HTTPS，并固定首次信任的服务器证书。
自托管 API 使用独立的 Network.framework TLS 通道，不依赖公共 CA 或域名证书；
信任由精确 SHA-256 证书指纹、证书有效期和同源限制决定，App Transport Security
不做全局放行；文章图片和 WebView 仍按系统策略处理，既有媒体与局域网例外不变。
公网直连还应配合强访问密码、限流和必要的防火墙策略；公网 CA 证书或安全隧道仍是可选的运维加强。

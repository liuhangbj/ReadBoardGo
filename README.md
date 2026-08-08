# ReadBoard Go

ReadBoard Go 是 ReadBoard 的独立远程客户端，面向 iPhone、iPad 和 Mac。抓取、数据库、处理任务和平台授权仍运行在 ReadBoard 服务端；Go 只通过版本化 API 访问服务。

## 当前能力

- 手动输入服务器地址和一次性配对码
- Keychain 保存设备凭据
- 读取服务能力与设备权限
- 基础文章列表、正文、订阅源和运行状态界面
- iOS 17+ 与 macOS 14+ 工程

## 开发

```sh
xcodegen generate
swift test
open ReadBoardGo.xcodeproj
```

当前依赖 ReadBoard 的 `codex/service-middleware-foundation` 分支。服务端中间层合并并发布首个 API tag 后，应改为固定的语义版本依赖。

当前传输支持局域网 HTTP，以便连接现有 ReadBoard 服务。请勿把服务端口直接暴露到公网；公网访问将在 TLS 支持完成后开放。

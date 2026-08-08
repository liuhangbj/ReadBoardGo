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

当前依赖 ReadBoard 的 `main` 分支。服务端发布首个稳定 API tag 后，应改为固定的语义版本依赖。

所有连接均使用 HTTPS，并固定首次信任的服务器证书。当前自签名证书适合可信局域网；直接公网访问仍应配合正式域名证书或安全隧道。

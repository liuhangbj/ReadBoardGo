# ReadBoard Go 项目入口

适用的统一质量契约版本：`1`

本仓库属于 ReadBoard 多仓库项目。开始任何工作前，必须完整读取并遵守相邻 Core 仓库的统一质量契约：

```text
../readboard/AGENTS.md
```

如果该文件可用但版本不是 `1`，必须先报告版本差异并按较严格的规则执行。独立克隆中该文件不可用时，下面的内置最低契约仍然生效，但不得宣称完成了“完整 ReadBoard 项目审核”，直到从项目固定的 Core 来源加载并核对版本 `1` 的统一契约：

- 主 Agent 是唯一产品代码写入者；独立审核 Agent 对所有仓库文件只读，产物必须隔离到临时目录或一次性 Worktree。
- 先还原需求和验收标准，再审查架构与复用；实现后必须分别检查业务流程 / 数据、UI、安全和 QA，任何不适用项都要说明。
- 用户可见改动必须验证真实 App；认证、媒体、远程访问、数据写入和发布按 `R3` 处理。
- 无证据不得宣称完成、部署或可发布；创建提交、推送、部署和发布分别需要用户对应授权。
- 发现 P0 / P1 后不得结束，必须由主 Agent 修复并让独立审核 Agent 复验。

本仓库补充约束：

1. Go 是远程客户端，只保留连接引导、设备凭据、Remote Gateway 注入、离线缓存、平台生命周期、分享扩展和打包资源；抓取、数据库、Worker、平台授权和服务端依赖不在客户端实现。
2. 通用页面和状态模型直接使用 Core 的 `ReadBoardFeatures` / `ReadBoardUI`。发现缺口时先修改 Core 共享层和 Contract，再更新 Go；不得在 Go 复制页面作为临时补丁。
3. 所有远程写操作必须验证权限拒绝、超时、重复提交、乐观更新回滚和重连后的权威状态；网络失败不得显示为空数据或健康状态。
4. 凭据、访问密码、TLS 首次固定、设备 token、scope 和断连缓存属于 R3，必须进行安全与隐私审核。
5. 联合开发的 SwiftPM 测试可以显式使用本地 Core：

```bash
READBOARD_CORE_PATH=../readboard swift test
```

6. Xcode App 和发布构建使用固定 Core SHA。更新共享内核时，必须在用户授权 Core 提交后执行：

```bash
./script/update_core_ref.sh <40-character-core-commit>
./script/verify_core_ref.sh
./script/build_and_run.sh --verify
```

只通过本地 SwiftPM 测试不能证明 Go App 已使用新 Core。正式验收还必须构建 iOS，并按 CI / 打包脚本验证 macOS 产物同时包含 `arm64` 与 `x86_64`。

7. 当前 Release 工作流仍需单独修复并复验“签名凭据缺失时跳过签名 / 公证但仍继续发布”的历史阻断项；本规则文件的提交不代表该阻断项已经关闭。

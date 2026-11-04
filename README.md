# 云吞插件：Actual Budget

把 [Actual Budget](https://actualbudget.org)（MIT）装成云吞插件：本地优先的家庭记账和信封预算，网页经云吞网关直接以主人身份打开。插件 ID 是 `org.actualbudget.actual`，用的镜像是上游官方 `actualbudget/actual-server`。

通用写法（compose 子集、权限、注入变量、开发环境参数）见[插件模板的 README](https://github.com/geraldpeng6/wonton-plugin-template)，这里只写这个插件自己的事。

## 登录

`sso: proxy`。核心生成一个 32 字节密钥存进密钥库，网关每个请求带上 `x-actual-password: {secret:server_password}`；Actual 开 `ACTUAL_LOGIN_METHOD=header`，拿这个值和服务器密码比对。

服务器没有从环境变量设初始密码的开关。一次性服务 `init` 只等应用进程启动，再调用 `/account/bootstrap` 把密钥设成密码，已经设过就跳过；最后用头认证登录一次，确认能用才退出。MCP 只依赖 `init` 成功退出，初始化失败会直接附上它的日志，不先等待 Actual 的健康检查。初始化请求超时为 10 秒；仅连接被拒绝会在 120 秒启动窗口内重试。

上游 actual#4488 的网页只在服务器报的登录方式是 header 时自动提交头认证，而报的方式来自 `auth` 表里的行。`init` 因此还补一条 `header` 行并把 password 行设为非默认；不补会看到密码框。头认证只认 `ACTUAL_TRUSTED_AUTH_PROXIES` 里的来源地址，地址池可能是任意网段，所以这里放开为 `0.0.0.0/0,::/0`，真正的凭据是那个密钥。

`WONTON_OWNER_NAME`、`WONTON_OWNER_EMAIL` 没有用上：头认证只有共享密码，没有用户名字段，Actual 会建一个空名字的 owner。用户名装好以后不会变，但这里也不按用户名认人，账号就是那个固定的服务器密码。

## MCP

`mcp` 服务跑社区 [s-stefanov/actual-mcp](https://github.com/s-stefanov/actual-mcp)（MIT，Streamable HTTP），开写工具，所以 Bot 能记账。

上游问题由包里的 `mcp/patch-loader.mjs` 在 `--import` 时修正，补丁必须匹配固定镜像源码：

- 它把 `cloudFileId` 当同步 ID 交给 `downloadBudget`，而 API 按 `groupId` 匹配，服务器预算两列都有；改传 `groupId`。
- 读工具没有 `readOnlyHint`，总线会把查账也当敏感操作；给读工具补上，写工具保持确认。
- 上游暖连接按 60 秒 TTL 同步，且同步失败后继续读缓存。插件每次工具调用都核对真实远端账本的同步 ID 并同步；同步失败直接向调用者报错，不继续返回本地数据。已加载的账本被删除、换成另一本或重置同步 ID 时明确失败，需要在 Actual 选好账本后重启 MCP，不自动切换账本。

一个远端预算时直接用它，不把本地下载缓存计入账本数量。有多个预算时 MCP 不知道用哪个，会报错；把账本设置 Advanced 里的同步 ID 填进 mcp 服务的 `ACTUAL_BUDGET_SYNC_ID`（清单没有设置表单，要改 compose）。加密的预算没有处理。

Actual 和 init 使用主人的 UID/GID、只读根文件系统和 `/tmp` tmpfs；MCP 也以主人 UID/GID 运行，下载缓存只放在 `/data` tmpfs，容器重启后从服务器重建。MCP 在同一临时目录记录成功加载过的同步 ID，供独立健康检查区分首装零账本和已加载账本失效。健康检查验证头认证、远端选择、MCP 协议与 `get-accounts`，同步失败和身份变化都报错；只有从未加载过账本的零预算安装会跳过读取。临时登录与 MCP 会话在检查结束时关闭。

## 数据与备份

Actual 的账本、服务器文件和缓存都在 `/data`，宿主上是 `${WONTON_APP_DATA}`；卸载保留数据时一起保留，卸载并删数据时一起删。MCP 的 `/data` 是临时下载缓存，不写入这个持久化目录。

服务器自己不写备份文件，桌面版的自动备份也不覆盖网页。备份由主人在账本的 Settings → Export data 导出到当前设备；导出的 zip 里有 `db.sqlite` 和 `metadata.json`。

银行同步（GoCardless、SimpleFIN）要出网，所以申请了 `network.egress`。其余不需要共享文件夹、显卡和局域网端口。

## 开发与检查

```bash
WONTON_CORE_IMAGE=wonton-core:plugin-dev WONTON_PULL=never scripts/dev.sh up
scripts/dev.sh install
scripts/check.sh --official
```

`check.sh` 和安装用同一套解析和校验，通过时打印插件包摘要；`--official` 加官方索引的要求。`dev.sh reinstall` 装了再装一次工作区，数据留着。没有单元测试，改了就在开发环境里走一遍：自动登录、记一笔、重装后数据还在。合并前跑 `scripts/dev.sh smoke`，探测在 `scripts/smoke-probes.sh`。

## 来源与许可

- 应用：Actual Budget，MIT，<https://github.com/actualbudget/actual>。
- 图标：Actual Budget v26.11.0 的官方白色标志，未用图片模型生成；来源、版权、处理方式、上游 MIT 全文和商标说明见 [NOTICE](NOTICE)。
- MCP：s-stefanov/actual-mcp，MIT，<https://github.com/s-stefanov/actual-mcp>。
- 插件包自己的许可见 [LICENSE](LICENSE)。

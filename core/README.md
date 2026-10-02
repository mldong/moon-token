# moon-token

MoonBit 生态的**登录态 / 会话标准件**：DDD 分层、async-first 契约、零第三方运行时依赖
（只依赖官方 `moonbitlang/async`）。本包是**核心**——应用层用例、领域模型与裁决、路由守卫、
领域事件、token 生成风格。

存储契约与内存适配器在同家族的 [`mldong/moon-token-store`](https://mooncakes.io/docs/mldong/moon-token-store)
（本包已依赖它，通常不需要单独 `moon add`）。

```bash
moon update
moon add mldong/moon-token
moon add moonbitlang/async      # async 运行时；库本身不依赖它，但调用方要
```

## 它解决什么

| 能力 | 说明 |
|---|---|
| 双向映射 | `token → login_id` 正查 + `login_id → token 族` 反查；踢人/顶人/在线列表全靠反查 |
| 精确反馈 | 被踢 / 被顶 / 过期 / 闲置超时 / 无 token / 伪造 / refresh 重放——**七种原因各报各的**，绝不塌成"未登录" |
| 并发三态 | `Coexist`（默认共存）/ `Supersede`（顶人下线）/ `Shared`（同设备共用一枚） |
| 双层时效 | 签发时效 `timeout` + 活跃时效 `active_timeout`；"记住我"是长时效档 |
| 全量轮转 | `rotate` 换新整对，旧 access 与旧 refresh 同时失效；**不校验绑定 access 是否存活**（那是必现缺陷的来源） |
| 滑动续期 | `SlideOnAccess`（带 60s 节流窗）/ `IdleMark`（活跃标记） |
| 多账号体系 | `realm` 维度实例化，键位前缀隔离 |
| 可插拔存储 | async 仓储端口 + 意图补丁 `FamilyPatch`，换后端不改业务代码 |
| 守卫 DSL | 路径模式 + 豁免 + 追加断言，纯逻辑、不绑定任何 web 框架 |
| 领域事件 | 7 个事实事件，**落库后** fire，观察者异常不影响主流程 |
| 可注入时钟 | 时效类特性不需要真等；测试与演示都靠它 |

## 五分钟跑通

```moonbit
pub(all) struct DemoPerms {
  permissions : Array[String]
  roles : Array[String]
}

// 业务只负责"给数"，AND/OR 裁决在库里
pub impl @port.PermissionProvider for DemoPerms with fn get_permissions(
  self,
  _login_id,
  _device,
) {
  self.permissions
}

pub impl @port.PermissionProvider for DemoPerms with fn get_roles(self, _login_id, _device) {
  self.roles
}

pub extend DemoPerms with @port.PermissionProvider::{get_permissions, get_roles}

fn new_auth() -> @app.TokenAuth[@mem.MemoryStore, DemoPerms] {
  let p : DemoPerms = { permissions: ["user:info"], roles: ["user"] }
  @app.TokenAuth::new(
    "user",                          // realm：账号体系
    @app.TokenConfig::default(),     // 八项配置，默认值即推荐值
    @mem.MemoryStore::new("user"),   // 存储端口；换后端只改这一处
    p,
    @style.opaque_style(),           // token 生成；取不到平台熵即 abort
  )
}

async fn flow() -> (String, String) raise {
  let auth = new_auth()
  let result = auth.login("u1", device="pc")             // 一次签发 access + refresh 整对
  let login_id = auth.check_login(result.token)          // 通过给 login_id
  auth.kickout("u1", device="pc") |> ignore
  let reason = auth.check_login(result.token) catch {
    err => err.message()
  }
  (login_id, reason)
}

async test "被踢方拿到的是 KickedOut，不是笼统未登录" {
  let (login_id, reason) = flow()
  assert_eq(login_id, "u1")
  assert_eq(reason, "not login: KickedOut")
}
```

## 文档

用法、机制与取舍都在仓库的 `docs/` 下（mooncakes 只渲染本模块 README，所以链接给的是 GitHub 绝对地址）：

| 文档 | 讲什么 |
|---|---|
| [快速开始](https://github.com/mldong/moon-token/blob/master/docs/quick-start.md) | 装好、五分钟跑通一条完整链 |
| [核心概念](https://github.com/mldong/moon-token/blob/master/docs/concepts.md) | realm、整对 token、反查族、双层时效、五种键位 |
| [登录与并发策略](https://github.com/mldong/moon-token/blob/master/docs/login-and-concurrency.md) | 三态策略各自跑出来是什么样 |
| [会话与踢人](https://github.com/mldong/moon-token/blob/master/docs/session-management.md) | 在线列表、附加态、踢/顶/封禁/宽窗 |
| [刷新与轮转](https://github.com/mldong/moon-token/blob/master/docs/refresh-rotation.md) | 全量轮转语义、重放防护、为什么不校验 access 存活 |
| [权限与角色](https://github.com/mldong/moon-token/blob/master/docs/permissions.md) | SPI 供数、`has_*` 与 `check_*`、AND/OR |
| [路由守卫](https://github.com/mldong/moon-token/blob/master/docs/route-guard.md) | 模式匹配、豁免优先级、怎么挂到 HTTP 上 |
| [领域事件](https://github.com/mldong/moon-token/blob/master/docs/events.md) | 7 个事件、码值表、落库后 fire |
| [错误词汇表](https://github.com/mldong/moon-token/blob/master/docs/error-vocabulary.md) | 七种原因 + 五类错误，响应码映射建议 |
| [配置与默认值](https://github.com/mldong/moon-token/blob/master/docs/configuration.md) | 每个默认值为什么是这个数 |
| [时钟与熵源](https://github.com/mldong/moon-token/blob/master/docs/clock-and-entropy.md) | 注入时钟、三档熵源与 `abort` 守卫 |
| [存储端口](https://github.com/mldong/moon-token/blob/master/docs/storage-port.md) | 怎么写自己的后端 |
| [测试指南](https://github.com/mldong/moon-token/blob/master/docs/testing.md) | 三场景怎么落地、假绿长什么样 |
| [数据模型](https://github.com/mldong/moon-token/blob/master/docs/data-model.md) | 五类记录字段、关系、TTL 公式、Redis/SQL 物理映射、变更纪律 |
| [常见问题](https://github.com/mldong/moon-token/blob/master/docs/faq.md) | 集群、多 realm、与 JWT 的取舍、边界 |

可运行示例（含手写十行路由的 HTTP 门面与 13 步 curl 剧本）：
[`examples/cmd/main`](https://github.com/mldong/moon-token/tree/master/examples/cmd/main)。

## 边界（v1）

- **只交付内存存储**。进程重启状态清零；持久化后端（事务型、Lua 原子型）在下一轮。
- **熵源分档**：默认 `opaque_style()` 取平台熵，取不到即 `abort`，绝不静默回落到固定种子。
  `wasm-gc` 档无平台熵源，请改用 `opaque_style_with_seed` / `opaque_style_with`。
- 随机流是 core 提供的 **ChaCha8（8 轮变体）**，本项目不宣称其等同 ChaCha20 强度。
- 不做注解式鉴权（语言无注解）；不做 JWT；二级认证与框架中间件适配归下一轮。
- 存储层不落 token 哈希（键位属共享内核，v1 未开放该钩子）。

## 许可与模块

Apache-2.0。同家族两模块：`mldong/moon-token`（本包）+ `mldong/moon-token-store`（契约与内存适配器），
同版本号、按拓扑序发布。

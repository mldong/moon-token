# 快速开始

五分钟跑通一条完整链：装库 → 建实例 → 登录 → 鉴权 → 权限判定 → 踢人 → 拿到**精确原因**。
本页每个 `moonbit` 代码块都是被 `scripts/docs-check.sh` 真编译真跑过的，照着敲即可。

## 1. 装库

```bash
moon update
moon add mldong/moon-token
moon add moonbitlang/async      # async 运行时；库本身不依赖它，但你的调用方要
```

内存适配器在 `mldong/moon-token-store` 里，核心包已依赖它，通常不用单独 `moon add`。

要求 MoonBit 工具链为当前稳定版（`moon version --all` 查看）。本库在 `preferred_target = "wasm"`
下开发与测试；`native` 档由 CI 的 ubuntu job 裁决。

## 2. 权限供数：实现一个端口就完事

库不认识"权限"是什么，它只向你要数。业务侧实现 `PermissionProvider` 这一个 async trait：

```moonbit
pub(all) struct DemoPerms {
  permissions : Array[String]
  roles : Array[String]
}

pub impl @port.PermissionProvider for DemoPerms with fn get_permissions(
  self,
  _login_id,
  _device,
) {
  self.permissions
}

pub impl @port.PermissionProvider for DemoPerms with fn get_roles(
  self,
  _login_id,
  _device,
) {
  self.roles
}

pub extend DemoPerms with @port.PermissionProvider::{get_permissions, get_roles}
```

两个写法上的坑，先说省得你撞：

- **实现头不写 `async`**。trait 里声明的是 `async fn`，实现处只写 `fn`——`async` 由契约决定，
  写了编译器不认。
- **`pub extend ... with ...` 不是可选的**。没有它，`perms.get_permissions(...)` 这种点号调用会报
  `implicit_impl_as_method`；本仓的门禁口径是零警告，所以必须显式 extend。

## 3. 建实例：一个 realm 一个 `TokenAuth`

`realm` 是账号体系的隔离维度。`user` 体系里登录出来的 token，拿到 `admin` 体系的实例上是不认的。

```moonbit
fn make_auth() -> @app.TokenAuth[@mem.MemoryStore, DemoPerms] {
  let perms : DemoPerms = { permissions: ["user:info", "user:list"], roles: ["demo"] }
  @app.TokenAuth::new(
    "user",                          // realm
    @app.TokenConfig::default(),     // 十二项配置，默认值即推荐值，见 configuration.md
    @mem.MemoryStore::new("user"),   // 存储端口；换后端只改这一处
    perms,
    @style.opaque_style(),           // token 生成风格；取不到平台熵即 abort，见 clock-and-entropy.md
  )
}
```

## 4. 登录：一次拿一整对

```moonbit
async fn do_login(auth : @app.TokenAuth[@mem.MemoryStore, DemoPerms]) -> @app.LoginResult raise {
  auth.login("u1", device="pc", remember=false)
}
```

`login` 一次签发**一整对**，返回的 `LoginResult` 六个字段：

| 字段 | 含义 |
|---|---|
| `token` | access token，走 `Authorization` 头 |
| `refresh_token` | refresh token，客户端留着做轮转；服务端另存了一份与 access 的绑定 |
| `expire_at` | 绝对到期时刻（ms）。惰性过期＝读的时候才判，没有后台定时器 |
| `login_id` / `device` | 回显签发对象 |
| `reused` | `Shared` 策略下复用了既有 token 时为 `true`（此时未新签） |

`login_id` 是主键
，空串或纯空白会直接 `InvalidInput` 报错——**不会**拿空值当身份落库。
`device` 省略时归一到 `default`（空串/带空格都算同一个设备，避免"同一个人"被拆成两个设备）。

## 5. 鉴权：token 一律显式传参

```moonbit
async fn whoami(auth : @app.TokenAuth[@mem.MemoryStore, DemoPerms], token : String) -> String raise {
  auth.check_login(token)     // 通过就返回 login_id；不通过抛 TokenError，原因精确
}
```

到这里，一条链已经能跑：

```moonbit
async fn quick_start() -> String raise {
  let auth = make_auth()
  let result = do_login(auth)
  whoami(auth, result.token)
}

async test "快速开始整链真跑" {
  assert_eq(quick_start(), "u1")
}
```

## 6. 失败长什么样：七种原因各报各的

`check_login` 不返回 bool，而是**抛**，且抛出来的东西带得出原因：

```moonbit
async fn reason_of(auth : @app.TokenAuth[@mem.MemoryStore, DemoPerms], token : String) -> String {
  try {
    "放行 → " + auth.check_login(token)
  } catch {
    err => "拦下 → " + err.message()
  }
}

async fn show_reasons() -> Array[String] raise {
  let auth = make_auth()
  let token = auth.login("u1", device="pc").token
  let other = auth.login("u1", device="phone").token
  auth.kickout("u1", device="pc") |> ignore
  [
    reason_of(auth, ""),                       // AbsentToken：压根没带
    reason_of(auth, "not-a-real-token"),       // UnknownToken：查无此枚
    reason_of(auth, token),                    // KickedOut：被踢（墓碑还在，等宽窗回收）
    reason_of(auth, other),                    // 放行：同账号另一台设备不受影响
  ]
}

async test "四种输入四种原因，互不塌缩" {
  let reasons = show_reasons()
  assert_true(reasons[0].contains("AbsentToken"))
  assert_true(reasons[1].contains("UnknownToken"))
  assert_true(reasons[2].contains("KickedOut"))
  assert_eq(reasons[3], "放行 → u1")
}
```

这四条就是本库存在的理由：**"被踢"和"过期"和"没登录"绝不塌成同一句"未登录"**。
前端只有拿到区分得开的原因，才谈得上给用户正确的提示、以及该不该跳登录页。
完整原因表见 [error-vocabulary.md](error-vocabulary.md)。

## 7. 权限判定：给数是业务的事，裁决是库的事

```moonbit
async fn check_perms() -> (Bool, Bool) raise {
  let auth = make_auth()
  let token = auth.login("u1", device="pc").token
  (
    auth.has_permission(token, ["user:info", "user:list"]),
    auth.has_permission(token, ["user:info", "order:read"]),
  )
}

async test "AND 缺一件就不放行" {
  let (both, missing) = check_perms()
  assert_true(both)
  assert_false(missing)
}
```

`has_*` 返回 bool、`check_*` 直接抛，两套并行：写断言用前者，写守卫的追加检查用后者。
`mode=@port.Or` 改成"命中其一即可"。

## 8. 下一步

- 想把它挂到 HTTP 上：[路由守卫](route-guard.md)（`examples/cmd/main` 有手写十行路由的完整样本）
- 想知道每个默认值为什么是这个数：[配置与默认值](configuration.md)
- 想换 Redis/SQL 后端：[存储端口](storage-port.md)
- 时效类特性（过期、活跃超时、踢人宽窗）没法真等：[时钟与熵源](clock-and-entropy.md)

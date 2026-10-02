# moonback 集成（moon-token-moonback）

把 moon-token 的"认证 + 路由权限策略"接到 [moonback](https://mooncakes.io/docs/moonbitlang/moonback)
的路由上：一次受保护请求只做**一次** `T:` 读，主体（登录号 + 权限集 + 角色 + 超管位）
放进请求上下文，handler 只管取数。

依赖方向是 `moonback 模块 → core + store`：core 不认识 moonback，端口也没为它改过一行，
所以适配层单独成模块 `mldong/moon-token-moonback`，`core`/`store`/`store-file` 保持零 web 依赖。

本页代码块由 `scripts/docs-check.sh` 逐块真编译真跑。

## 1. 三条硬前置（先读，这三条都是实测踩出来的）

**① `TokenAuth` 不能在顶层 `let` 里构造。** wasm 档的顶层 `let` 在 `__moonbit_init` 阶段求值，
那时平台熵还没装好，`@style.opaque_style()` 会当场 abort，栈是
`__moonbit_init → style.opaque_style → require_platform_entropy`。
守卫本身是对的（它把"静默用固定种子发 token"变成启动即响亮失败），但文案不会告诉你"是时机太早"。
moonback README 的 `let app = @moonback.App(...)` 顶层风格正是往这个坑里带的那只手——
**所有构造都放进 `main` 或工厂函数**。详见 [时钟与熵](clock-and-entropy.md)。

**② 本机只跑 wasm，native 交 CI。** moonback 的 `preferred_target` 写的是 native，
但 async 的 C 运行时在 MinGW 下三处 `#error "Currently only MSVC is supported on Windows"`，
本机 `moon build --target native` 出不了包；wasm 档 `moonrun` 能起真服务
（实测 25 格 HTTP 矩阵全通）。所以本工程一律 `--target wasm`。

**③ cookie 只是 token 的第四个来源，不是一条独立通路。** 裁决永远走 `TokenStore`。
把"cookie 模式"做成不过存储的通路，等于交付一个"改掉 cookie 字符串就能冒充任何人"的对照组。
重启后会不会丢由**存储**决定，与载体无关：内存版重启即丢、换 `store-file` 后同一枚 cookie
自然跨重启存活，用户代码一行不用改。

## 2. 装起来

```text
moon add mldong/moon-token mldong/moon-token-store mldong/moon-token-moonback
moon add moonbitlang/moonback moonbitlang/async
```

`moon.pkg` 里的别名（本仓文档用的就是这套）：

```text
"mldong/moon-token/app" @app
"mldong/moon-token/guard" @guard          // 路由策略在这里（core 的）
"mldong/moon-token/style" @style
"mldong/moon-token-store/port" @port
"mldong/moon-token-store/memory" @mem
"mldong/moon-token-moonback/guard" @mbguard   // 适配层
"moonbitlang/moonback" @mb
"moonbitlang/async"
```

`@guard` 与 `@mbguard` 都叫 guard 不是巧合：前者是**策略与判决**（框架无关），
后者是**把判决接到 moonback 的 `Request`/`Responder` 上**。名字撞车说明它们本来就在同一层。

## 3. 业务只供数，裁决在库里

三个方法就是 [权限端口](permissions.md) 的全部：`get_permissions` / `get_roles` / `is_super_admin`。
库拿到数之后按路由策略裁决，**每会话至多问一次**（第二次起读 `P:` 授权快照）。

```moonbit
struct DocPerms {}

///|
pub impl @port.PermissionProvider for DocPerms with fn get_permissions(
  _self,
  login_id,
  _device,
) {
  if login_id == "demo-user" { ["api:user:info", "sys:user:save"] } else { [] }
}

///|
pub impl @port.PermissionProvider for DocPerms with fn get_roles(
  _self,
  login_id,
  _device,
) {
  if login_id == "boss" { ["admin"] } else { ["user"] }
}

///|
pub impl @port.PermissionProvider for DocPerms with fn is_super_admin(
  _self,
  login_id,
  _device,
) {
  login_id == "boss"
}

pub extend DocPerms with @port.PermissionProvider::{
  get_permissions,
  get_roles,
  is_super_admin,
}
```

## 4. 守卫：一个 realm 一套

保护面三档同时给全——豁免、例外清单、其余走推导（推导规则见 [路由权限策略](route-policy.md)）。

```moonbit
fn doc_policy() -> @guard.RoutePolicy {
  (@guard.RoutePolicy::new())
    .exempt("/login")
    .exempt("/public/**")
    .rule(@guard.RouteRule::make("/sys/user/save", ["sys:user:save"]))
    .rule(@guard.RouteRule::make("/admin/panel", []).with_roles(["admin"], @port.And))
}

///|
/// 构造点放在函数里，不是顶层 let（§1 第 ① 条）。
fn doc_auth(realm : String) -> @app.TokenAuth[@mem.MemoryStore, DocPerms] {
  @app.TokenAuth::new(
    realm,
    @app.TokenConfig::default(),
    @mem.MemoryStore::new(realm),
    DocPerms::{},
    @style.opaque_style(),
  )
}

///|
fn doc_guard(realm : String) -> @mbguard.Guard[@mem.MemoryStore, DocPerms] {
  @mbguard.Guard::new(doc_auth(realm), doc_policy())
}
```

## 5. 逐路由包装，不是 App 级中间件

`secure(handler)` 是默认姿势。理由实测过：moonback 的 `add_middleware` 是 **App 全局作用域**，
而且**先于路由匹配**执行——404 与方法不匹配的路径也会先过一遍鉴权，
在中间件里按路径查权限表等于自己重做一遍路由匹配。

`middleware()` 也给了（整个模块都要受保护时用它）；策略表按 path 决策，挂全局不会漏判，
只是 404 也吃一次鉴权开销。

```moonbit
///|
/// handler 只干一件事：从上下文取主体。不解析 token、不查库。
/// 守卫拦下时根本走不到 handler，所以这里的 `None` 只剩"这条路由命中豁免面"一种含义。
let doc_info : @mb.Handler = async fn(request, responder) {
  let body = match @mbguard.principal_of(request) {
    None => "{\"code\":99999999,\"msg\":\"豁免面没有主体\",\"data\":null}"
    Some(p) => {
      let perms = p.permissions.join(",")
      "{\"code\":0,\"msg\":\"ok\",\"data\":{\"login_id\":\"\{p.login_id}\"" +
        ",\"super_admin\":\{p.super_admin.to_string()},\"permissions\":\"\{perms}\"}}"
    }
  }
  responder.send_text(body, headers=[("Content-Type", "application/json")])
}

///|
let doc_ping : @mb.Handler = async fn(_request, responder) {
  responder.send_text("public")
}

///|
async fn doc_wire(realm : String) -> @mb.App {
  let g = doc_guard(realm)
  let root = @mb.Module((ctx) => {
    ctx.get("/public/ping", doc_ping) catch {
      _ => fail("/public/ping 注册失败")
    }
    g.get(ctx, "/api/user/info", doc_info) catch {
      _ => fail("/api/user/info 注册失败")
    }
    g.get(ctx, "/sys/user/save", doc_info) catch {
      _ => fail("/sys/user/save 注册失败")
    }
    g.get(ctx, "/admin/panel", doc_info) catch {
      _ => fail("/admin/panel 注册失败")
    }
  })
  @mb.App(root)
}
```

`principal_of` 给 `None` 的两种含义只有一种是真的：这条路由**没挂守卫**或它是豁免路由。
"未登录"到不了 handler——守卫已经按状态码回了。

## 6. 失败响应：库只给状态码，code 表归业务

默认映射只有这张表，不发明业务错误码：

```moonbit
test "MB-D1 状态码映射：401 身份不成立、403 无权/被禁用、400 入参、500 存储" {
  assert_eq(@mbguard.status_of(@port.NotLogin(@port.AbsentToken)), 401)
  assert_eq(@mbguard.status_of(@port.NotLogin(@port.UnknownToken)), 401)
  assert_eq(@mbguard.status_of(@port.NotPermission("sys:user:save")), 403)
  assert_eq(@mbguard.status_of(@port.NotRole("admin")), 403)
  assert_eq(@mbguard.status_of(@port.Disabled("u1", 0L)), 403)
  assert_eq(@mbguard.status_of(@port.InvalidInput("realm 不能为空")), 400)
  assert_eq(@mbguard.status_of(@port.Store("redis 连不上")), 500)
}
```

`401` 与 `403` 必须分得开：前端据此决定是跳登录页还是报"你没这个权限"。
要换成自己那套信封（`code=99990403` 之类），传一个 `on_error` 进去就完，**别改库**：

```moonbit
///|
/// 状态码仍按库那张表给，只是 body 换成框架信封。
async fn doc_envelope(
  _request : @mb.Request,
  responder : @mb.Responder,
  err : @port.TokenError,
) -> Unit {
  let code = match err {
    @port.NotLogin(_) => 99990401
    @port.NotPermission(_) => 99990403
    @port.NotRole(_) => 99990403
    @port.Disabled(_, _) => 99990403
    @port.InvalidInput(_) => 99990400
    @port.Store(_) => 99999999
  }
  responder.send_text(
    "{\"code\":\{code.to_string()},\"msg\":\"\{err.message()}\",\"data\":null}",
    status=@mbguard.status_of(err),
  )
}

///|
fn doc_envelope_guard(
  g : @mbguard.Guard[@mem.MemoryStore, DocPerms],
) -> @mbguard.Guard[@mem.MemoryStore, DocPerms] {
  g.with_on_error(doc_envelope)
}
```

## 6.1 框架契约要 HTTP 恒 200 时（`CommonResult` 那一档）

mldong 系各栈的出口契约不是 REST 状态码：**HTTP 恒 200，成败在 body 的 `code` 里**
（Java 侧 `GlobalExceptionHandler` 挂 `@ResponseStatus(HttpStatus.OK)`，前端按 `code` 分诊）。
这一档**不需要改库**：`with_on_error` 拿到的是整个 `Responder`，状态码由框架壳自己给。

```moonbit
///|
/// 档 B：恒 200 + 信封。码表归框架壳（库不内置任何项目的 code），这里只给形状。
fn doc_code_200(err : @port.TokenError) -> Int {
  match err {
    @port.NotLogin(_) => 99990403
    @port.Disabled(_, _) => 10041003
    @port.NotPermission(_) => 99990406
    @port.NotRole(_) => 99990406
    @port.InvalidInput(_) => 99999999
    @port.Store(_) => 99999999
  }
}

///|
async fn doc_on_error_200(
  _request : @mb.Request,
  responder : @mb.Responder,
  err : @port.TokenError,
) -> Unit {
  responder.send_text(
    "{\"code\":\{doc_code_200(err).to_string()},\"msg\":\"\{err.message()}\",\"data\":null}",
    status=200,
  )
}
```

```moonbit
async test "MB-D5 恒 200 那一档：只换响应写法，判决与精确原因都不塌" {
  // 码表通常比原因的档位粗（Java 那侧把七档未登录全塌进 TOKEN_NOT_EXIST 一个码）：
  // 这不丢东西，前提是精确原因留在 msg 里，别让"被踢"和"没带 token"在出口变成同一个事实
  assert_eq(doc_code_200(@port.NotLogin(@port.KickedOut)), 99990403)
  assert_eq(doc_code_200(@port.NotLogin(@port.AbsentToken)), 99990403)
  assert_eq(doc_code_200(@port.NotRole("admin")), 99990406)
  assert_eq((@port.NotLogin(@port.KickedOut)).message(), "not login: KickedOut")
  assert_eq((@port.NotLogin(@port.AbsentToken)).message(), "not login: AbsentToken")
  // 档位切换一个字没动判决：够权限那条照样有主体
  let g = doc_guard("doc-200").with_on_error(doc_on_error_200)
  let token = g.auth.login("demo-user", device="pc").token
  assert_true(@mbguard.decide(g.auth, g.policy, doc_req("/sys/user/save", Some(token))) is Some(_))
}
```

真服务器上的读数（一次性探针工程，装的是注册表 0.1.8 四件，wasm 档 moonrun 起服务）：

| 请求 | 状态码 | body |
|---|---|---|
| `POST /login` | 200 | `{"code":0,"msg":"ok","data":"<token>"}` |
| 无凭证 `GET /api/user/info` | **200** | `{"code":99990403,"msg":"not login: AbsentToken","data":null}` |
| 假 token | **200** | `{"code":99990403,"msg":"not login: UnknownToken","data":null}` |
| 缺权限码 `GET /sys/user/remove` | **200** | `{"code":99990406,"msg":"no permission: sys:user:remove","data":null}` |
| 缺角色 `GET /admin/panel` | **200** | `{"code":99990406,"msg":"no role: admin","data":null}` |
| 超管 `GET /admin/panel` | 200 | `{"code":0,"msg":"ok","data":"hello boss"}` |
| 同名 cookie 腿 | 200 | `{"code":0,"msg":"ok","data":"hello demo-user"}` |

两档选哪档都不影响判决面，`scripts/mw-smoke.sh` 那 17 格测的是**默认档**（真状态码，REST 消费方）；
框架壳要是走恒 200，判据就该换成"逐格断 body 的 `code`"，别两边都只断"非 200"或"code≠0"。

## 7. 判据：豁免面没有主体、只问业务一轮

`decide` 是判决本体，只吃"取路径 / 取头"两个闭包——写集成测试时不用真起服务器
（moonback 的 `Context::new` 与 `ConnectionInfo` 都不公开，包外造不出 `Request`）。

```moonbit
fn doc_req(path : String, token : String?) -> @guard.RequestFns {
  { path: fn() { path }, header: fn(_) { token } }
}

///|
async test "MB-D2 豁免放行但没主体 / 无凭证 401 精确到档 / 够权限给主体" {
  let auth = doc_auth("doc-judge")
  let pol = doc_policy()
  // ① 豁免面：连 token 都不看，放行但没有主体
  assert_true(@mbguard.decide(auth, pol, doc_req("/public/ping", None)) is None)
  // ② 负向：身份不成立，精确到 AbsentToken（不是笼统"未登录"）
  let loud = try {
    let _ = @mbguard.decide(auth, pol, doc_req("/sys/user/save", None))
    "没抛"
  } catch {
    err => err.message()
  }
  assert_eq(loud, "not login: AbsentToken")
  // ③ 正向 + 回归：登录后过例外清单；第二趟仍读同一份快照
  let token = auth.login("demo-user", device="pc").token
  match @mbguard.decide(auth, pol, doc_req("/sys/user/save", Some(token))) {
    None => fail("够权限应有主体")
    Some(p) => assert_eq(p.login_id, "demo-user")
  }
  assert_true(
    @mbguard.decide(auth, pol, doc_req("/sys/user/save", Some(token))) is Some(_),
  )
  // 角色面：demo-user 有权限但没有 admin
  let refused = try {
    let _ = @mbguard.decide(auth, pol, doc_req("/admin/panel", Some(token)))
    "没抛"
  } catch {
    err => err.message()
  }
  assert_eq(refused, "no role: admin")
}

///|
async test "MB-D3 接线件真跑：路由注册不冲突、换信封不动判决" {
  let app = doc_wire("doc-app")
  // App 起来只是把路由表建好（不 listen），拿到实例就说明四条路由都没撞
  app.close()
  let g = doc_envelope_guard(doc_guard("doc-env"))
  assert_eq(g.policy.rule_count(), 2, msg="例外清单两条：/sys/user/save 与 /admin/panel")
  assert_true(g.policy.resolve("/public/ping") is @guard.Public)
  assert_true(g.policy.resolve("/api/user/info") is @guard.Guarded(_))
}
```

## 8. 换后端只动构造点

`Guard` 对存储类型只要求实现 [存储端口](storage-port.md)。会话要跨重启存活，就把
`@mem.MemoryStore::new` 换成 `@file.FileStore::open`（[文件后端](file-store.md)），
moonback 那一侧一行都不用改：

```moonbit
async fn doc_file_guard(
  dir : String,
) -> @mbguard.Guard[@file.FileStore, DocPerms] {
  let auth = @app.TokenAuth::new(
    "user",
    @app.TokenConfig::default(),
    @file.FileStore::open("user", dir),
    DocPerms::{},
    @style.opaque_style(),
  )
  @mbguard.Guard::new(auth, doc_policy())
}

///|
async test "MB-D4 文件后端接上守卫：判决照旧，重启不丢" {
  let dir = @fs.tmpdir(prefix="mt-doc-mb.")
  let g = doc_file_guard(dir)
  let token = g.auth.login("demo-user", device="pc").token
  let first = @mbguard.decide(g.auth, g.policy, doc_req("/sys/user/save", Some(token)))
  assert_true(first is Some(_))
  // 换一个实例重开同一目录：会话还在，判决也还在（这一条正是文件后端的存在理由）
  let again = doc_file_guard(dir)
  let reopened = try {
    let second = @mbguard.decide(again.auth, again.policy, doc_req("/sys/user/save", Some(token)))
    second is Some(_)
  } catch {
    err => fail("重开后判决变了：" + err.message())
  }
  assert_true(reopened)
  @fs.rmdir(dir, recursive=true)
}
```

## 9. 真跑的那条腿在哪

`moon test` 判的是判决逻辑（`moonback/guard/guard_test.mbt`，MB1–MB9 + MB10）。
"`Request` → 两个闭包"这一小段、加状态码真落到响应上，只能靠真服务器：

```text
moon run --target wasm examples/cmd/moonback-demo   # 127.0.0.1:18891
bash scripts/mw-smoke.sh                   # 逐格断状态码 + 精确原因
```

矩阵覆盖：豁免 / 无凭证 401 / 伪造 token 401 / 头腿 / cookie 腿 / 推导面正反 /
例外清单 / 多码 OR / 只挂角色 / 超管跳过裁决 / 404 不背锅 / 注销后失效 / 回归。

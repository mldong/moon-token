# moon-token-moonback

[moonback](https://mooncakes.io/docs/moonbitlang/moonback) 适配层：把
[`mldong/moon-token`](https://mooncakes.io/docs/mldong/moon-token) 的认证与路由权限策略
接到 moonback 的路由上。一次受保护请求只做**一次**会话读，主体（登录号 + 权限集 + 角色 + 超管位）
放进请求上下文，handler 只管取数。

零 web 依赖的部分仍在 `mldong/moon-token`：这一层单独成模块，
所以 core / store / store-file 都不因为"要接某个框架"而长出第二套语义。

## 装起来

```text
moon add mldong/moon-token mldong/moon-token-store mldong/moon-token-moonback
moon add moonbitlang/moonback moonbitlang/async
```

## 三条要知道的

- **`TokenAuth` 别写成顶层 `let`。** wasm 档的顶层 `let` 在 `__moonbit_init` 阶段求值，
  那时平台熵还没装好，`@style.opaque_style()` 会当场 abort。放进 `main` 或工厂函数。
- **逐路由包装优先。** moonback 的 `add_middleware` 是 App 全局作用域且先于路由匹配执行，
  404 也会先过一次鉴权；`secure(handler)` / `get` / `post` 才是默认姿势，
  `middleware()` 留给"整个模块都要受保护"。
- **cookie 只是 token 的第四个来源。** 头里没有才按同名 cookie 取，裁决永远走 `TokenStore`。
  会话重启后会不会丢由**存储**决定（内存版会丢、`mldong/moon-token-store-file` 不丢），与载体无关。

## 最小接线

```moonbit
struct MbPerms {}

///|
pub impl @port.PermissionProvider for MbPerms with fn get_permissions(
  _self,
  login_id,
  _device,
) {
  if login_id == "admin" { ["sys:user:save"] } else { [] }
}

///|
pub impl @port.PermissionProvider for MbPerms with fn get_roles(
  _self,
  _login_id,
  _device,
) {
  ["user"]
}

///|
pub impl @port.PermissionProvider for MbPerms with fn is_super_admin(
  _self,
  _login_id,
  _device,
) {
  false
}

pub extend MbPerms with @port.PermissionProvider::{
  get_permissions,
  get_roles,
  is_super_admin,
}

///|
fn mb_auth(realm : String) -> @app.TokenAuth[@mem.MemoryStore, MbPerms] {
  @app.TokenAuth::new(
    realm,
    @app.TokenConfig::default(),
    @mem.MemoryStore::new(realm),
    MbPerms::{},
    @style.opaque_style(),
  )
}

///|
let mb_save : @mb.Handler = async fn(request, responder) {
  let who = match @mbguard.principal_of(request) {
    None => "（豁免路由没有主体）"
    Some(p) => p.login_id
  }
  responder.send_text("saved by " + who)
}

///|
let mb_ping : @mb.Handler = async fn(_request, responder) {
  responder.send_text("public")
}

///|
async fn mb_wiring(realm : String) -> Unit {
  let auth = mb_auth(realm)
  let policy = (@guard.RoutePolicy::new()).exempt("/public/**").rule(
    @guard.RouteRule::make("/sys/user/save", ["sys:user:save"]),
  )
  let g = @mbguard.Guard::new(auth, policy)
  let root = @mb.Module((ctx) => {
    ctx.get("/public/ping", mb_ping) catch {
      _ => fail("/public/ping 注册失败")
    }
    g.get(ctx, "/sys/user/save", mb_save) catch {
      _ => fail("/sys/user/save 注册失败")
    }
  })
  let app = @mb.App(root)
  // 这里只建路由表，不 listen：真起服务器见 `examples/cmd/moonback-demo`
  app.close()
  let token = auth.login("admin", device="pc").token
  let fns : @guard.RequestFns = {
    path: fn() { "/sys/user/save" },
    header: fn(_) { Some(token) },
  }
  match @mbguard.decide(auth, policy, fns) {
    None => fail("够权限应有主体")
    Some(p) => assert_eq(p.login_id, "admin")
  }
  // 没带凭证的那一趟必须精确报 AbsentToken，状态码 401
  let absent : @guard.RequestFns = {
    path: fn() { "/sys/user/save" },
    header: fn(_) { None },
  }
  let why = try {
    let _ = @mbguard.decide(auth, policy, absent)
    "没抛"
  } catch {
    err => err.message()
  }
  assert_eq(why, "not login: AbsentToken")
  assert_eq(@mbguard.status_of(@port.NotLogin(@port.AbsentToken)), 401)
}

///|
async test "README 这条链真跑：建路由表 + 判决 + 状态码" {
  mb_wiring("readme-mb")
}
```

## 失败响应

默认只映射状态码（`401` 身份不成立 / `403` 权限、角色、被禁用 / `400` 入参 / `500` 存储故障），
**不发明业务错误码**——code 表由业务在自己的全局异常处理里转。要换信封就传 `with_on_error`。

## 看更多

`mldong/moon-token` 的文档站讲端口、数据模型与路由策略；这一层的判决逻辑在
`moonback/guard/guard_test.mbt`（MB1–MB9），"`Request` → 两个闭包"那一段由
`examples/cmd/moonback-demo` + `scripts/mw-smoke.sh` 在真服务器上逐格断状态码。
源码仓：<https://github.com/mldong/moon-token>。

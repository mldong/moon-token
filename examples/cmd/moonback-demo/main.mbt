///|
/// moonback + moon-token 的可运行示例服务（不发布）：守卫挂在真路由上，一条 curl 矩阵就能走完。
///
/// 起法：moon run --target wasm examples/cmd/moonback-demo      （默认 127.0.0.1:18891）
/// 验证：bash scripts/mw-smoke.sh
///
/// **`TokenAuth` 必须在 `main` 里构造，不能写成顶层 `let`**：wasm 档的顶层 `let` 在
/// `__moonbit_init` 阶段求值，那时平台熵还没装好，`opaque_style()` 会当场 abort
/// （实测记在 hub 的 moonback 复测报告 §12）。moonback README 的 `let app = @moonback.App(...)`
/// 顶层风格正是把人往这个坑里带的那只手。

///|
/// 权限供数方：库里没有业务语义，只有"业务给数 + 库裁决"两步。
/// 三个账号三种形状，冒烟矩阵要用的三档都在这里给出来。
struct DemoPerms {}

///|
pub impl @port.PermissionProvider for DemoPerms with fn get_permissions(
  _self,
  login_id,
  _device,
) {
  // 超管故意给空权限：他要靠 `is_super_admin` 那一档过，不是靠码表
  if login_id == "demo-user" { ["api:user:info", "sys:user:save"] } else { [] }
}

///|
pub impl @port.PermissionProvider for DemoPerms with fn get_roles(
  _self,
  login_id,
  _device,
) {
  if login_id == "boss" { ["admin"] } else { ["user"] }
}

///|
pub impl @port.PermissionProvider for DemoPerms with fn is_super_admin(
  _self,
  login_id,
  _device,
) {
  login_id == "boss"
}

pub extend DemoPerms with @port.PermissionProvider::{
  get_permissions,
  get_roles,
  is_super_admin,
}

///|
/// 与 mldong 框架契约同形的极简信封：code=0 成功，99999999 失败，msg 带精确原因。
/// 真实项目里这层由业务自己的全局异常处理写，适配层只给状态码、不替项目定 code 表。
fn envelope(code : Int, msg : String, data : String) -> String {
  "{\"code\":\{code.to_string()},\"msg\":\"\{msg}\",\"data\":\{data}}"
}

///|
async fn reply(responder : @mb.Responder, body : String) -> Unit {
  let writer = responder.respond(
    headers=[("Content-Type", "application/json; charset=utf-8")],
  )
  writer.write(body)
}

///|
/// 同一枚 token 既交给 `Authorization` 头也塞进 cookie：两条腿过的是同一次裁决，
/// 因为 cookie 只是载体，判活判权限的一直是 store。
async fn reply_token(responder : @mb.Responder, token : String) -> Unit {
  let headers : Array[(String, String)] = [
    ("Content-Type", "application/json; charset=utf-8"),
    ("Set-Cookie", "Authorization=\{token}; Path=/; HttpOnly; SameSite=Lax"),
  ]
  let writer = responder.respond(headers=@mb.Headers::from(headers))
  writer.write(
    envelope(0, "ok", "{\"token\":\"\{token}\",\"refresh_token\":\"\{token}-r\"}"),
  )
}

///|
/// 三档保护面一次给全：豁免面（`/login` `/logout` `/public/**`）、例外清单（三条规则）、
/// 其余走推导（`/api/user/info` ⇒ `api:user:info`）。
fn policy() -> @core_guard.RoutePolicy {
  (@core_guard.RoutePolicy::new())
    .exempt("/login")
    .exempt("/logout")
    .exempt("/public/**")
    .rule(@core_guard.RouteRule::make("/sys/user/save", ["sys:user:save"]))
    .rule(@core_guard.RouteRule::make("/multi", ["a:b", "c:d"]).with_perm_mode(@port.Or))
    .rule(
      @core_guard.RouteRule::make("/admin/panel", []).with_roles(["admin"], @port.And),
    )
}

///|
/// 只给注销 handler 用：它挂在豁免面上（本来就没登录也要能调），所以自己取 token。
/// 同一条"头优先、cookie 兜底"的顺序由适配层守着，这里照抄一遍即可，不另起规则。
fn token_of(request : @mb.Request) -> String {
  let from_header = match request.headers.get("Authorization") {
    None => ""
    Some(v) => v.to_owned()
  }
  if from_header.is_empty() {
    match request.cookie().get("Authorization") {
      None => ""
      Some(v) => v
    }
  } else {
    from_header
  }
}

///|
async fn main {
  let auth = @app.TokenAuth::new(
    "user",
    @app.TokenConfig::default(),
    @mem.MemoryStore::new("user"),
    DemoPerms::{},
    @style.opaque_style(),
  )
  let g = @mbguard.Guard::new(auth, policy())

  let login : @mb.Handler = async fn(request, responder) {
    let who = match request.query().get("as") {
      None => "demo-user"
      Some(v) => v
    }
    let result = auth.login(who, device="pc") catch {
      err => {
        reply(responder, envelope(99999999, err.message(), "null"))
        return
      }
    }
    reply_token(responder, result.token)
  }
  let logout : @mb.Handler = async fn(request, responder) {
    auth.logout(token_of(request)) catch {
      err => {
        reply(responder, envelope(99999999, err.message(), "null"))
        return
      }
    }
    reply(responder, envelope(0, "ok", "\"已注销\""))
  }
  let ping : @mb.Handler = async fn(_request, responder) {
    reply(responder, envelope(0, "ok", "\"public pass\""))
  }
  // 受保护的 handler 只干一件事：从上下文取主体。不解析 token、不查库
  let info : @mb.Handler = async fn(request, responder) {
    match @mbguard.principal_of(request) {
      None => reply(responder, envelope(99999999, "守卫没给主体", "null"))
      Some(p) => {
        let data = "{\"login_id\":\"\{p.login_id}\",\"super_admin\":\{p.super_admin.to_string()}" +
          ",\"permissions\":\"\{p.permissions.join(",")}\"}"
        reply(responder, envelope(0, "ok", data))
      }
    }
  }
  let saved : @mb.Handler = async fn(request, responder) {
    let who = match @mbguard.principal_of(request) {
      None => "-"
      Some(p) => p.login_id
    }
    reply(responder, envelope(0, "ok", "\"saved by " + who + "\""))
  }

  let root = @mb.Module((ctx) => {
    // 豁免面用原 handler 直挂（守卫对它们是看一眼就放行）；其余一律 g.get/g.post
    ctx.post("/login", login) catch {
      _ => fail("/login 注册失败")
    }
    ctx.get("/public/ping", ping) catch {
      _ => fail("/public/ping 注册失败")
    }
    g.post(ctx, "/logout", logout) catch {
      _ => fail("/logout 注册失败")
    }
    g.get(ctx, "/api/user/info", info) catch {
      _ => fail("/api/user/info 注册失败")
    }
    g.get(ctx, "/sys/user/save", saved) catch {
      _ => fail("/sys/user/save 注册失败")
    }
    // 这条没进权限集：推导给出 api:user:remove ⇒ 该 403，用来证"推导面真的在裁"
    g.get(ctx, "/api/user/remove", saved) catch {
      _ => fail("/api/user/remove 注册失败")
    }
    g.get(ctx, "/multi", saved) catch {
      _ => fail("/multi 注册失败")
    }
    g.get(ctx, "/admin/panel", saved) catch {
      _ => fail("/admin/panel 注册失败")
    }
  })

  let app = @mb.App(root)
  defer app.close()
  let server = @mb.listen(host="127.0.0.1", port=18891)
  println("moon-token × moonback demo listening on 127.0.0.1:18891")
  println("  冒烟：bash scripts/mw-smoke.sh")
  app.serve(server)
}

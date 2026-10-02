///|
/// moon-token 的可运行示例服务（不发布）：一个最小 HTTP 门面，把库的用例逐条露出来。
/// 起法：moon run --target wasm examples/cmd/main     （默认 127.0.0.1:18890）
/// 验证：bash examples/curl.sh
///
/// 这个文件刻意只依赖库的公开 API：`DemoPerms` 是权限端口的一个普通实现方，
/// 信封与路由都是手写十行，不引任何 web 框架——库本身零 web 依赖。

///|
/// 权限/角色供数：业务侧只给数，AND/OR 裁决在库里
pub(all) struct DemoPerms {
  permissions : Array[String]
  roles : Array[String]
}

///|
pub impl @port.PermissionProvider for DemoPerms with fn get_permissions(
  self,
  _login_id,
  _device,
) {
  self.permissions
}

///|
pub impl @port.PermissionProvider for DemoPerms with fn get_roles(
  self,
  _login_id,
  _device,
) {
  self.roles
}

pub extend DemoPerms with @port.PermissionProvider::{get_permissions, get_roles}

///|
/// 与 mldong 框架契约同形的极简信封：code=0 成功，99999999 失败，msg 带精确原因
fn envelope(code : Int, msg : String, data : String) -> String {
  "{\"code\":\{code.to_string()},\"msg\":\"\{msg}\",\"data\":\{data}}"
}

fn text(s : String) -> String {
  "\"" + s + "\""
}

fn method_of(req : @http.Request) -> String {
  match req.meth {
    Get => "GET"
    Post => "POST"
    Delete => "DELETE"
    _ => "OTHER"
  }
}

fn header_value(req : @http.Request, name : String) -> String? {
  match req.headers.get(name) {
    None => None
    Some(v) => if v.is_empty() { None } else { Some(v) }
  }
}

fn header_or_empty(req : @http.Request, name : String) -> String {
  match header_value(req, name) {
    None => ""
    Some(v) => v
  }
}

///|
async fn reply(conn : @http.ServerConnection, payload : String) -> Unit {
  conn.send_response(200, "application/json; charset=utf-8")
  conn.write_string(payload)
  conn.end_response()
}

///|
/// 签发整对：access 走 Authorization 头回传，refresh 交给调用方存着做轮转
async fn do_login(
  auth : @app.TokenAuth[@mem.MemoryStore, DemoPerms],
  device : String,
  conn : @http.ServerConnection,
) -> Unit {
  let result = auth.login("demo-user", device=device) catch {
    err => {
      reply(conn, envelope(99999999, err.message(), "null"))
      return
    }
  }
  reply(
    conn,
    "{\"code\":0,\"msg\":\"ok\",\"data\":{\"token\":\"" + result.token +
      "\",\"refresh_token\":\"" + result.refresh_token + "\"}}",
  )
}

///|
/// 全量轮转：旧 access 与旧 refresh 同时作废，重放第二次必被拒
async fn do_rotate(
  auth : @app.TokenAuth[@mem.MemoryStore, DemoPerms],
  req : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  let refresh = header_or_empty(req, "x-refresh-token")
  let result = auth.rotate(refresh) catch {
    err => {
      reply(conn, envelope(99999999, err.message(), "null"))
      return
    }
  }
  reply(
    conn,
    "{\"code\":0,\"msg\":\"ok\",\"data\":{\"token\":\"" + result.token +
      "\",\"refresh_token\":\"" + result.refresh_token + "\"}}",
  )
}

///|
async fn handle(
  auth : @app.TokenAuth[@mem.MemoryStore, DemoPerms],
  route_guard : @guard.RouteGuard,
  req : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  let path = req.path
  let meth = method_of(req)
  if path == "/health" {
    reply(conn, envelope(0, "ok", text("moon-token")))
    return
  }
  if path == "/login" && meth == "POST" {
    do_login(auth, header_or_empty(req, "x-device"), conn)
    return
  }
  if path == "/rotate" && meth == "POST" {
    do_rotate(auth, req, conn)
    return
  }
  // 其余路径交给守卫：未登录会被拦下，并给出精确原因
  let request_fns : @guard.RequestFns = {
    path: fn() { path },
    header: fn(name) { header_value(req, name) },
  }
  match @guard.run_guard(auth, route_guard, request_fns) {
    // 豁免面：放行但没有主体——绝不能把路径当 login_id 往下传
    Ok(@guard.Exempt) => reply(conn, envelope(0, "ok", text("public pass")))
    Ok(@guard.Passed(login_id)) =>
      if path == "/logout" && meth == "POST" {
        auth.logout(header_or_empty(req, "authorization"))
        reply(conn, envelope(0, "ok", text("logged out " + login_id)))
      } else if path == "/kick" && meth == "POST" {
        let kicked = auth.kickout(login_id)
        reply(conn, envelope(0, "ok", text("kicked " + kicked.to_string())))
      } else if path == "/whoami" {
        // 权限 SPI 的可见证据：库里没有业务语义，只有"给数 + 裁决"两步
        let ok = auth.has_permission(
          header_or_empty(req, "authorization"),
          ["user:info", "user:list"],
        ) catch {
          err => {
            reply(conn, envelope(99999999, err.message(), "null"))
            return
          }
        }
        let flag = if ok { "有" } else { "没有" }
        reply(
          conn,
          envelope(0, "ok", text(login_id + " " + flag + " user:info+user:list（AND）")),
        )
      } else {
        reply(conn, envelope(0, "ok", text("hello " + login_id)))
      }
    Err(err) => reply(conn, envelope(99999999, err.message(), "null"))
  }
}

///|
/// 处理器不得把错误抛穿到 `main`：失败就地转成 code=99999999 的信封
async fn handle_safe(
  auth : @app.TokenAuth[@mem.MemoryStore, DemoPerms],
  route_guard : @guard.RouteGuard,
  req : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  handle(auth, route_guard, req, conn) catch {
    err => reply(conn, envelope(99999999, "\{err}", "null"))
  }
}

///|
async fn main {
  let listen = "127.0.0.1:18890"
  let p : DemoPerms = { permissions: ["user:info", "user:list"], roles: ["demo"], }
  let auth = @app.TokenAuth::new(
    "user",
    @app.TokenConfig::default(),
    @mem.MemoryStore::new("user"),
    p,
    @style.opaque_style(),
  )
  let route_guard = @guard.RouteGuard::new()
    .match_pattern("/api/**")
    .match_pattern("/logout")
    .match_pattern("/kick")
    .match_pattern("/whoami")
    .not_match_pattern("/api/public/**")
  println("moon-token demo listening on \{listen}（GET /health）")
  println("  冒烟：bash examples/curl.sh")
  let addr = @socket.Addr::parse(listen)
  let server = @http.Server(addr, reuse_addr=true)
  server.run_forever() <| async fn(req, _body, conn) {
    handle_safe(auth, route_guard, req, conn)
  }
}

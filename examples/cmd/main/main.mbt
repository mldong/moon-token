// examples/web：moon-token 的可运行演示服务（不发布）。
// 起法：moon run --target wasm examples/cmd/main     （默认 127.0.0.1:18890）
// 验证：bash examples/curl.sh

///|
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

///|
pub extend DemoPerms with @port.PermissionProvider::{get_permissions, get_roles}

///|
/// 与 mldong 框架契约同形的极简信封：code=0 成功，99999999 失败
fn envelope(code : Int, msg : String, data : String) -> String {
  "{\"code\":\{code.to_string()},\"msg\":\"\{msg}\",\"data\":\"\{data}\"}"
}

///|
fn method_of(req : @http.Request) -> String {
  match req.meth {
    Get => "GET"
    Post => "POST"
    Delete => "DELETE"
    _ => "OTHER"
  }
}

///|
fn header_value(req : @http.Request, name : String) -> String? {
  match req.headers.get(name) {
    None => None
    Some(v) => if v.is_empty() { None } else { Some(v) }
  }
}

///|
fn token_of(req : @http.Request) -> String? {
  match header_value(req, "authorization") {
    None => header_value(req, "Authorization")
    Some(v) => Some(v)
  }
}

///|
async fn reply(conn : @http.ServerConnection, payload : String) -> Unit {
  conn.send_response(200, "application/json")
  conn.write_string(payload)
  conn.end_response()
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
    reply(conn, envelope(0, "ok", "moon-token"))
    return
  }
  if path == "/login" && meth == "POST" {
    let result = auth.login("demo-user", device="cli") catch {
      err => {
        reply(conn, envelope(99999999, err.message(), ""))
        return
      }
    }
    reply(
      conn,
      envelope(
        0,
        "ok",
        "token=" + result.token + " refresh=" + result.refresh_token,
      ),
    )
    return
  }
  // 其余路径交给守卫：未登录会被拦下，并给出精确原因
  let request_fns : @guard.RequestFns = {
    path: fn() { path },
    header: fn(name) { header_value(req, name) },
  }
  match @guard.run_guard(auth, route_guard, request_fns) {
    Ok(login_id) =>
      if path == "/logout" && meth == "POST" {
        let token = match token_of(req) {
          None => ""
          Some(v) => v
        }
        auth.logout(token)
        reply(conn, envelope(0, "ok", "logged out " + login_id))
      } else if path == "/kick" && meth == "POST" {
        let kicked = auth.kickout(login_id)
        reply(conn, envelope(0, "ok", "kicked " + kicked.to_string()))
      } else {
        reply(conn, envelope(0, "ok", "hello " + login_id))
      }
    Err(err) => reply(conn, envelope(99999999, err.message(), ""))
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
    err => reply(conn, envelope(99999999, "\{err}", ""))
  }
}

///|
async fn main {
  let listen = "127.0.0.1:18890"
  let store = @mem.MemoryStore::new("user")
  let p : DemoPerms = { permissions: ["user:info"], roles: ["demo"], }
  let auth = @app.TokenAuth::new(
    "user",
    @app.TokenConfig::default(),
    store,
    p,
    @style.opaque_style(),
  )
  let route_guard = @guard.RouteGuard::new()
    .match_pattern("/api/**")
    .match_pattern("/logout")
    .match_pattern("/kick")
    .not_match_pattern("/api/public/**")
  println("moon-token demo listening on \{listen} (GET /health)")
  let addr = @socket.Addr::parse(listen)
  let server = @http.Server(addr, reuse_addr=true)
  server.run_forever() <| async fn(req, _body, conn) {
    handle_safe(auth, route_guard, req, conn)
  }
}

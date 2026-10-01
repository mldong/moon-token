///|
/// 站点进程：一个端口两个门面——`/` 起是给人看的 HTML，`/api/**`、`/login`、`/kick`、
/// `/logout` 是给脚本看的 JSON（原来那个纯 JSON demo 合到这里，少一个入口少一份腐坏）。
/// 起法：moon run --target wasm examples/cmd/serve      （默认 127.0.0.1:18891）
fn envelope(code : Int, msg : String, data : String) -> String {
  "{\"code\":\{code.to_string()},\"msg\":\"\{msg}\",\"data\":\"\{data}\"}"
}

///|
fn method_of(req : @http.Request) -> String {
  match req.meth {
    Get => "GET"
    Post => "POST"
    Put => "PUT"
    Delete => "DELETE"
    Options => "OPTIONS"
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
/// 取 token：先看 header（Authorization），再退到 `?token=`——curl 与浏览器都能用
fn request_token(req : @http.Request, params : Map[String, String]) -> String {
  match header_value(req, "authorization") {
    Some(v) => v
    None =>
      match params.get("token") {
        None => ""
        Some(v) => v
      }
  }
}

///|
async fn reply(
  conn : @http.ServerConnection,
  status : Int,
  ctype : String,
  body : String,
) -> Unit {
  conn.send_response(status, ctype)
  conn.write_string(body)
  conn.end_response()
}

///|
async fn html(conn : @http.ServerConnection, body : String) -> Unit {
  reply(conn, 200, "text/html; charset=utf-8", body)
}

///|
async fn json(conn : @http.ServerConnection, body : String) -> Unit {
  reply(conn, 200, "application/json; charset=utf-8", body)
}

///|
/// 页面渲染失败也要回一页人能看的 HTML，而不是连接被掐断
async fn fail_page(
  conn : @http.ServerConnection,
  page : String,
  err : Error,
) -> Unit {
  let detail = "\{err}"
  reply(conn, 200, "text/html; charset=utf-8", @site.error_page(page, detail))
}

///|
/// 一个端点一个函数，且 `try` 里只放库调用（响应写出留在 try 外）：
/// `try` 的捕获类型取块内**全部**效果之并，把 `conn.write` 混进来会把
/// 精确的 `TokenError` 拓宽成内置 `Error`，`err.message()` 就没了。
async fn api_login(
  site : @site.Site,
  realm : String,
  auth : @site.Auth,
  params : Map[String, String],
  conn : @http.ServerConnection,
) -> Unit {
  let login_id = @site.param(params, "user", "demo-user")
  let device = @site.param(params, "device", "cli")
  let payload = try {
    let r = auth.login(login_id, device~)
    site.remember_token(realm, login_id, r.token)
    "{\"code\":0,\"msg\":\"ok\",\"data\":{\"token\":\"\{r.token}\",\"refresh_token\":\"\{r.refresh_token}\"}}"
  } catch {
    err => envelope(99999999, err.message(), "")
  }
  json(conn, payload)
}

///|
async fn api_kick(
  auth : @site.Auth,
  token : String,
  params : Map[String, String],
  conn : @http.ServerConnection,
) -> Unit {
  let given = @site.param(params, "user", "")
  let payload = try {
    let mut target = given
    if target.is_empty() {
      // 没给 user 就先认 token：踢的是"自己"
      target = auth.check_login(token)
    }
    envelope(0, "ok", "kicked " + auth.kickout(target).to_string())
  } catch {
    err => envelope(99999999, err.message(), "")
  }
  json(conn, payload)
}

///|
async fn api_logout(
  auth : @site.Auth,
  token : String,
  conn : @http.ServerConnection,
) -> Unit {
  let payload = try {
    auth.logout(token)
    envelope(0, "ok", "logged out")
  } catch {
    err => envelope(99999999, err.message(), "")
  }
  json(conn, payload)
}

///|
/// JSON 门面上不受保护的那几条：/health 与登录/踢人/登出
async fn api_open(
  site : @site.Site,
  route : String,
  meth : String,
  req : @http.Request,
  params : Map[String, String],
  conn : @http.ServerConnection,
) -> Unit {
  let realm = @site.param(params, "realm", "user")
  let auth = site.auth_of(realm)
  if route == "/health" {
    json(conn, envelope(0, "ok", "moon-token"))
  } else if route == "/login" && meth == "POST" {
    api_login(site, realm, auth, params, conn)
  } else if route == "/kick" && meth == "POST" {
    api_kick(auth, request_token(req, params), params, conn)
  } else if route == "/logout" && meth == "POST" {
    api_logout(auth, request_token(req, params), conn)
  } else {
    json(conn, envelope(99999999, "no such open route: " + route, ""))
  }
}

///|
/// 受保护面：与守卫模拟页共用同一个 RouteGuard + run_guard，守卫逻辑只有一份
async fn api_guarded(
  site : @site.Site,
  route : String,
  req : @http.Request,
  params : Map[String, String],
  conn : @http.ServerConnection,
) -> Unit {
  let auth = site.auth_of(@site.param(params, "realm", "user"))
  let route_guard = @guard.RouteGuard::new().match_pattern("/api/**")
  let request_fns : @guard.RequestFns = {
    path: fn() { route },
    header: fn(_name) {
      let t = request_token(req, params)
      if t.is_empty() {
        None
      } else {
        Some(t)
      }
    },
  }
  match @guard.run_guard(auth, route_guard, request_fns) {
    Ok(login_id) =>
      json(
        conn,
        "{\"code\":0,\"msg\":\"ok\",\"data\":{\"login_id\":\"\{login_id}\",\"path\":\"\{route}\"}}",
      )
    Err(err) => json(conn, envelope(99999999, err.message(), ""))
  }
}

///|
async fn api(
  site : @site.Site,
  route : String,
  meth : String,
  req : @http.Request,
  params : Map[String, String],
  conn : @http.ServerConnection,
) -> Unit {
  if route.has_prefix("/api/") {
    api_guarded(site, route, req, params, conn)
  } else {
    api_open(site, route, meth, req, params, conn)
  }
}

///|
async fn serve(
  site : @site.Site,
  req : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  let (route, params) = @site.split_path_query(req.path)
  let meth = method_of(req)
  let is_json = route.has_prefix("/api/") ||
    route == "/health" ||
    (route == "/login" && meth == "POST") ||
    route == "/kick" ||
    route == "/logout"
  if is_json {
    api(site, route, method_of(req), req, params, conn)
  } else if route == "/" {
    html(conn, @site.page_overview(site)) catch {
      err => fail_page(conn, "总览", err)
    }
  } else if route == "/sessions" {
    html(conn, @site.page_sessions(site)) catch {
      err => fail_page(conn, "键位矩阵", err)
    }
  } else if route == "/login" {
    html(conn, @site.page_login_form(site)) catch {
      err => fail_page(conn, "登录台", err)
    }
  } else if route == "/do/login" {
    html(conn, @site.page_do_login(site, params)) catch {
      err => fail_page(conn, "登录结果", err)
    }
  } else if route == "/play" {
    html(conn, @site.page_play(site, params)) catch {
      err => fail_page(conn, "剧本剧场", err)
    }
  } else if route == "/guard" {
    html(conn, @site.page_guard(site, params)) catch {
      err => fail_page(conn, "守卫模拟", err)
    }
  } else if route == "/api-demo" {
    html(conn, @site.page_api_demo(site, params)) catch {
      err => fail_page(conn, "受保护 API", err)
    }
  } else if route == "/events" {
    html(conn, @site.page_events(site)) catch {
      err => fail_page(conn, "事件流", err)
    }
  } else if route == "/clock" {
    html(conn, @site.page_clock(site, params)) catch {
      err => fail_page(conn, "时间机器", err)
    }
  } else if route == "/reset" {
    html(conn, @site.page_reset(site)) catch {
      err => fail_page(conn, "重置", err)
    }
  } else {
    html(conn, @site.error_page("没有这个页面", "未知路径 " + route))
  }
}

///|
/// 首屏不空：两个 realm 各先签几枚会话当种子（内存版，无需外部服务）
async fn seed(site : @site.Site) -> Unit {
  let pairs = [
    ("user", "demo-user", "pc"),
    ("user", "vip-user", "mobile"),
    ("admin", "admin", "pc"),
  ]
  for (realm, account, device) in pairs {
    try {
      let r = site.auth_of(realm).login(account, device~)
      site.remember_token(realm, account, r.token)
    } catch {
      _ => ()
    }
  }
}

///|
async fn main {
  let listen = "127.0.0.1:18891"
  let site = @site.Site::new()
  site.install_clock()
  seed(site)
  println(
    "moon-token 演示站 listening on \{listen}（HTML + JSON 双门面）",
  )
  println(
    "  浏览器打开 http://\{listen}/ ；curl 冒烟：bash examples/curl.sh",
  )
  let addr = @socket.Addr::parse(listen)
  let server = @http.Server(addr, reuse_addr=true)
  server.run_forever() <| async fn(req, _body, conn) { serve(site, req, conn) }
}

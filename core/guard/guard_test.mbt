///|
/// G1/G2：守卫是纯逻辑——路径匹配（同步）与"保护面 + 豁免 + 追加断言"的端到端各测一条。
struct FixedView {
  permissions : Array[String]
  roles : Array[String]
}

///|
pub impl @port.PermissionProvider for FixedView with fn get_permissions(
  self,
  _login_id,
  _device,
) {
  self.permissions
}

///|
pub impl @port.PermissionProvider for FixedView with fn get_roles(
  self,
  _login_id,
  _device,
) {
  self.roles
}

///|
pub extend FixedView with @port.PermissionProvider::{get_permissions, get_roles}

///|
fn request(path : String, token : String?) -> @guard.RequestFns {
  let fns : @guard.RequestFns = {
    path: fn() { path },
    header: fn(name) { if name == "Authorization" { token } else { None } },
  }
  fns
}

///|
test "G1 路径模式：/** 吃尾段、* 名单段、字面相等" {
  assert_true(@guard.matches_path("/api/**", "/api/user/list"))
  assert_true(@guard.matches_path("/api/**", "/api/user"))
  assert_true(!@guard.matches_path("/api/**", "/login"))
  assert_true(@guard.matches_path("/api/*", "/api/user"))
  assert_true(!@guard.matches_path("/api/*", "/api/user/list"))
  assert_true(@guard.matches_path("/api/login", "/api/login"))
}

///|
async test "G2 端到端：公开端点放行、保护端点未登录拦下、带 token 放行并跑追加断言" {
  @port.set_clock(Some(fn() { 5_000_000L }))
  let store = @mem.MemoryStore::new("user")
  let p : FixedView = { permissions: ["user:info"], roles: [], }
  let auth = @app.TokenAuth::new(
    "user",
    @app.TokenConfig::default(),
    store,
    p,
    @style.opaque_style(),
  )
  let result = auth.login("u1", device="pc")
  let base = @guard.RouteGuard::new()
    .match_pattern("/api/**")
    .not_match_pattern("/api/login")
  // 公开端点：不在保护面 ⇒ 放行（连 token 都不看）
  let public_pass = @guard.run_guard(auth, base, request("/api/login", None))
  assert_true(public_pass is Ok(_))
  // 保护端点 + 无 token ⇒ 必须拦下，且报的是 AbsentToken
  let blocked = @guard.run_guard(auth, base, request("/api/user/list", None))
  match blocked {
    Ok(_) => fail("无 token 访问保护端点必须被拦下")
    Err(err) => {
      let reason = match err.not_login_reason() {
        None => @port.UnknownToken
        Some(r) => r
      }
      assert_eq(reason.code(), @port.AbsentToken.code())
    }
  }
  // 带 token ⇒ 放行并返回 login_id
  match
    @guard.run_guard(auth, base, request("/api/user/list", Some(result.token))) {
    Ok(login_id) => assert_eq(login_id, "u1")
    Err(err) => fail("带有效 token 应当放行，实得 " + err.message())
  }
  // 追加断言确实被执行到了
  let seen : Array[String] = []
  let strict = base.check((login_id, _token) => seen.push(login_id))
  @guard.run_guard(auth, strict, request("/api/user/list", Some(result.token)))
  |> ignore
  assert_eq(seen, ["u1"])
  @port.set_clock(None)
}

///|
/// R1：README「最小用法」那段要真能编译并跑通核心链（文档示例抽出来真跑的既有纪律）。
/// 挂在 guard 包的测试里：README 的示例本身就是"auth + 守卫"这条组合。
async test "R1 README 最小用法跑通 login → check → kick 精确原因 + 守卫拦截" {
  @port.set_clock(Some(fn() { 9_000_000L }))
  let store = @mem.MemoryStore::new("user")
  let p : FixedView = { permissions: ["user:info"], roles: ["admin"], }
  let auth = @app.TokenAuth::new(
    "user",
    @app.TokenConfig::default(),
    store,
    p,
    @style.opaque_style(),
  )
  let result = auth.login("u1", device="pc")
  assert_eq(auth.check_login(result.token), "u1")
  auth.kickout("u1", device="pc") |> ignore
  let code = try {
    auth.check_login(result.token) |> ignore
    -1
  } catch {
    err =>
      match err.not_login_reason() {
        None => -2
        Some(r) => r.code()
      }
  }
  assert_eq(code, @port.KickedOut.code())
  let route_guard = @guard.RouteGuard::new()
    .match_pattern("/api/**")
    .not_match_pattern("/api/public/**")
  assert_true(
    @guard.run_guard(auth, route_guard, request("/api/user/info", None))
    is Err(_),
  )
  let public_pass2 = @guard.run_guard(
    auth,
    route_guard,
    request("/api/public/ping", None),
  )
  assert_true(public_pass2 is Ok(_))
  @port.set_clock(None)
}

///|
/// moon-token 的免端口演示（不发布）：把 cmd/main 那套端到端剧本搬进进程内，
/// 不起 HTTP、不占端口、跑完即退——起不了端口的环境（CI、受限容器）与快速冒烟都用它。
/// 起法：moon run --target wasm examples/cmd/oneshot
///
/// 只依赖库的公开 API；每步断言**精确原因**，而不是"有没有报错"。

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
  _extra,
) {
  self.permissions
}

///|
pub impl @port.PermissionProvider for DemoPerms with fn get_roles(
  self,
  _login_id,
  _device,
  _extra,
) {
  self.roles
}

///|
pub impl @port.PermissionProvider for DemoPerms with fn is_super_admin(
  _self,
  _login_id,
  _device,
  _extra,
) {
  false
}

pub extend DemoPerms with @port.PermissionProvider::{
  get_permissions,
  get_roles,
  is_super_admin,
}

///|
fn new_auth() -> @app.TokenAuth[@mem.MemoryStore, DemoPerms] {
  let p : DemoPerms = { permissions: ["user:info", "user:list"], roles: ["demo"] }
  @app.TokenAuth::new(
    "user",
    @app.TokenConfig::default(),
    @mem.MemoryStore::new("user"),
    p,
    @style.opaque_style(),
  )
}

///|
async fn main {
  let auth = new_auth()
  let route_guard = @guard.RouteGuard::new()
    .match_pattern("/api/**")
    .not_match_pattern("/api/public/**")

  println("[1] 豁免面：无凭证也放行，且没有主体")
  let exempt = @guard.run_guard(auth, route_guard, {
    path: fn() { "/api/public/ping" },
    header: fn(_name) { None },
  }) catch {
    err => {
      println("FAIL[1]：豁免面不该拦：" + err.message())
      return
    }
  }
  let exempt_ok : Bool = match exempt {
    @guard.Exempt => true
    @guard.Passed(_) => false
  }
  assert_eq(exempt_ok, true)

  println("[2] 保护面无凭证 —— 期望 not login: AbsentToken")
  let absent = try {
    @guard.run_guard(auth, route_guard, {
      path: fn() { "/api/user/info" },
      header: fn(_name) { None },
    }) |> ignore
    "无凭证竟被放行"
  } catch {
    err => err.message()
  }
  assert_eq(absent, "not login: AbsentToken")

  println("[3] 登录（pc）—— 签发 access + refresh 整对")
  let pair = auth.login("demo-user", device="pc") catch {
    err => {
      println("FAIL[3]：" + err.message())
      return
    }
  }

  println("[4] 带 token 正查 —— 期望回 login_id")
  let who = auth.check_login(pair.token) catch {
    err => {
      println("FAIL[4]：" + err.message())
      return
    }
  }
  assert_eq(who, "demo-user")

  println("[5] 权限 SPI —— 业务只供数，AND 裁决在库里")
  let ok = auth.has_permission(pair.token, ["user:info", "user:list"]) catch {
    err => {
      println("FAIL[5]：" + err.message())
      return
    }
  }
  assert_eq(ok, true)

  println("[6] 全量轮转 —— 整对换新")
  let rotated = auth.rotate(pair.refresh_token) catch {
    err => {
      println("FAIL[6]：" + err.message())
      return
    }
  }

  println("[7] 旧 access 再用 —— 期望 not login: UnknownToken（旧对同废）")
  let old_access = auth.check_login(pair.token) catch { err => err.message() }
  assert_eq(old_access, "not login: UnknownToken")

  println("[8] 旧 refresh 重放 —— 期望 not login: RefreshInvalid（原子取删）")
  let replay = try {
    auth.rotate(pair.refresh_token) |> ignore
    "重放竟被接受"
  } catch {
    err => err.message()
  }
  assert_eq(replay, "not login: RefreshInvalid")

  println("[9] 同账号另起（mobile）—— 默认 Coexist 共存")
  let mobile = auth.login("demo-user", device="mobile") catch {
    err => {
      println("FAIL[9]：" + err.message())
      return
    }
  }
  let who2 = auth.check_login(mobile.token) catch {
    err => {
      println("FAIL[9b]：" + err.message())
      return
    }
  }
  assert_eq(who2, "demo-user")

  println("[10] 批量踢人（不带 device）—— 旧 access 被拒且绑定 refresh 一起失效")
  let kicked = auth.kickout("demo-user") catch {
    err => {
      println("FAIL[10]：" + err.message())
      return
    }
  }
  assert_eq(kicked >= 1, true)

  println("[11] 被踢方再用 —— 期望 not login: KickedOut（不是笼统未登录）")
  let kicked_pc = auth.check_login(rotated.token) catch { err => err.message() }
  assert_eq(kicked_pc, "not login: KickedOut")

  println("[12] 另一设备同样被踢 —— 批量踢＝全设备")
  let kicked_mob = auth.check_login(mobile.token) catch { err => err.message() }
  assert_eq(kicked_mob, "not login: KickedOut")

  println("[13] 重新登录后注销 —— 期望 not login: UnknownToken（注销删键，与被踢分得开）")
  let again = auth.login("demo-user", device="pc") catch {
    err => {
      println("FAIL[13]：" + err.message())
      return
    }
  }
  auth.logout(again.token) catch {
    err => {
      println("FAIL[13b]：" + err.message())
      return
    }
  }
  let after_logout = auth.check_login(again.token) catch { err => err.message() }
  assert_eq(after_logout, "not login: UnknownToken")

  println(
    "PASS：13 步全绿——豁免/AbsentToken/签发/正查/AND 裁决/轮转/旧对同废/重放必拒/共存/批量踢/KickedOut/注销删键 逐条原因对上",
  )
}

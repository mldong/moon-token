# 路由守卫

`RouteGuard` 是纯逻辑：路径模式 + 一个取头的闭包，不依赖任何 web 框架。
所以官方 `@http.Server`、moonasgi、mooncat，甚至你自己的手写路由，挂的都是同一套守卫。

本页代码块由 `scripts/docs-check.sh` 逐块真编译真跑（对注册表已发布件）。

```moonbit
pub(all) struct P {
  permissions : Array[String]
  roles : Array[String]
}

pub impl @port.PermissionProvider for P with fn get_permissions(self, _login_id, _device) {
  self.permissions
}

pub impl @port.PermissionProvider for P with fn get_roles(self, _login_id, _device) {
  self.roles
}

pub extend P with @port.PermissionProvider::{get_permissions, get_roles}

fn auth() -> @app.TokenAuth[@mem.MemoryStore, P] {
  let p : P = { permissions: ["user:info"], roles: ["demo"] }
  @app.TokenAuth::new("user", @app.TokenConfig::default(), @mem.MemoryStore::new("user"), p, @style.opaque_style())
}

fn site_guard() -> @guard.RouteGuard {
  @guard.RouteGuard::new()
    .match_pattern("/api/**")
    .match_pattern("/admin/**")
    .not_match_pattern("/api/public/**")
}

/// 把"一次请求"喂给守卫：库只要两件事——路径是什么、头里有什么
fn request(path : String, token : String) -> @guard.RequestFns {
  {
    path: fn() { path },
    header: fn(name) {
      if name == "Authorization" && !token.is_empty() { Some(token) } else { None }
    },
  }
}
```

## 1. 三条规则，一次判定

```moonbit
fn verdict(v : Result[@guard.GuardOutcome, @port.TokenError]) -> String {
  match v {
    Ok(@guard.Exempt) => "exempt"
    Ok(@guard.Passed(login_id)) => login_id
    Err(err) => err.message()
  }
}

async fn three_rules() -> Array[String] raise {
  let a = auth()
  let t = a.login("u1", device="pc").token
  let g = site_guard()
  [
    // 保护面内 + 有 token ⇒ Passed(login_id)
    verdict(@guard.run_guard(a, g, request("/api/user/info", t))),
    // 保护面内 + 无 token ⇒ AbsentToken
    verdict(@guard.run_guard(a, g, request("/api/user/info", ""))),
    // 豁免臂优先级最高：即便在 /api/** 下也不问身份 ⇒ Exempt（没有主体）
    verdict(@guard.run_guard(a, g, request("/api/public/ping", ""))),
    // 压根不在保护面 ⇒ 同样 Exempt
    verdict(@guard.run_guard(a, g, request("/health", ""))),
  ]
}

async test "先匹配、后豁免、不在面内一律放行" {
  let r = three_rules()
  assert_eq(r[0], "u1")
  assert_eq(r[1], "not login: AbsentToken")
  assert_eq(r[2], "exempt")
  assert_eq(r[3], "exempt")
}
```

**两种放行由类型区分，不靠"值里装的是什么"猜**：`run_guard` 的 `Ok` 装的是 `GuardOutcome`。

| 情况 | 结果 | handler 能拿到什么 |
|---|---|---|
| 在保护面内且鉴权通过 | `Passed(login_id)` | 主体身份 |
| 命中豁免臂，或压根不在保护面内 | `Exempt` | **没有主体**——别去编一个 |

> 0.1.1 及之前这里返回 `Ok(String)`，豁免分支塞的是**请求路径**，于是
> `login_id == "/api/public/ping"` 这种假值能被一路传进业务。0.1.2 起由类型挡住
> （`docs/data-model.md` §8 末记着这条变更）。
>
> 守卫只挂在保护面上时，`Exempt` 那一臂其实永远不会走到——但**必须写**，
> 一是让编译器替你确认"这里没有身份可用"，二是豁免规则随时可能加。

## 2. 模式匹配支持什么

```moonbit
fn matches() -> Array[Bool] {
  [
    @guard.matches_path("/api/**", "/api/user/info"),
    @guard.matches_path("/api/**", "/api"),
    @guard.matches_path("/api/*", "/api/user/info"),
    @guard.matches_path("/api/*", "/api/info"),
    @guard.matches_path("/api/user/info", "/api/user/info"),
    @guard.matches_path("/api/user/info", "/api/user/list"),
  ]
}

test "/** 吃后续所有段，* 只吃一段" {
  assert_eq(matches(), [true, true, false, true, true, false])
}
```

- `/**` 结尾：吃掉后续所有段，**并且也命中前缀本身**——`/api/**` 既命中 `/api/user/info`，也命中 `/api`。
  （`**` 是"这一段之后全收"，不是"至少还要一段"。想只收深层路由就再写一条更细的排除臂。）
- `*`：只吃一段。
- 其余按字面逐段相等。

## 3. token 从哪来：`token_name` 与 `token_prefix`

守卫用 `auth.config.token_name` 去要头，再按 `token_prefix` 剥前缀。默认是裸值（`Authorization: <token>`）；
要接 `Bearer` 风格只改配置：

```moonbit
async fn bearer_style() -> (String, String) raise {
  let p : P = { permissions: ["user:info"], roles: ["demo"] }
  let cfg = @app.TokenConfig::default()
  cfg.token_prefix = "Bearer "
  let a = @app.TokenAuth::new("user", cfg, @mem.MemoryStore::new("user"), p, @style.opaque_style())
  let t = a.login("u2", device="pc").token
  let g = @guard.RouteGuard::new().match_pattern("/api/**")
  let ok : @guard.RequestFns = {
    path: fn() { "/api/x" },
    header: fn(name) { if name == "Authorization" { Some("Bearer " + t) } else { None } },
  }
  let bad : @guard.RequestFns = {
    path: fn() { "/api/x" },
    header: fn(name) { if name == "Authorization" { Some(t) } else { None } },
  }
  (
    verdict(@guard.run_guard(a, g, ok)),
    verdict(@guard.run_guard(a, g, bad)),
  )
}

async test "配了前缀就只认带前缀的头；裸值取不到 token，报 AbsentToken" {
  let (with_prefix, bare) = bearer_style()
  assert_eq(with_prefix, "u2")
  assert_eq(bare, "not login: AbsentToken")
}
```

前缀是**精确匹配**（`has_prefix`），剥完再 `trim`。配了 `"Bearer "` 却收到 `bearer xxx`（大小写不同）
就是取不到——这是刻意的：认证头的格式不该由库来猜。
注意"取不到"报的是 `AbsentToken`（压根没拿到 token），不是 `UnknownToken`（拿到了但查无此枚）：
前者是**接线错了**，后者才是**用户该重登**。这两个原因混在一起，线上排查会瞎。

## 4. 追加断言：`check` 收的是同步闭包

`RouteGuard::check` 允许在身份通过后再加断言，签名是 `(login_id, token) -> Unit raise`——**同步**。
库里所有权限/角色判定都是 async（要查业务供数，可能是 IO），所以**别在 `check` 里判权限**：

```moonbit
async fn extra_check() -> String raise {
  let a = auth()
  let t = a.login("u3", device="pc").token
  // 同步断言：能拿到身份之后还想卡死的规则（比如禁止某台设备进后台）
  let g = @guard.RouteGuard::new().match_pattern("/api/**").check(
    (login_id, token) => {
      if login_id == "banned-device-owner" {
        raise @port.InvalidInput("该账号不允许走这条路由")
      }
      if token.is_empty() {
        raise @port.InvalidInput("token 不应为空")
      }
    },
  )
  verdict(@guard.run_guard(a, g, request("/api/x", t)))
}

async test "同步断言通过则照旧放行" {
  assert_eq(extra_check(), "u3")
}
```

权限/角色这类要查数的断言，写在处理器里（拿到 `login_id` 之后再 `check_permission`），
示例服务的 `/whoami` 就是这个形状。`check` 留给"不需要 IO 的硬规则"。

## 5. 挂到真实 HTTP 上

`examples/cmd/main` 里那十行就是完整接法：

```text
match @guard.run_guard(auth, route_guard, {
  path: fn() { req.path },
  header: fn(name) { header_value(req, name) },
}) {
  Ok(login_id) => 继续处理这个请求
  Err(err)     => 回 {"code":99999999,"msg":err.message(),...}
}
```

两个坑：

- `req.path` 在官方 `@http.Server` 里带的是**完整请求目标**（含 `?a=1`），要按 `?` 切一刀再交给守卫，
  否则 `/api/user/info?x=1` 匹配不上 `/api/**` 之外的更细模式。
- 处理器不要把错误抛穿到 `main`：守卫已经返回 `Result`，其它库调用用 `try/catch` 就地转成信封，
  否则一个未登录请求会让整个连接崩掉。

## 6. 下一步

- 放行之后怎么判权限：[权限与角色](permissions.md)
- 错误怎么映射成响应码：[错误词汇表](error-vocabulary.md)

# 会话与批量操作

登录之后要对"人"做的事——查在线、改附加态、踢、顶、封——全部以 `login_id` 为轴，
靠反查族（`A:` 键）落地。本页代码块由 `scripts/docs-check.sh` 逐块真编译真跑。

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
```

## 1. 在线列表：数的是"活着的会话"，不是反查族成员

```moonbit
async fn online_view() -> (Int, String) raise {
  let a = auth()
  a.login("u1", device="pc") |> ignore
  a.login("u1", device="phone") |> ignore
  a.login("u1", device="pad") |> ignore
  let before = a.get_token_list_by_login_id("u1")
  a.kickout("u1", device="phone") |> ignore
  let after = a.get_token_list_by_login_id("u1")
  (before.length() - after.length(), (a.get_device_list("u1")).join(","))
}

async test "被踢的设备立刻从在线列表与设备列表里消失" {
  let (dropped, devices) = online_view()
  assert_eq(dropped, 1)
  assert_eq(devices, "pc,pad")
}
```

`get_token_list_by_login_id` 每条是一个 `TokenInfo { token, device, expire_at, login_time }`。
它**不数反查族成员**：族里记着但会话已被踢/已过期的一律不出现——否则"在线 3 台"里可能有两台是僵尸，
运营看到的数就是假的。`get_device_list` 是同一判据下去重后的设备集合。

## 2. 两种会话：跟着 token 走的，和跟着账号走的

| | 载体 | 键 | 典型用途 |
|---|---|---|---|
| token 会话附加态 | 每枚 token 一份 | `{realm}:T:{token}` 的 extra 段 | 本次登录的临时上下文（入口、UA、灰度标记） |
| 账号会话 | 每个 login_id 一份，**跨该账号所有 token 可见** | `{realm}:S:{login_id}` | 与设备无关的账号级态（最后活跃页、切换中的租户） |

```moonbit
async fn token_extra_roundtrip() -> (String, String) raise {
  let a = auth()
  let t = a.login("u2", device="pc").token
  a.update_token_session(t, "entry", Some("app"))
  // value = None 是删除该属性（空串不算删除——'' 与"没有这个键"是两件事）
  a.update_token_session(t, "draft", Some("to-be-removed"))
  a.update_token_session(t, "draft", None)
  let session = match a.get_token_session(t) {
    None => "无会话"
    Some(s) => match s.extra("entry") {
      None => "无属性"
      Some(v) => v
    }
  }
  let draft = match a.get_token_session(t) {
    None => "无会话"
    Some(s) => if s.extra("draft") is None { "已删" } else { "还在" }
  }
  (session, draft)
}

async test "extra 读写往返，None 才删键" {
  let (entry, draft) = token_extra_roundtrip()
  assert_eq(entry, "app")
  assert_eq(draft, "已删")
}
```

可选值一律用 `match` 或 `is None` 取，别指望有默认值运算符。
`update_*_session` 的 `value` 参数同理：`None` 是"删掉这个属性"，`Some("")` 是"把它改成空串"——
两者在库里是不同状态，因为 `''` 与"没有这个键"在业务上从来不是一回事。

```moonbit
async fn account_session_shared_across_tokens() -> String raise {
  let a = auth()
  let pc = a.login("u3", device="pc")
  let phone = a.login("u3", device="phone")
  a.update_account_session("u3", "tenant", Some("t-9"))
  // 另一枚 token 也读得到：账号级会话不属于某一枚 token
  let seen = match a.get_account_session("u3") {
    None => "无"
    Some(r) => r.attrs["tenant"]
  }
  a.logout(pc.token)
  let still_there = match a.get_account_session("u3") {
    None => "无"
    Some(r) => r.attrs["tenant"]
  }
  seen + "/" + still_there + "/" + (if phone.token == pc.token { "两枚相同" } else { "两枚不同" })
}

async test "账号会话跨 token 可见，且不随单枚注销而消失" {
  assert_eq(account_session_shared_across_tokens(), "t-9/t-9/两枚不同")
}
```

## 3. 注销漏斗：只有一个出口

`logout`（按 token）与 `logout_by_id`（按账号，可限定设备）汇成同一件事：**删 `T:` 键 + 从反查族摘除 +
联动删绑定的 `R:` 键**。三处少写一处就会留孤儿键——refresh 还活着但 access 已经没了，
下次轮转会签出一枚"上一世"的会话。

```moonbit
async fn logout_is_not_kick() -> (String, String) raise {
  let a = auth()
  let by_logout = a.login("u4", device="pc")
  let by_kick = a.login("u4", device="phone")
  a.logout(by_logout.token)
  a.kickout("u4", device="phone") |> ignore
  (
    a.check_login(by_logout.token) catch { err => err.message() },
    a.check_login(by_kick.token) catch { err => err.message() },
  )
}

async test "注销＝删键（UnknownToken），踢＝落墓碑（KickedOut）：两件事必须分得开" {
  let (after_logout, after_kick) = logout_is_not_kick()
  assert_eq(after_logout, "not login: UnknownToken")
  assert_eq(after_kick, "not login: KickedOut")
}
```

注销后 refresh 也一起失效（同一枚 access 绑着的那一条），所以"注销后还能拿 refresh 续命"不可能发生。

## 4. 封禁：压在会话之上的账号级判定

`disable` 写的是 `D:` 键，与 `T:` 键互不改写——**封禁期间会话本身仍然有效**，
只是每次鉴权都要先问一句"这人被封了吗"。解禁后原 token 原样可用，用户不需要重登。

```moonbit
async fn disable_then_undo() -> (String, String, String) raise {
  let a = auth()
  let t = a.login("u5", device="pc").token
  a.disable("u5", @port.Duration::from_minutes(30L), reason="风控命中")
  let during = a.check_login(t) catch { err => err.message() }
  let banned = a.is_disabled("u5")
  a.undo_disable("u5")
  (during, banned.to_string(), a.check_login(t))
}

async test "封禁给的是带原因与到期时刻的错，解禁后原 token 复活" {
  let (during, banned, after) = disable_then_undo()
  assert_true(during.contains("disabled until"))
  assert_true(during.contains("风控命中"))
  assert_eq(banned, "true")
  assert_eq(after, "u5")
}
```

`ban_of` 在读路径上顺手判到期：过期即视为无封禁并回收脏行，所以不需要后台定时任务去"解封"。

## 5. 保留宽窗与 `sweep`

被踢/被顶的 token 落成墓碑后不会立刻消失——保留 `kick_grace`（默认 5 分钟）。
这段时间内它仍占一个键位，为的是让"被踢"这件事能被读出来。窗口关上之后，
读路径会当场回收它。长驻服务还可以主动 `sweep` 一次清干净。

```moonbit
async fn grace_then_recycle() -> (String, String, Int) raise {
  let a = auth()
  let t = a.login("u6", device="pc").token
  a.kickout("u6") |> ignore
  let in_window = a.check_login(t) catch { err => err.message() }
  let cell = @port.now_ms() + a.config.kick_grace_ms() + 1000L
  @port.set_clock(Some(fn() { cell }))
  let after_window = a.check_login(t) catch { err => err.message() }
  let swept = a.sweep()
  @port.set_clock(None)
  (in_window, after_window, swept)
}

async test "宽窗内 KickedOut、窗外 UnknownToken，sweep 返回被回收的条数" {
  let (in_window, after_window, _swept) = grace_then_recycle()
  assert_eq(in_window, "not login: KickedOut")
  assert_eq(after_window, "not login: UnknownToken")
}
```

拨时钟这件事为什么必须能做，见 [时钟与熵源](clock-and-entropy.md)。

## 6. 一张表记住谁改谁

| 调用 | `T:` 会话 | `A:` 反查族 | `R:` refresh | `S:` 账号会话 | `D:` 封禁 |
|---|---|---|---|---|---|
| `login` | 新增 | 加成员 | 新增绑定 | — | 命中即拒 |
| `check_login` | 读 + 可能续期 | 读 | — | — | 读（过期即回收） |
| `rotate` | 删旧 + 新增 | 摘旧 + 加新 | 原子取删 + 新增 | — | — |
| `logout` | **删** | 摘除 | **联动删** | — | — |
| `kickout` / `supersede` | 落墓碑（不删） | 成员保留 | — | — | — |
| `disable` / `undo_disable` | — | — | — | — | 写 / 删 |
| `update_*_session` | 改 extra | — | — | 改属性 | — |
| `sweep` | 回收过期与墓碑 | 剔除过期成员 | 随 access 失效 | 随族到期 | 到期回收 |

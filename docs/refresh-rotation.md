# 刷新与全量轮转

`rotate` 是本库最容易写错的一个用例——错法在别家实现里出现过，也在这套生态的 13 个栈里出现过一次，
代价是"用户闲置一会儿就再也续不上命"。本页把语义钉死，并给出可跑的证明。

本页代码块由 `scripts/docs-check.sh` 逐块真编译真跑（对注册表已发布件）。

```moonbit
pub(all) struct P {
  permissions : Array[String]
  roles : Array[String]
}

pub impl @port.PermissionProvider for P with fn get_permissions(self, _login_id, _device, _extra) {
  self.permissions
}

pub impl @port.PermissionProvider for P with fn get_roles(self, _login_id, _device, _extra) {
  self.roles
}

pub impl @port.PermissionProvider for P with fn is_super_admin(
  _self,
  _login_id,
  _device,
  _extra,
) {
  false
}

pub extend P with @port.PermissionProvider::{
  get_permissions,
  get_roles,
  is_super_admin,
}

fn auth() -> @app.TokenAuth[@mem.MemoryStore, P] {
  let p : P = { permissions: ["user:info"], roles: ["demo"] }
  @app.TokenAuth::new("user", @app.TokenConfig::default(), @mem.MemoryStore::new("user"), p, @style.opaque_style())
}
```

## 1. 语义：整对换新，旧对同废

`login` 一次签发两枚：access（短时效，走请求头）与 refresh（长时效，只在轮转时出现）。
`rotate(refresh)` 做的事是：

1. **原子取删** `R:` 键——取到才算有效，取不到就是失效。重放防护完全靠这一步，不需要额外的黑名单。
2. 把**旧 access** 从反查族摘掉并删键（"整对换新"里的"废"就是这一处）。
3. 签出全新的一整对，重新绑定。
4. 落库之后 fire `Refreshed`。

第 3 步签的新会话**搬用旧会话的 `extra`**（用例 A39）：轮转换的是凭证，不该把人换出原来那条业务线。
旧 access 的会话已经读不到时（自然过期或已注销）就没得搬，新会话带空属性表。

```moonbit
async fn rotate_shape() -> (Bool, String, String) raise {
  let a = auth()
  let first = a.login("u1", device="pc")
  let second = a.rotate(first.refresh_token)
  (
    second.token != first.token,
    a.check_login(first.token) catch { err => err.message() },
    a.check_login(second.token),
  )
}

async test "换新后：旧 access 立刻失效，新 access 可用" {
  let (changed, old_reason, who) = rotate_shape()
  assert_true(changed)
  assert_eq(old_reason, "not login: UnknownToken")
  assert_eq(who, "u1")
}
```

## 2. 重放必拒

同一枚 refresh 用第二次，拿到的不是"上一轮那对"，而是 `RefreshInvalid`。

```moonbit
async fn replay() -> (String, Bool) raise {
  let a = auth()
  let first = a.login("u2", device="pc")
  let second = a.rotate(first.refresh_token)
  // rotate 成功时给 LoginResult，取"抛出来的话"就得用块式 try（表达式级 catch 两臂必须同类型）
  let retry = try {
    a.rotate(first.refresh_token) |> ignore
    "没抛"
  } catch {
    err => err.message()
  }
  // 第二轮的新 refresh 仍然可用：被废掉的只有旧的那一对
  let third = a.rotate(second.refresh_token)
  (retry, third.token != second.token)
}

async test "旧 refresh 重放被拒，新 refresh 照常能轮转" {
  let (retry, third_ok) = replay()
  assert_eq(retry, "not login: RefreshInvalid")
  assert_true(third_ok)
}
```

## 3. 关键裁定：**不**校验"绑定的 access 是否还活着"

这是最容易写错的一条。直觉上"refresh 绑着某枚 access，那枚 access 都没了，凭什么让我续"很有道理，
实践里它是个必现缺陷：

- access 时效短（默认 6h），refresh 时效长（默认 30d）。
- 用户闲置超过 access 时效是**常态**，而且恰恰是 refresh 唯一该工作的场景——跨闲置空档续命。
- 加上这条校验，等于把 refresh 的主要用途判死：闲置一晚，第二天必然被误杀成"请重新登录"。

反过来，这条校验对"防重放"是**冗余**的：登出/踢人/封禁的注销漏斗已经联动删掉 `R:` 键，
原子取删本来就取不到，防护一点没少。

```moonbit
async fn survives_idle_gap() -> String raise {
  let a = auth()
  let first = a.login("u3", device="pc")
  // 闲置 7 小时：access 自然过期
  let cell = @port.now_ms() + a.config.timeout_ms() + 1000L
  @port.set_clock(Some(fn() { cell }))
  let access_dead = a.check_login(first.token) catch { err => err.message() }
  let rotated = a.rotate(first.refresh_token)
  @port.set_clock(None)
  access_dead + " → " + a.check_login(rotated.token)
}

async test "access 自然过期后仍能拿 refresh 续命（这正是 refresh 存在的意义）" {
  assert_eq(survives_idle_gap(), "not login: SessionExpired → u3")
}
```

同一枚 token 在轮转前是"过期"，轮转后新 token 是"有效"——两条断言在同一个函数里成立，
就是这条裁定的完整证明。

## 4. 空 refresh 与不存在的 refresh

两者同判 `RefreshInvalid`，不给攻击者区分"存在但已消费"与"从未存在"的信号。

```moonbit
async fn refuse(refresh : String, a : @app.TokenAuth[@mem.MemoryStore, P]) -> String {
  try {
    a.rotate(refresh) |> ignore
    "没抛"
  } catch {
    err => err.message()
  }
}

async fn negative_inputs() -> (String, String) {
  let a = auth()
  (refuse("", a), refuse("never-issued-refresh-token", a))
}

async test "空与伪造同因：都报 RefreshInvalid" {
  let (empty, forged) = negative_inputs()
  assert_eq(empty, "not login: RefreshInvalid")
  assert_eq(forged, "not login: RefreshInvalid")
}
```

## 5. 接在 HTTP 上怎么调

`rotate` 的入参是 refresh，而 refresh **不该**出现在业务请求头里（那是 access 的位置）。
示例服务把它单独挂在一个端点上，用另一个头传：

```text
POST /rotate
X-Refresh-Token: <refresh>
→ {"code":0,"msg":"ok","data":{"token":"…","refresh_token":"…"}}
```

`examples/curl.sh` 的第 [7]–[9] 步就是这条链的真跑读数（换新、旧 access 失效、重放被拒）。
响应码怎么映射见 [错误词汇表](error-vocabulary.md)。

## 6. 三个时效别混

| 配置 | 默认 | 管什么 |
|---|---|---|
| `timeout` | 6h | access 活多久 |
| `remember_timeout` | 30d | "记住我"档的 access 活多久 |
| `refresh_timeout` | 30d | refresh 活多久＝**一次登录最多能续多久**（每次轮转重新计时） |

`rotate` 签出的新 access 走 `timeout`（不继承 remember 档）——长时效档是"这次登录选的就是它"，
不该被一次续命悄悄复制下去。

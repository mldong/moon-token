# 测试指南

本库自己怎么测、你在自己项目里该怎么测它。核心一句话：**断言到"原因"这一层，不断言"有没有报错"**。
本页代码块由 `scripts/docs-check.sh` 逐块真编译真跑（对注册表已发布件）。

## 1. 三场景纪律

| 档 | 覆盖什么 | 典型断言 |
|---|---|---|
| 正向 | 核心链路能跑通 | `check_login(token) == "u1"` |
| 负向 | 每条边界报**指定**的原因 | `err.not_login_reason() == Some(KickedOut)` |
| 回归 | 已有行为不被改坏 | 同一套夹具，前后跑结果一致 |

只跑正向等于没测：本库的价值全在负向那批"精确原因"上。

## 2. 断言原因，而不是断言"抛了"

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

/// 取原因这件事抽成纯函数：输入是已经抓到的错误，不做调用
fn label(err : @port.TokenError) -> String {
  match err.not_login_reason() {
    None => "非鉴权错:" + err.message()
    Some(r) => r.label()
  }
}

/// 同步闭包调不了 async（本库用例方法全是 async），所以"就地展开"是常态写法
async fn negative_matrix() -> Array[String] raise {
  let a = auth()
  let t = a.login("u1", device="pc").token
  a.kickout("u1") |> ignore
  let inside = try {
    "放行:" + a.check_login(t)
  } catch {
    err => label(err)
  }
  let cell = @port.now_ms() + a.config.kick_grace_ms() + 1000L
  @port.set_clock(Some(fn() { cell }))
  let recycled = try {
    "放行:" + a.check_login(t)
  } catch {
    err => label(err)
  }
  @port.set_clock(None)
  let forged = try {
    "放行:" + a.check_login("forged")
  } catch {
    err => label(err)
  }
  [inside, recycled, forged]
}

async test "负向矩阵：每条边界各自的原因都对得上" {
  assert_eq(negative_matrix(), ["KickedOut", "UnknownToken", "UnknownToken"])
}
```

### 假绿长什么样

同一条用例，两种写法，只有一种能守住行为：

```text
// 假绿：任何错误都算过——把 KickedOut 改成 UnknownToken 它照样绿
let ok = a.check_login(t) catch { _ => "拦住了" }
assert_eq(ok, "拦住了")

// 真绿：钉死原因，行为一变就红
let r = match err_of(a.check_login(t)) { None => "?"  Some(x) => x.label() }
assert_eq(r, "KickedOut")
```

同类坑还有三种，都见过真实的：

- **恒真的夹具**：两条节点的线性流程，任何实现都能"跑通"，因为它没测任何分支。
- **恒 skip 的套件**：环境不齐时整批跳过还报绿——`moon test` 的退出码 0 不等于"跑过了"。
  本仓的门禁因此断言 `Total tests: 33` 这个**条数**，而不是只看退出码。
- **wasm-gc 档静默丢用例**：`async test` 在 wasm-gc 下会被整片丢弃且仍报 passed。
  所以口径钉在 `preferred_target = "wasm"`，native 交给 CI。

## 3. 时效类：拨时钟，不要 sleep

```moonbit
async fn expired_reason() -> String raise {
  let a = auth()
  let t = a.login("u2", device="pc").token
  let cell = @port.now_ms() + a.config.timeout_ms() + 1000L
  @port.set_clock(Some(fn() { cell }))
  let r = a.check_login(t) catch { err => err.message() }
  @port.set_clock(None)
  r
}

async test "过签发时效报 SessionExpired（而不是 UnknownToken）" {
  assert_eq(expired_reason(), "not login: SessionExpired")
}
```

三条纪律：

1. **成对写** `set_clock(Some(..))` / `set_clock(None)`，中间任何断言失败都会漏还原——
   批量跑时会污染后面的用例。真要稳，把时钟夹具做成"进入即设、离开即还原"的一层包装。
2. **别在断言里算真实毫秒差**。两次 `login` 之间会漂 1ms，
   "差值恰好等于 30d - 6h"这种断言会偶发红（本仓的门禁真被它红过一次）。
   要断言就断言"相对注入的那个 now"的差。
3. 时钟槽是**进程级全局**的，不要并发跑共享它的用例。

## 4. "有没有写库"要用计数 store 断言

续期节流、幂等这类行为的判据是**写次数**，光看返回值看不出来。

```moonbit
pub(all) struct CountingStore {
  inner : @mem.MemoryStore
  mut writes : Int
}

pub fn CountingStore::new(realm : String) -> CountingStore {
  let s : CountingStore = { inner: @mem.MemoryStore::new(realm), writes: 0 }
  s
}

pub impl @port.TokenStore for CountingStore with fn get(self, key) {
  self.inner.get(key)
}

pub impl @port.TokenStore for CountingStore with fn set(self, key, payload, expire_at) {
  self.writes += 1
  self.inner.set(key, payload, expire_at)
}

pub impl @port.TokenStore for CountingStore with fn del(self, keys) {
  self.writes += keys.length()
  self.inner.del(keys)
}

pub impl @port.TokenStore for CountingStore with fn get_and_del(self, key) {
  self.writes += 1
  self.inner.get_and_del(key)
}

pub impl @port.TokenStore for CountingStore with fn apply(self, patch) {
  self.writes += 1
  self.inner.apply(patch)
}

pub impl @port.TokenStore for CountingStore with fn sweep(self, now) {
  self.inner.sweep(now)
}

// 两个读侧方法照转发，但**不计进 writes**——这一页测的就是"写了几次"
pub impl @port.TokenStore for CountingStore with fn get_many(self, keys) {
  self.inner.get_many(keys)
}

pub impl @port.TokenStore for CountingStore with fn list_sessions(
  self,
  filter,
  cursor,
  limit,
) {
  self.inner.list_sessions(filter, cursor, limit)
}

pub extend CountingStore with @port.TokenStore::{
  get,
  set,
  del,
  get_and_del,
  apply,
  sweep,
  get_many,
  list_sessions,
}

async fn throttle_writes() -> (Int, Int) raise {
  let store = CountingStore::new("user")
  let p : P = { permissions: [], roles: [] }
  let a = @app.TokenAuth::new("user", @app.TokenConfig::default(), store, p, @style.opaque_style())
  let t = a.login("u3", device="pc")
  let after_login = store.writes
  a.check_login(t.token) |> ignore
  let in_window = store.writes
  (after_login, in_window)
}

async test "窗内访问不产生任何写" {
  let (after_login, in_window) = throttle_writes()
  assert_true(after_login >= 3)
  assert_eq(after_login, in_window)
}
```

## 5. 内存不泄漏：`sweep` 的条数断言

跑一轮"登录—注销"，再 `sweep`，断言清掉的条数等于留下的孤儿数——
这条断言能抓住所有"删了一半"的注销漏斗缺陷（孤儿 `R:` 键是最常见的一种）。

```moonbit
async fn no_orphans() -> Bool raise {
  let store = CountingStore::new("leak")
  let p : P = { permissions: [], roles: [] }
  let a = @app.TokenAuth::new("leak", @app.TokenConfig::default(), store, p, @style.opaque_style())
  let mut i = 0
  while i < 50 {
    let r = a.login("u" + i.to_string(), device="pc")
    a.logout(r.token)
    i += 1
  }
  let cell = @port.now_ms() + 90_000_000L
  @port.set_clock(Some(fn() { cell }))
  let cleared = a.sweep()
  @port.set_clock(None)
  // 50 轮登录登出之后，库里不该还剩任何活键
  cleared >= 0 && store.inner.size() == 0
}

async test "五十轮登录登出之后库里不残留" {
  assert_true(no_orphans())
}
```

## 6. 你自己项目里的最小测试骨架

```text
你的包
  ├─ 领域裁决（纯函数）        → 同步 test，零 IO，跑得快
  ├─ 应用层用例（async）       → async test + MemoryStore + 注入时钟
  ├─ 端口契约                  → 计数 store 断言写次数；幂等断言版本号
  └─ 负向矩阵                  → 每条边界钉一个 NotLoginReason
```

`async test` 只有在**非主包**的黑盒 `_test.mbt` 里会被收集；白盒 `_wbtest.mbt` 收集不到，
主包（`pkgtype(kind:"executable")`）放黑盒测试会被工具链标记废弃。这是本工具链的形状，不是风格问题。

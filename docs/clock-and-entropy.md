# 时钟与熵源

这两件事是同一类问题的两面：**"什么时候到期"要能被拨动，"token 从哪来"要能被交代**。
两者都不给静默默认——宁可响亮失败，也不要签出一枚可预测的 token。

本页代码块由 `scripts/docs-check.sh` 逐块真编译真跑（对注册表已发布件）。

## 1. 时钟槽：一个环境端口

core 里没有 time 包，全库唯一的时间源是 `@port.now_ms()`，它读一个可注入的槽：

```moonbit
test "不注入时读真实时钟，注入后读我们给的" {
  assert_true(@port.now_ms() > 1_700_000_000_000L)
  let cell = 1_000L
  @port.set_clock(Some(fn() { cell }))
  assert_eq(@port.now_ms(), 1000L)
  // None 是"还原"，不是"设成 0"
  @port.set_clock(None)
  assert_true(@port.now_ms() > 1_700_000_000_000L)
}
```

两点要记住：

- 这是**进程级全局槽**。忘了还原的典型症状是"这条测试单独跑绿、整批跑红"——
  上一个用例把时钟钉在了 1970 年。
- 时钟闭包是同步的，所以**异步调用不能塞进时钟闭包**；反过来，要在异步流程里拨时钟，
  就在使用它的那个 `async fn` 里把 `set_clock` / `set_clock(None)` 成对写。

## 2. 为什么必须有它

本库有一整类特性是"时间到了才成立"的：

| 特性 | 判据 | 不注入时钟的代价 |
|---|---|---|
| 签发时效 `timeout` | `now > expire_at` | 真等 6 小时 |
| 活跃时效 `active_timeout` | `now - last_active > 阈值` | 真等 5 分钟起 |
| 踢人保留宽窗 `kick_grace` | 墓碑过了 `deadline` 才回收 | 真等 5 分钟，且窗内外两种原因要各等一次 |
| 续期节流 `renew_min_interval` | 出窗才前推到期点 | 真等 60 秒，且"窗内不写库"测不准 |
| refresh 到期 | `R:` 键 TTL | 真等 30 天 |

所以时钟槽不是"方便测试的小机关"，是这些用例**能被测出来、也能被演出来**的前提。
同类生态里有过教训：时效不可注入就只能 `sleep`，于是 CI 偶发红、本地永远绿。

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
  let p : P = { permissions: [], roles: [] }
  @app.TokenAuth::new("user", @app.TokenConfig::default(), @mem.MemoryStore::new("user"), p, @style.opaque_style())
}

async fn grace_window() -> (String, String) raise {
  let a = auth()
  let t = a.login("u1", device="pc").token
  a.kickout("u1") |> ignore
  let inside = a.check_login(t) catch { err => err.message() }
  let cell = @port.now_ms() + a.config.kick_grace_ms() + 1000L
  @port.set_clock(Some(fn() { cell }))
  let after = a.check_login(t) catch { err => err.message() }
  @port.set_clock(None)
  (inside, after)
}

async test "宽窗内是被踢，窗外是查无此枚：两个原因都测得到" {
  let (inside, after) = grace_window()
  assert_eq(inside, "not login: KickedOut")
  assert_eq(after, "not login: UnknownToken")
}
```

## 3. 熵源：三个入口，一个都不静默

token 是 **bearer 凭证**——拿到 token 就等于拿到身份。所以"token 可不可预测"是安全问题，
不是实现细节。本库把选择权交给调用方：

| 入口 | 熵从哪来 | 什么时候用 |
|---|---|---|
| `opaque_style()` | **平台熵源** | 默认。wasm / Linux native / macOS native 直接用它 |
| `opaque_style_with_seed(seed)` | 你给的 32 字节 | 测试与夹具：同种子必出同序列，可复现 |
| `opaque_style_with(entropy)` | 你的 CSPRNG（须给 32 字节） | 宿主自带熵源、HSM，或平台熵源拿不到的环境（如 wasm-gc） |

三档产出**形状一致**：默认 40 字符、小写 base32 字符集（`a-z` + `0-9`）；
长度可配（`opaque_style(len=...)`，内部按熵字节数换算，不是截断）。

```moonbit
test "同种子必出同序列：可复现档是给测试用的" {
  let seed = b"0123456789abcdef0123456789abcdef"
  let same = @style.opaque_style_with_seed(b"0123456789abcdef0123456789abcdef")
  let other = @style.opaque_style_with_seed(b"fedcba9876543210fedcba9876543210")
  let a = @style.opaque_style_with_seed(seed)
  assert_eq((a.generate)(), (same.generate)())
  assert_true((a.generate)() != (other.generate)())
}

test "形状：40 字符，且 verify_shape 认得出来" {
  let style = @style.opaque_style()
  let t = (style.generate)()
  assert_eq(t.length(), 40)
  assert_true((style.verify_shape)(t))
  assert_false((style.verify_shape)("too-short"))
  // 字符集合法但长度不对，一样不认
  assert_false((style.verify_shape)(t + "x"))
}
```

宿主自带熵源那一档，给字节的闭包长这样：

```moonbit
test "opaque_style_with：宿主给 32 字节，两次签发不同" {
  let seeds = [b"0123456789abcdef0123456789abcdef", b"fedcba9876543210fedcba9876543210"]
  let mut taken = 0
  let style = @style.opaque_style_with(fn() {
    let s = seeds[taken]
    taken += 1
    s
  })
  let first = (style.generate)()
  let second = (style.generate)()
  assert_eq(first.length(), 40)
  assert_true(first != second)
}
```

## 4. 拿不到平台熵会怎样

`opaque_style()` 的第一步是 `require_platform_entropy()`：**拿不到就 `abort`，绝不静默回落到固定种子**。
这条是刻意的——静默回落意味着"生产环境签出的 token 全一样"，那是要出安全事故的事。

实测分档：

| 目标档 | 平台熵 | 该用哪个入口 |
|---|---|---|
| `wasm` | 有 | `opaque_style()` |
| `wasm-gc` | **无**（`Rand::new()` 会静默回落到硬编码种子） | `opaque_style_with_seed` / `opaque_style_with` |
| native（Linux/macOS） | 有 | `opaque_style()` |
| native（Windows） | 需要 MSVC 运行库（`rand_s`）；只有 MinGW 时拿不到 | 同上，或换宿主 |

所以本仓的开发/CI 口径是 `preferred_target = "wasm"`：既跑得动 async，也拿得到真熵。
要在 wasm-gc 上部署，请显式选后两个入口——**这是宿主的决定，不是库该替你做的默认**。

## 5. 随机流是什么

内部用 **ChaCha8**（8 轮变体）作确定性扩展函数，把 32 字节种子扩成一串 token。
本库**不宣称**它等同 ChaCha20 的强度；它承担的是两件事：给定种子可复现、不给种子不可预测。
要接你自己的 CSPRNG，用 `opaque_style_with`，别改库。

## 6. 能不能拿 `moonbitlang/x` 的时间包当内置时钟？

**不能当时间源，可以当"读法"。** 实测结论（工具链同版本，`moonbitlang/x@0.5.5`）：

- `x/time` 里**没有读当前时间的入口**：`@time.Time` 这个类型不存在（编译器直接报
  `The type/trait @time.Time is not found`），整个包的公开接口里 `now` 命中 0 处；`x/sys` 也没有。
  它是日历 / 时区 / 时长**格式化**库（`PlainDate` / `ZonedDateTime` / `Duration` / 解析与算术），不是时钟。
- core 侧同样没有 `time` / `sys` 包。跨档唯一可用的时间源仍是 `@env.now()`（`UInt64` 毫秒）——
  这就是本库自己带 `Duration` 值对象、并把时间收敛到一个可注入槽的原因。

它的正当用武之地是**展示层**：把库里的绝对毫秒换成人类可读时刻，实测可用——

```text
@time.ZonedDateTime::from_unix_second(ms / 1000L, nanosecond=(ms % 1000L).to_int())
→ 2026-10-01T23:47:25.459Z
```

但**不建议把它引进 core/store**，三条理由：

1. 破 v1 红线"零第三方运行时依赖"（目前只依赖官方 `moonbitlang/async`）。
2. `Duration` 是**契约的一部分**：`TokenConfig` 八个字段与 `TokenStore` 的签名都在用它。
   换成 `x/time.Duration` 会把这个依赖传染给 v2 的每一个后端实现。
3. `x/time` 的 `Duration::of(hours?, minutes?, seconds?, nanoseconds?)` **没有毫秒构造器**，
   而本库的默认值恰好是 6h / 30d / 60s / 5min 这类"毫秒整数"语义——换过去只会更绕。

结论：时间源保持现状（`@env.now()` + 可注入槽）；要给用户看"几点几分过期"，
在你的展示层引 `moonbitlang/x` 换算即可，库不掺和。

## 7. 两句话总结

- 时效类断言一律注入时钟、测完还原；不要 `sleep`，也不要在断言里算真实毫秒差（会漂 1ms 偶发红）。
- 生产环境请说得出你的 token 是从哪个入口来的。答不上来，就把 `opaque_style()` 的 `abort` 当成它在帮你。

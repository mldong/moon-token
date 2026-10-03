# 领域事件

事件是**已经发生的事实**，不是"请求你去做什么"。本库的事件模型三条硬规矩：

1. **落库之后才 fire**——订阅方看到的永远是已生效的状态，不会读到"登录了一半"。
2. **码粗、载荷细**——事件类型只到"发生了什么事实"，细节在载荷里（login_id / device / token / at）。
3. **观察者异常不带崩主流程**——`fire` 逐条吞异常。订阅方炸了是订阅方的问题。

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

/// 收集器：结构体是引用语义，闭包里 push 进去的东西外面看得见
pub(all) struct Sink {
  lines : Array[String]
}

fn sink_auth() -> (@app.TokenAuth[@mem.MemoryStore, P], Sink) {
  let p : P = { permissions: ["user:info"], roles: ["demo"] }
  let a = @app.TokenAuth::new("user", @app.TokenConfig::default(), @mem.MemoryStore::new("user"), p, @style.opaque_style())
  let sink : Sink = { lines: [] }
  a.on_event(ev => sink.lines.push(
    "\{ev.event_type.code()} \{ev.event_type.name()} \{ev.login_id}/\{ev.device}",
  ))
  (a, sink)
}
```

## 1. 七个事实

| 码 | 类型 | 什么时候发 |
|---|---|---|
| 1 | `LoggedIn` | 签发（或 `Shared` 复用）成功、三处写库之后 |
| 2 | `LoggedOut` | 注销漏斗走完（`T:` 删 + 族摘 + `R:` 联动删） |
| 3 | `Kicked` | 被踢，落墓碑 |
| 4 | `Superseded` | 被顶（`Supersede` 策略下旧会话自动落墓碑，或被显式 `supersede`） |
| 5 | `Disabled` | 账号被封禁 |
| 6 | `Enabled` | 封禁被解除 |
| 7 | `Refreshed` | `rotate` 换新完成 |

码值 10+ 是**预留不发的号段**：先占号，将来加事实时不必改已有码，
订阅方（尤其是别的团队写死的 `match`）不会被一次升级打穿。

```moonbit
async fn seven_facts() -> Array[String] raise {
  let (a, sink) = sink_auth()
  a.login("u1", device="pc") |> ignore
  a.kickout("u1", device="pc") |> ignore
  let second = a.login("u1", device="pc")
  a.logout(second.token)
  a.disable("u1", @port.Duration::from_minutes(5L), reason="audit")
  a.undo_disable("u1")
  let third = a.login("u1", device="pad")
  a.rotate(third.refresh_token) |> ignore
  sink.lines
}

async test "七种事实各来一次（登录发生了三次，所以共 8 条）" {
  let lines = seven_facts()
  assert_eq(lines.length(), 8)
  assert_eq(lines[0], "1 TOKEN_LOGGED_IN u1/pc")
  assert_eq(lines[1], "3 TOKEN_KICKED u1/")
  assert_eq(lines[2], "1 TOKEN_LOGGED_IN u1/pc")
  assert_eq(lines[3], "2 TOKEN_LOGGED_OUT u1/pc")
  assert_eq(lines[4], "5 TOKEN_DISABLED u1/")
  assert_eq(lines[5], "6 TOKEN_ENABLED u1/")
  assert_eq(lines[6], "1 TOKEN_LOGGED_IN u1/pad")
  assert_eq(lines[7], "7 TOKEN_REFRESHED u1/pad")
}
```

> `Kicked` / `Disabled` / `Enabled` 的载荷里 `device` 是空串：这三件事的作用域是**账号**
> （`kickout` 不带 device 时踢全部），把"最后一个设备名"填进去会是假信息。
> 注销那条带 device，是因为 `logout` 本来就是按一枚 token 发生的。

## 2. 观察者炸了，业务照旧

```moonbit
async fn boom_listener() -> String raise {
  let (a, sink) = sink_auth()
  // 第二条观察者总是抛错；第一条照常记账
  a.on_event(_ev => raise @port.Store("这条观察者总是抛错"))
  let token = a.login("u2", device="pc").token
  token.length().to_string() + "/" + sink.lines.length().to_string() + "/" + a.listener_count().to_string()
}

async test "两条观察者，一条总抛错：登录照样成功，事件照样记上" {
  assert_eq(boom_listener(), "40/1/2")
}
```

顺序也有讲究：第一条先记成功、第二条抛错，`fire` 逐条吞，所以第一条的效果留着。
**不要**指望"抛错能回滚这次登录"——事件是通知，不是事务参与者。

## 3. 落库后才 fire：为什么这条不能让步

如果 `login` 先 fire 再写库，订阅方（审计、在线人数、消息推送）拿着 `login_id` 反查会话，
会读到一个还不存在的 `T:` 键——这种"偶发的查不到"极难排查。

```moonbit
async fn fired_after_commit() -> String raise {
  let (a, _sink) = sink_auth()
  let seen : Sink = { lines: [] }
  a.on_event(ev => seen.lines.push(ev.token))
  let token = a.login("u3", device="pc").token
  // ① 观察者是在主流程里同步跑完的：login 返回时它已经记下一条，且记的就是这枚 token
  let fired = seen.lines.length() == 1 && seen.lines[0] == token
  // ② 而此刻这枚 token 在库里读得到 ⇒ 事件发在落库**之后**，不是之前
  let readable = a.is_login(token)
  (if fired && readable { "先落库、后通知" } else { "顺序不对" }) +
    "/" + (seen.lines.length()).to_string()
}

async test "观察者里回查得到刚写进去的会话" {
  assert_eq(fired_after_commit(), "先落库、后通知/1")
}
```

**监听器是同步闭包，里面调不了 async**（`is_login` 这类回查都是 async）。
所以订阅方要么只做纯内存的记账/投递，要么把事件塞进自己的队列再异步处理——
这也正是"事件是通知、不是事务参与者"的另一面。

## 4. 怎么用它

| 场景 | 订阅方做什么 |
|---|---|
| 审计流水 | 把 `(码, login_id, device, at)` 追加进审计表 |
| 在线人数看板 | `LoggedIn` +1、`LoggedOut`/`Kicked`/`Superseded` −1 |
| 异地登录提醒 | 订阅 `LoggedIn`，比对 device/来源 |
| 缓存失效 | 订阅 `Disabled` / `Enabled` / `Kicked`，清掉该账号的派生缓存 |

要"拦截"某个动作（比如禁止登录）不要靠事件——那是策略，属于并发配置与封禁，
事件只负责告诉你发生了什么。

## 5. 接线形状

`on_event` 收的是 `(TokenEvent) -> Unit raise`，**同步**闭包。
异步的订阅方（要发 HTTP、写库）在自己的实现里把任务投进队列，别指望在监听器里 `await`——
`EventHub` 的订阅表是同步的，这是"零依赖、零运行时假设"的代价。

```moonbit
test "事件类型自带码与名" {
  assert_eq(@event.LoggedIn.code(), 1)
  assert_eq(@event.Refreshed.name(), "TOKEN_REFRESHED")
}
```

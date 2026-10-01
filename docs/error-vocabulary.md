# 错误词汇表

本库的错误模型是一等公民：**"没登录"不是一种错误，是七种**。
把它们塌成一句"未登录"，前端就没法区分"该跳登录页"和"你的账号在别处登录了"。

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
```

## 1. 七种未登录原因

| `NotLoginReason` | 什么时候给 | 前端该做什么 |
|---|---|---|
| `AbsentToken` | 头里没有 token（或配了 `token_prefix` 而头的格式不对） | **接线错了**，不是用户的问题：查中间件/查前缀配置 |
| `UnknownToken` | 拿到了但库里查无此枚（伪造、已注销、墓碑过了保留窗） | 清本地 token，跳登录页 |
| `SessionExpired` | 会话存在，只是过了签发时效 | 有 refresh 就先静默轮转，失败再跳登录 |
| `ActiveTimeout` | 闲置过了 `active_timeout`（`IdleMark` 模式） | 提示"超时请重新登录"，属预期 |
| `KickedOut` | 被管理端/别处踢下线 | 提示"您已被踢下线"，并给一个"知道了" |
| `SupersededByLogin` | 同账号在别处登录把它顶了 | 提示"账号在其它设备登录" |
| `RefreshInvalid` | refresh 为空、不存在、或已被消费（重放） | 整对作废，必须重登 |

区分 `AbsentToken` 与 `UnknownToken` 特别值钱：前者是**部署/接线问题**，
线上突然大量出现说明有客户端或网关把头弄丢了；后者才是用户态问题。

## 2. 五类错误

| 变体 | 载荷 | `message()` 形状 |
|---|---|---|
| `NotLogin(reason)` | 上面七种之一 | `not login: KickedOut` |
| `NotPermission(missing)` | **缺的那一项** | `no permission: order:read` |
| `NotRole(missing)` | 缺的那个角色 | `no role: admin` |
| `Disabled(reason, until)` | 封禁原因 + 到期时刻 | `disabled until 1790…: 风控命中` |
| `InvalidInput(msg)` | 调用方写错了（空 login_id、空属性键…） | `invalid input: login_id must not be empty` |
| `Store(msg)` | 后端 IO 失败（内存档永不触发） | `store error: …` |

## 3. 精确断言：别只断言"报错了"

`message()` 给人看，`not_login_reason()` 给断言用。

```moonbit
fn label_of(v : Result[String, @port.TokenError]) -> String {
  match v {
    Ok(_) => "放行"
    Err(err) => match err.not_login_reason() {
      None => "非鉴权错:" + err.message()
      Some(r) => r.label()
    }
  }
}

/// 每个动作各自包成 Result：取原因这件事只有一处实现，断言才有可比性
async fn seven_reasons() -> Array[String] {
  let a = auth()
  let t = a.login("u1", device="pc").token
  let absent = try {
    Ok(a.check_login(""))
  } catch {
    err => Err(err)
  }
  let forged = try {
    Ok(a.check_login("forged-token-value"))
  } catch {
    err => Err(err)
  }
  a.kickout("u1") |> ignore
  let kicked = try {
    Ok(a.check_login(t))
  } catch {
    err => Err(err)
  }
  let replay = try {
    // rotate 成功时给 LoginResult，这里只要"有没有抛"，所以先丢返回值再给 Ok
    a.rotate("never-issued") |> ignore
    Ok("不该放行")
  } catch {
    err => Err(err)
  }
  [label_of(absent), label_of(forged), label_of(kicked), label_of(replay)]
}

async test "四种输入四种原因，逐条取得出来" {
  assert_eq(seven_reasons(), ["AbsentToken", "UnknownToken", "KickedOut", "RefreshInvalid"])
}
```

## 3.1 被踢方拿到的是墓碑原因

```moonbit
async fn kicked_reason() -> String raise {
  let a = auth()
  let t = a.login("u2", device="pc").token
  a.kickout("u2") |> ignore
  let err = try {
    a.check_login(t) |> ignore
    @port.NotLogin(@port.AbsentToken)
  } catch {
    err => err
  }
  match err.not_login_reason() {
    None => "不是鉴权错"
    Some(r) => r.label() + "/code=" + r.code().to_string()
  }
}

async test "被踢方拿到 KickedOut，码值稳定" {
  assert_eq(kicked_reason(), "KickedOut/code=5")
}
```

## 4. 映射成响应码：库不规定，但给个建议表

`TokenError` 是**领域错误**，不带 HTTP 语义；防腐层（v2 的 `moon-token-web`）负责映射。
建议一张表钉死，别让每个 controller 自己发明：

| 原因 | HTTP | 应用码建议 | 用户可见文案 |
|---|---|---|---|
| `AbsentToken` / `UnknownToken` / `RefreshInvalid` | 401 | 未登录族 | 请重新登录 |
| `SessionExpired` / `ActiveTimeout` | 401 | 时效族 | 登录已过期 |
| `KickedOut` / `SupersededByLogin` | 401 | 互斥族 | 账号在别处登录 |
| `NotPermission` / `NotRole` | 403 | 权限族 | 无权限（带缺的那项） |
| `Disabled` | 403 | 封禁族 | 封禁原因 + 到期时刻 |
| `InvalidInput` | 400 | 调用方错误 | 不该出现在正常用户路径 |
| `Store` | 500 | 后端失败 | 内部错误，附 trace |

三件"族"分开是有意义的：客服看到"未登录族"和"互斥族"的处理动作完全不同。
应用码具体取值随各家框架的既有约定走，本库不置可否。

## 5. 三条反模式

1. **`x catch { _ => false }` 一口吞**：把"该跳登录页"吞成"无权限"，用户会卡在原地。
2. **只记 `err.message()` 不记原因码**：日志里全是"not login"，永远查不出是宽窗回收还是伪造。
3. **给 `Disabled` 回 401**：封禁是**授权**问题不是**认证**问题，回 401 会让客户端去做无意义的重登循环。

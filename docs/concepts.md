# 核心概念

这页只讲五件事：`realm`、一整对 token、反查族、双层时效、五种键位。
把它们对上，后面所有 API 的形状都不言自明；对不上，就会觉得本库"一个登录怎么这么多名词"。

本页每个 `moonbit` 块都由 `scripts/docs-check.sh` 真编译真跑过（对注册表已发布件），可以照抄。

## 1. realm：一个账号体系一个实例

`realm` 是**实例级**的隔离维度，不是参数级的开关。库把 realm 拼进每一个键的前缀，
所以 `user` 体系签发的 token 拿到 `admin` 体系的实例上必然查无此枚。

```moonbit
fn auth_of(realm : String) -> @app.TokenAuth[@mem.MemoryStore, EmptyPerms] {
  @app.TokenAuth::new(
    realm,
    @app.TokenConfig::default(),
    @mem.MemoryStore::new(realm),
    { permissions: [], roles: [] },
    @style.opaque_style(),
  )
}

async fn realm_isolation() -> Bool raise {
  let user = auth_of("user")
  let admin = auth_of("admin")
  let token = user.login("root", device="pc").token
  // 同一枚 token，两个体系里一个有效一个查无此人
  let in_user = user.is_login(token)
  let in_admin = admin.is_login(token)
  in_user && !in_admin
}

async test "realm 前缀隔离：跨体系不认账" {
  assert_true(realm_isolation())
}
```

`EmptyPerms` 是本页用的最小权限实现（没有任何权限，只把端口填上）：

```moonbit
pub(all) struct EmptyPerms {
  permissions : Array[String]
  roles : Array[String]
}

pub impl @port.PermissionProvider for EmptyPerms with fn get_permissions(
  self,
  _login_id,
  _device,
) {
  self.permissions
}

pub impl @port.PermissionProvider for EmptyPerms with fn get_roles(
  self,
  _login_id,
  _device,
) {
  self.roles
}

pub extend EmptyPerms with @port.PermissionProvider::{get_permissions, get_roles}
```

> 一个进程里放几个 realm 都行，它们互不干扰；但**同一个 realm 请只建一个 `TokenAuth` 实例**——
> 实例本身无状态，状态全在 `store` 里，两个实例共用两个 store 才会看到彼此看不见的会话。

## 2. 一整对 token：access 与 refresh

`login` 一次签发两枚：

- **access**：走 `Authorization` 头，短时效（默认 6h），每次访问可被滑动续期。
- **refresh**：不出现在请求头里，客户端存着，只用来调 `rotate` 换新整对。

两枚在服务端各占一键（`R:` 键存着它绑定的 access），所以"旧 refresh 再拿来用"能被精确拒绝。

```moonbit
async fn pair_shape() -> String raise {
  let auth = auth_of("user")
  let first = auth.login("u1", device="pc")
  let second = auth.rotate(first.refresh_token)
  // 全量轮转：整对换新，旧 access 当场作废
  let old_access_dead = !auth.is_login(first.token)
  let new_access_alive = auth.is_login(second.token)
  // 注意形状：`expr catch { }` 的两个臂必须同类型，所以这里用块式 try 把"成功"那一支也写成 Bool
  let replay_refused = try {
    auth.rotate(first.refresh_token) |> ignore
    false
  } catch {
    err => err.message().contains("RefreshInvalid")
  }
  "旧 access 作废=" + old_access_dead.to_string() +
    " 新 access 有效=" + new_access_alive.to_string() +
    " 旧 refresh 重放被拒=" + replay_refused.to_string()
}

async test "轮转后三件事同时成立" {
  assert_eq(
    pair_shape(),
    "旧 access 作废=true 新 access 有效=true 旧 refresh 重放被拒=true",
  )
}
```

## 3. 反查族：`login_id → token 集合`

只有 `token → login_id` 的正查，做不了"把某人踢下线"——那需要反方向。
库为每个 `login_id` 维护一个**反查族**（`A:` 键），成员是 `(device, token, expire_at)`，带一个递增的 `version`。

三件依赖它的事才因此成立：

| 能力 | 靠族里的什么 |
|---|---|
| 踢人 / 顶人 / 按账号注销 | 拿到该账号当前所有 token，逐个落墓碑或删键 |
| 在线列表、设备列表 | 遍历成员，再回 `T:` 键核对状态与时效（族里的过期成员不算在线） |
| `Shared` 策略复用 token | 按 `device` 在族里找同设备的既有会话 |

```moonbit
async fn family_shape() -> String raise {
  let auth = auth_of("user")
  auth.login("u2", device="pc") |> ignore
  auth.login("u2", device="phone") |> ignore
  let online = auth.get_token_list_by_login_id("u2")
  let devices = auth.get_device_list("u2")
  auth.kickout("u2", device="pc") |> ignore
  // 踢掉 pc 之后：在线只剩 phone，设备列表也跟着缩
  online.length().to_string() + "/" + devices.join(",") + " → " +
    (auth.get_device_list("u2")).join(",")
}

async test "反查族支撑在线列表与踢人" {
  assert_eq(family_shape(), "2/pc,phone → phone")
}
```

## 4. 双层时效：签发时效与活跃时效

两把独立的尺子，判据不同、目的不同：

| 层 | 配置项 | 默认 | 判什么 |
|---|---|---|---|
| 签发时效 | `timeout` / `remember_timeout` | 6h / 30d | 这枚 token **活多久**（绝对到期时刻） |
| 活跃时效 | `active_timeout` | 不限（0） | 这枚 token **多久没动**就该失效 |

`renewal` 决定访问时怎么对待这两把尺子：

- `SlideOnAccess`（默认）：每次访问把到期点往前推，但受 `renew_min_interval`（默认 60s）节流——
  窗内不写库。没有这层节流，"滑动续期"就等于每个请求一次写库。
- `IdleMark`：只记最后活跃时刻，闲置过 `active_timeout` 即拒，**不看签发时效**。

```moonbit
async fn two_clocks() -> String raise {
  let auth = auth_of("user")
  let token = auth.login("u3", device="pc").token
  // 拨快 7 小时：过了 6h 的签发时效
  let later = @port.now_ms() + 7L * 3_600_000L
  let cell = later
  @port.set_clock(Some(fn() { cell }))
  let reason = auth.check_login(token) catch {
    err => err.message()
  }
  @port.set_clock(None)
  reason
}

async test "过签发时效报 SessionExpired 而不是含糊未登录" {
  assert_true(two_clocks().contains("SessionExpired"))
}
```

时效类判定一律走可注入时钟 `@port.now_ms()`，所以"过期"这件事能被测出来、也能被演出来，
不需要真等六小时。用法见 [时钟与熵源](clock-and-entropy.md)。

## 5. 五种键位：状态到底存在哪儿

内存档与将来的 Redis/SQL 档共用同一套键位约定（realm 是前缀）：

| 键 | 装什么 | 谁写它 | 谁读它 |
|---|---|---|---|
| `{realm}:T:{token}` | 会话记录：login_id、device、login_time、expire_at、last_active、status、refresh 绑定、extra | 签发 / 续期 / 落墓碑 | 每次鉴权 |
| `{realm}:A:{login_id}` | 反查族：成员 `(device, token, expire_at)` + `version` | `FamilyPatch` 唯一入口 | 踢/顶/在线列表/Shared 复用 |
| `{realm}:R:{refresh}` | refresh → (login_id, device, 绑定的 access) | 签发 | `rotate`（原子取删） |
| `{realm}:S:{login_id}` | 账号级会话属性（跨该账号所有 token 共享的业务附加态） | `update_account_session` | `get_account_session` |
| `{realm}:D:{login_id}` | 封禁记录：`until` + `reason` | `disable` | 每次鉴权与登录 |

两条共同形状，值得单独记住：

1. **`T:` 的过期是分两档的**。载荷还是 Active 会话、只是过了签发时效 ⇒ 读路径**照旧交回载荷**，
   为的是让裁决层报得出 `SessionExpired`；载荷是墓碑（被踢/被顶）且已过保留宽窗 ⇒ 当场回收，读作 `UnknownToken`。
   一刀切惰性删除会把"过期"和"无效"塌成同一个原因，本库的卖点当场失效。
2. **`A:` 是反向索引的唯一写入口**。所有影响族的操作都走 `FamilyPatch`（意图补丁），
   而不是"先 get 再 set"的读改写——后者换后端时就不是原子的了。见 [存储端口](storage-port.md)。

```moonbit
async fn ban_beats_session() -> (String, String, Bool) raise {
  let auth = auth_of("user")
  let token = auth.login("u4", device="pc").token
  let before = auth.check_login(token)
  auth.disable("u4", @port.Duration::from_minutes(30L), reason="风控命中")
  let after = auth.check_login(token) catch {
    err => err.message()
  }
  auth.undo_disable("u4")
  // 封禁优先于"会话本身有效"：会话一行没改，解禁后原样可用
  (before, after, auth.is_login(token))
}

async test "账号级封禁压在会话之上" {
  let (before, after, restored) = ban_beats_session()
  assert_eq(before, "u4")
  assert_true(after.contains("disabled until"))
  assert_true(after.contains("风控命中"))
  assert_true(restored)
}
```

## 6. 这些概念在代码里落在哪

```text
core/domain    TokenSession · AccountFamily      不变量在聚合根方法里
core/policy    decide_concurrent · decide_renewal
               decide_contains · classify_access 纯函数，零 IO、零 async
core/app       TokenAuth                          一个用例一个方法：
                                                  取聚合 → 调领域服务 → 提交补丁 → 发事件
core/guard     RouteGuard · RoutePolicy    纯逻辑，不依赖任何 web 框架
store/port     TokenStore · FamilyPatch · 键位 · 错误词汇表   共享内核
store/memory   MemoryStore                        v1 唯一后端
```

领域裁决是**同步纯函数**是本库最重要的一条分层纪律：所有"该不该放行、该续不该续、
谁被顶掉"的判断都能脱离存储、脱离时钟、脱离 async 单测，`moon test` 里 D 系列用例就是这么跑的。

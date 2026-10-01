///|
/// 剧本剧场：每个剧本在**独立 realm + 独立内存档 + 独立手动时钟**上跑，
/// 逐步给出「调用 → 结果（含精确原因）→ 这一步期间落库写了什么」，末了附一张键位快照。
/// 跑完把站点的时钟装回去，剧本之间与站点主状态互不污染。
///
/// 这里的错误一律往页面上抛（不静默吞）：剧本要演的就是"这一步到底报什么错"。
pub(all) struct Step {
  title : String
  call : String
  outcome : String
  ops : Array[String]
}

///|
pub(all) struct Script {
  name : String
  label : String
  gist : String
  steps : Array[Step]
  keys : Array[KeyRow]
}

///|
fn step(
  title : String,
  call : String,
  outcome : String,
  ops : Array[String],
) -> Step {
  let s : Step = { title, call, outcome, ops, }
  s
}

///|
fn mk(
  name : String,
  label : String,
  gist : String,
  steps : Array[Step],
  keys : Array[KeyRow],
) -> Script {
  let s : Script = { name, label, gist, steps, keys, }
  s
}

///|
fn script_auth(
  realm : String,
  config : @app.TokenConfig,
  events : EventSink,
) -> Auth {
  let auth = @app.TokenAuth::new(
    realm,
    config,
    ObservingStore::new(realm),
    SeedPerms::demo(),
    @style.opaque_style(),
  )
  // 剧本的事件也记进站点那一格：换 backend 也好、写监听器也好，都是同一份流水
  attach_recorder(auth, events)
  auth
}

///|
pub fn scripts_index() -> Array[(String, String, String)] {
  [
    (
      "coexist", "共存不共享（默认）", "同账号两台设备各持一枚有效 token，互不干扰",
    ),
    (
      "shared", "共享 token", "同设备重复登录复用同一枚，不新签",
    ),
    (
      "supersede", "顶人下线", "新登录把既有 token 落成墓碑，被顶方拿到精确原因",
    ),
    (
      "kick", "踢人与保留宽窗", "先 KickedOut，宽窗关上后变 UnknownToken",
    ),
    ("disable", "封禁与解禁", "账号级封禁优先于会话是否有效"),
    (
      "expire", "签发时效", "过 timeout 报 SessionExpired，而不是含糊的未登录",
    ),
    ("idle", "活跃时效", "IdleMark：闲置过阈值判 ActiveTimeout"),
    (
      "rotate", "全量轮转", "整对换新 + 重放防护；access 自然过期后仍能续命",
    ),
    ("throttle", "续期节流", "窗内不写库，出窗才前推到期点"),
    (
      "realm", "多账号体系隔离", "user 的 token 在 admin 体系下不认账",
    ),
    ("perm", "权限/角色 SPI", "业务只供数，AND/OR 裁决在库"),
  ]
}

///|
pub async fn run_script(site : Site, name : String) -> Script {
  let sc = ClockCell::new()
  sc.to_manual()
  let cell = sc
  // 剧本吃自己的手动时钟，跑完把站点的装回去
  @port.set_clock(Some(fn() { cell.now() }))
  let result = dispatch(name, sc, site.events)
  site.install_clock()
  result
}

///|
fn advance(sc : ClockCell, ms : Int64) -> Unit {
  sc.advance(ms)
}

///|
fn bool_text(b : Bool) -> String {
  if b {
    "true（放行）"
  } else {
    "false（拦截）"
  }
}

///|
async fn permission_text(
  auth : Auth,
  token : String,
  required : Array[String],
  mode : @port.MatchMode,
) -> String {
  // 判定本身可能抛（未登录那一档），剧本页要的是把原因画出来
  try {
    bool_text(auth.has_permission(token, required, mode~))
  } catch {
    err => "拦下 → " + err.message()
  }
}

///|
async fn dispatch(name : String, sc : ClockCell, events : EventSink) -> Script {
  let cfg = @app.TokenConfig::default()
  let steps : Array[Step] = []
  if name == "coexist" {
    let auth = script_auth("coexist", cfg, events)
    let a = auth.login("alice", device="pc")
    let b = auth.login("alice", device="mobile")
    steps.push(
      step(
        "两台设备各登录一次",
        "login(alice, pc) ; login(alice, mobile)",
        "两枚不同 token：" + short(a.token) + " / " + short(b.token),
        auth.store.ops_since(0),
      ),
    )
    steps.push(
      step(
        "两枚都仍然有效",
        "check_login(a) ; check_login(b)",
        reason_text(auth, a.token) + "　｜　" + reason_text(auth, b.token),
        [],
      ),
    )
    steps.push(
      step(
        "反查族把两枚收进同一个族",
        "get_token_list_by_login_id(alice) ; get_device_list(alice)",
        online_count(auth, "alice").to_string() +
        " 个在线会话，设备：" +
        auth.get_device_list("alice").join(", "),
        [],
      ),
    )
    mk(
      name,
      "共存不共享",
      "默认策略 ConcurrentPolicy::Coexist：同账号多设备互不干扰",
      steps,
      auth.store.dump(),
    )
  } else if name == "shared" {
    let c = @app.TokenConfig::default()
    c.concurrent = @port.Shared
    let auth = script_auth("shared", c, events)
    let first = auth.login("bob", device="pc")
    let second = auth.login("bob", device="pc")
    steps.push(
      step(
        "同设备重复登录",
        "login(bob, pc) ; login(bob, pc)　policy=Shared",
        if first.token == second.token {
          "复用同一枚 token：" +
          short(second.token) +
          "（没有新签）"
        } else {
          "意外签了新 token：" + short(second.token)
        },
        auth.store.ops_since(0),
      ),
    )
    let before = auth.store.ops_len()
    let phone = auth.login("bob", device="phone")
    steps.push(
      step(
        "换设备才另签",
        "login(bob, phone)",
        "新 token " + short(phone.token),
        auth.store.ops_since(before),
      ),
    )
    mk(
      name,
      "共享 token",
      "同 realm 同 device 共享一枚；换设备另签",
      steps,
      auth.store.dump(),
    )
  } else if name == "supersede" {
    let c = @app.TokenConfig::default()
    c.concurrent = @port.Supersede
    let auth = script_auth("supersede", c, events)
    let old = auth.login("carol", device="pc")
    let before = auth.store.ops_len()
    let fresh = auth.login("carol", device="phone")
    steps.push(
      step(
        "再次登录顶掉旧会话",
        "login(carol, phone)　policy=Supersede",
        "新 token " +
        short(fresh.token) +
        "；旧 token 未删键，只落成墓碑",
        auth.store.ops_since(before),
      ),
    )
    steps.push(
      step(
        "旧 token 再拿来用",
        "check_login(旧 token)",
        reason_text(auth, old.token),
        [],
      ),
    )
    mk(
      name,
      "顶人下线",
      "被顶方拿到 SupersededByLogin，而不是含糊的一句「未登录」",
      steps,
      auth.store.dump(),
    )
  } else if name == "kick" {
    let auth = script_auth("kick", cfg, events)
    let login = auth.login("dave", device="pc")
    let before = auth.store.ops_len()
    let n = auth.kickout("dave")
    steps.push(
      step(
        "踢下线（不删键，先落墓碑）",
        "kickout(dave) → 命中 " + n.to_string() + " 枚",
        reason_text(auth, login.token),
        auth.store.ops_since(before),
      ),
    )
    advance(sc, cfg.kick_grace_ms() + 1000L)
    steps.push(
      step(
        "保留宽窗（默认 5min）关上之后再拿同一枚 token",
        "advance(5min+1s) ; check_login",
        reason_text(auth, login.token) +
        "　⇒ 墓碑已回收，状态不堆积",
        [],
      ),
    )
    mk(
      name,
      "踢人与保留宽窗",
      "被踢 ≠ 未登录：两个原因分得开，宽窗过后墓碑自动回收",
      steps,
      auth.store.dump(),
    )
  } else if name == "disable" {
    let auth = script_auth("disable", cfg, events)
    let login = auth.login("erin", device="pc")
    let before = auth.store.ops_len()
    auth.disable(
      "erin",
      @port.Duration::from_minutes(30L),
      reason="风控命中",
    )
    steps.push(
      step(
        "账号级封禁 30 分钟",
        "disable(erin, 30min, reason=风控命中)",
        reason_text(auth, login.token),
        auth.store.ops_since(before),
      ),
    )
    let mid = auth.store.ops_len()
    auth.undo_disable("erin")
    steps.push(
      step(
        "解除封禁",
        "undo_disable(erin)",
        reason_text(auth, login.token),
        auth.store.ops_since(mid),
      ),
    )
    mk(
      name,
      "封禁与解禁",
      "封禁判定优先于会话是否有效（D: 键独立于 T: 键）",
      steps,
      auth.store.dump(),
    )
  } else if name == "expire" {
    let auth = script_auth("expire", cfg, events)
    let login = auth.login("frank", device="pc")
    steps.push(
      step(
        "刚签发",
        "login(frank, pc)",
        "到期点 " + login.expire_at.to_string() + "（timeout=6h）",
        auth.store.ops_since(0),
      ),
    )
    advance(sc, auth.config.timeout_ms() + 1000L)
    steps.push(
      step(
        "闲置过签发时效",
        "advance(6h+1s) ; check_login",
        reason_text(auth, login.token),
        [],
      ),
    )
    mk(
      name,
      "签发时效",
      "SessionExpired 与 UnknownToken 是两回事，负向反馈才有抓手",
      steps,
      auth.store.dump(),
    )
  } else if name == "idle" {
    let c = @app.TokenConfig::default()
    c.renewal = @port.IdleMark
    c.active_timeout = @port.Duration::from_minutes(5L)
    let auth = script_auth("idle", c, events)
    let login = auth.login("gina", device="pc")
    steps.push(
      step(
        "刚登录（签发时效 6h 远未过）",
        "check_login",
        reason_text(auth, login.token),
        [],
      ),
    )
    advance(sc, 360_000L)
    steps.push(
      step(
        "闲置 6 分钟（活跃阈值 5 分钟）",
        "advance(6min) ; check_login",
        reason_text(auth, login.token) +
        "　⇒ 签发时效还没到，光看它是该放行的",
        [],
      ),
    )
    mk(
      name,
      "活跃时效",
      "IdleMark：太久没动也拒，不看签发时效",
      steps,
      auth.store.dump(),
    )
  } else if name == "rotate" {
    let auth = script_auth("rotate", cfg, events)
    let first = auth.login("henry", device="pc")
    let before = auth.store.ops_len()
    let second = auth.rotate(first.refresh_token)
    steps.push(
      step(
        "整对换新",
        "rotate(refresh-1)",
        "新 access " +
        short(second.token) +
        "；旧 access 与旧 refresh 同时作废",
        auth.store.ops_since(before),
      ),
    )
    steps.push(
      step(
        "旧 access 再拿来用",
        "check_login(access-1)",
        reason_text(auth, first.token),
        [],
      ),
    )
    steps.push(
      step(
        "旧 refresh 重放",
        "rotate(refresh-1) 第二次",
        rotate_text(auth, first.refresh_token),
        [],
      ),
    )
    advance(sc, auth.config.timeout_ms() + 1000L)
    let late = auth.store.ops_len()
    steps.push(
      step(
        "access 自然过期后仍可续命",
        "advance(6h+1s) ; rotate(refresh-2)",
        rotate_text(auth, second.refresh_token) +
        "（不校验绑定 access 是否存活——13 栈 UC-0113 的教训）",
        auth.store.ops_since(late),
      ),
    )
    mk(
      name,
      "全量轮转",
      "旧对同废 + 重放必拒 + 跨闲置空档续命",
      steps,
      auth.store.dump(),
    )
  } else if name == "throttle" {
    let auth = script_auth("throttle", cfg, events)
    let login = auth.login("ivy", device="pc")
    let issued = login.expire_at
    auth.check_login(login.token) |> ignore
    steps.push(
      step(
        "签发时的到期点",
        "login(ivy, pc) ; check_login",
        issued.to_string() + "（访问在 60s 节流窗内，不该动它）",
        auth.store.ops_since(0),
      ),
    )
    let same = expire_of(auth, login.token)
    advance(sc, auth.config.renew_min_interval_ms() + 1000L)
    auth.check_login(login.token) |> ignore
    let moved = expire_of(auth, login.token)
    steps.push(
      step(
        "出窗后再访问一次",
        "advance(61s) ; check_login",
        "到期点 " +
        same.to_string() +
        " → " +
        moved.to_string() +
        " ⇒ 滑动续期前推（否则每请求都要写一次库）",
        [],
      ),
    )
    mk(
      name,
      "续期节流",
      "滑动续期不是无脑每请求写库：renew_min_interval 是契约不是优化",
      steps,
      auth.store.dump(),
    )
  } else if name == "realm" {
    let user = script_auth("user", cfg, events)
    let admin = script_auth("admin", cfg, events)
    let login = user.login("root", device="pc")
    steps.push(
      step(
        "在 user 体系登录",
        "user.login(root, pc)",
        "token " + short(login.token),
        user.store.ops_since(0),
      ),
    )
    steps.push(
      step(
        "同一枚 token 拿去 admin 体系",
        "admin.check_login(同一枚)",
        reason_text(admin, login.token) +
        "　⇒ 键位前缀不同，查不到",
        [],
      ),
    )
    steps.push(
      step(
        "回到自己的体系仍然有效",
        "user.check_login(同一枚)",
        reason_text(user, login.token),
        [],
      ),
    )
    mk(
      name,
      "多账号体系",
      "realm 前缀隔离：同一个人可以在 user 是会员、在 admin 是管理员",
      steps,
      user.store.dump(),
    )
  } else if name == "perm" {
    let auth = script_auth("perm", cfg, events)
    let demo = auth.login("demo-user", device="pc")
    let vip = auth.login("vip-user", device="pc")
    steps.push(
      step(
        "业务侧只供数",
        "SeedPerms::demo()：demo-user=[user:info user:list]，vip-user 另有 order:read，admin 另有 sys:manage",
        "供数走 @port.PermissionProvider（async trait），库里不认业务语义",
        [],
      ),
    )
    steps.push(
      step(
        "AND：两项都有",
        "has_permission(demo, [user:info, user:list], And)",
        permission_text(auth, demo.token, ["user:info", "user:list"], @port.And),
        [],
      ),
    )
    steps.push(
      step(
        "AND：缺一件",
        "has_permission(demo, [user:info, order:read], And)",
        permission_text(
          auth,
          demo.token,
          ["user:info", "order:read"],
          @port.And,
        ),
        [],
      ),
    )
    steps.push(
      step(
        "OR：命中其一即可",
        "has_permission(vip, [order:read, sys:manage], Or)",
        permission_text(auth, vip.token, ["order:read", "sys:manage"], @port.Or),
        [],
      ),
    )
    mk(
      name,
      "权限 SPI",
      "供数归业务、AND/OR 裁决归库（core/policy）",
      steps,
      auth.store.dump(),
    )
  } else {
    steps.push(step("没有这个剧本", name, "检查 ?run= 参数", []))
    mk(name, name, "—", steps, [])
  }
}

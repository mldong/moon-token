///|
/// 页面层：把库里的状态与机制画成人能看懂的东西。全部服务端直出，动作一律带查询串的 GET。
/// 页面上出现的每一个数字都直接来自库的端口读数，不是写死的文案。
fn token_of_key(key : String) -> String {
  // 键形状是 `realm:T:token`，realm 与 token 都不含冒号 ⇒ 按冒号切第三段就是 token
  let parts = @port.split_by(key, ':')
  if parts.length() >= 3 {
    parts[2]
  } else {
    key
  }
}

///|
fn row_link(realm : String, token : String, label : String) -> String {
  "<a href='/guard?realm=" +
  esc(realm) +
  "&token=" +
  esc(token) +
  "'>" +
  esc(label) +
  "</a>"
}

///|
fn live_rows(rows : Array[KeyRow]) -> Int {
  let mut n = 0
  for r in rows {
    if r.kind == "T 会话" && !r.status.contains("墓碑") && r.left_ms != 0L {
      n += 1
    }
  }
  n
}

///|
/// 渲染失败也要回一页人能看的东西（不吞错误：把库抛出的原文印出来）
pub fn error_page(page : String, detail : String) -> String {
  let body = paras([
    "<p>这一页没渲染出来。演示站不吞错误——原文照贴：</p>",
    pre_lines(["页面：" + page, "报错：" + detail]),
    buttons([("/", "回总览"), ("/sessions", "看键位")]),
  ])
  layout("/", "出错了", "页面渲染失败", "", body)
}

///|
pub fn page_overview(site : Site) -> String {
  let user = site.auth_of("user")
  let admin = site.auth_of("admin")
  let user_keys = user.store.dump()
  let admin_keys = admin.store.dump()
  let body = cards([
      ("账号体系 realm", "2 个（user / admin）"),
      (
        "有效会话",
        (live_rows(user_keys) + live_rows(admin_keys)).to_string(),
      ),
      ("键位总数", (user_keys.length() + admin_keys.length()).to_string()),
      ("事件条数", site.events.count().to_string()),
      ("时钟", site.clock.mode_label()),
      ("站点重置次数", site.resets.to_string()),
    ]) +
    paras([
      "<h2>这套库在做什么</h2>",
      "<p>MoonBit 生态的登录态/会话标准件：多账号体系、双向映射的反查族、双层时效、" +
      "踢/顶/封禁给出<b>精确原因</b>、可插拔 async 存储端口、路由守卫 DSL、领域事件。" +
      "分层是 DDD：<code>domain</code>（聚合根）+ <code>policy</code>（纯函数裁决）+ " +
      "<code>app</code>（用例编排）+ <code>port</code>（存储与权限端口）。" +
      "本演示站就是它的一个普通使用者。</p>",
      "<h2>依赖方向</h2>",
      pre_lines([
        "examples/site      观测型 store（端口的另一个实现方）+ 页面",
        "    ↓ 只依赖", "core/app    TokenAuth —— 一个用例一个方法：取聚合 → 调领域服务 → 提交补丁 → 发事件",
        "core/guard  RouteGuard —— 纯逻辑，不依赖任何 web 框架", "    ↓",
        "core/policy    decide_concurrent / decide_renewal / decide_contains / classify_access  ← 纯函数，无 IO",
        "core/domain    TokenSession · AccountFamily（不变量在聚合根方法里）",
        "    ↓", "store/port     TokenStore（async trait）+ FamilyPatch + 键位 + 错误词汇表（共享内核）",
        "store/memory   MemoryStore（惰性过期 / 族清扫 / sweep）· v2 位：moondb / redis",
      ]),
      "<h2>三个入口</h2>",
      "<ul>",
      "<li><b>剧本剧场</b>：11 个既定剧本，逐步看「调用 → 精确结果 → 这一步落库写了什么」——机制由这一栏自证。</li>",
      "<li><b>键位矩阵</b>：把 <code>T:/A:/S:/R:/D:</code> 五种键与它们的剩余寿命画出来；被踢的墓碑看得见，几秒后消失也看得见。</li>",
      "<li><b>时间机器</b>：时效类特性（过期 / 活跃超时 / 踢人宽窗 / 续期节流）不能等真时间，切手动后随便拨。</li>",
      "</ul>",
      buttons([
        ("/play", "先看剧本剧场"),
        ("/sessions", "看键位矩阵"),
        ("/login", "自己登录一次"),
      ]),
    ])
  layout(
    "总览",
    "总览",
    "moon-token v1（内存档）· 本站由 MoonBit 服务端直出，零前端构建、零第三方依赖",
    clock_badge(site.clock),
    body,
  )
}

///|
pub fn page_sessions(site : Site) -> String {
  let buf = StringBuilder()
  for realm in ["user", "admin"] {
    let auth = site.auth_of(realm)
    let rows : Array[Array[String]] = []
    for r in auth.store.dump() {
      let cell = if r.kind == "T 会话" {
        // 链接里带的是全值（40 字符），显示只给前缀——表格不被一长串撑破
        row_link(realm, token_of_key(r.key), short(token_of_key(r.key)))
      } else {
        esc(short(r.key))
      }
      let owner = if r.login_id.is_empty() {
        "—"
      } else if r.device.is_empty() {
        esc(r.login_id)
      } else {
        esc(r.login_id) + " / " + esc(r.device)
      }
      rows.push([
        cell,
        esc(r.kind),
        esc(r.status),
        esc(fmt_left(r.left_ms)),
        owner,
      ])
    }
    buf.write_string(
      "<h2>realm「" +
      esc(realm) +
      "」共 " +
      rows.length().to_string() +
      " 个键</h2>",
    )
    buf.write_string(
      table(
        [
          "键", "键位类型", "状态（库里的真值）", "剩余", "归属",
        ],
        rows,
      ),
    )
  }
  let body = paras([
      "<p class='sub'>状态列直接来自 <code>T:/A:/R:/D:/S:</code> 载荷解码。" +
      "标了「已到期，未回收」的行是<b>活会话过期</b>：读路径照旧交回载荷，为的是让 " +
      "<code>classify_access</code> 报 <code>SessionExpired</code> 而不是含糊的“无效”；" +
      "墓碑态过保留宽窗才被回收。</p>",
      "<p class='sub'>这一栏演的是内存档的键位形状（直接扫 store），不是库对外的契约——" +
      "真实后端没有“扫全库”这一说。</p>",
      buttons([
        ("/sessions", "刷新（重新读数）"),
        ("/reset", "重置站点＝等价进程重启"),
        ("/", "回总览"),
      ]),
    ]) +
    buf.to_string()
  layout(
    "键位矩阵",
    "键位矩阵",
    "内存档的真实键位与剩余寿命；本页每 5 秒自动刷新",
    clock_badge(site.clock),
    body,
    head_extra="<meta http-equiv='refresh' content='5'>",
  )
}

///|
pub async fn page_login_form(site : Site) -> String {
  let rows : Array[Array[String]] = []
  for realm in ["user", "admin"] {
    let auth = site.auth_of(realm)
    for account in site.perms.known_accounts() {
      rows.push([
        esc(realm),
        esc(account),
        esc(online_count(auth, account).to_string()),
        esc(site.perms.grant_for(account)),
        esc(site.perms.role_for(account)),
      ])
    }
  }
  let body = text_form(
      "/do/login",
      [
        ("realm", "realm（user/admin）", "user"),
        ("login_id", "账号", "demo-user"),
        ("device", "设备", "pc"),
        ("remember", "remember（true/false）", "false"),
      ],
      "登录",
    ) +
    paras([
      "<p class='sub'>账号是种子数据（内存版，无需外部服务）：" +
      esc(site.perms.known_accounts().join(" / ")) +
      "。<code>remember=true</code> 走 30d 长时效档。输入请写 ASCII——演示站不做 percent 解码，" +
      "但库对 login_id 的字面值一模一样认账。</p>",
      "<h2>并发策略与时效全部来自配置</h2>",
      pre_lines([
        "TokenConfig::default()", "  token_name       = \"Authorization\"（可配 token_prefix 剥前缀）",
        "  timeout          = 6h     ← 对齐 mldong 13 栈 access 档：30d 的 access 会让滑动续期永远判“不用续”",
        "  remember_timeout = 30d", "  active_timeout   = 不限（剧本「活跃时效」里改成 5min 演 IdleMark）",
        "  renewal          = SlideOnAccess    renew_min_interval = 60s ← 续期节流是契约不是优化",
        "  kick_grace       = 5min             concurrent         = Coexist", "  refresh_timeout  = 30d",
      ]),
      "<h2>该 realm 下当前在线（取自 get_token_list_by_login_id，不是数反查族成员）</h2>",
      table(
        [
          "realm", "账号", "在线会话数", "权限（业务供数）", "角色",
        ],
        rows,
      ),
    ])
  layout(
    "登录台",
    "登录台",
    "签发 access + refresh 整对；同账号在别的设备/策略下的行为见剧本剧场",
    clock_badge(site.clock),
    body,
  )
}

///|
pub async fn page_do_login(site : Site, params : Map[String, String]) -> String {
  let realm = param(params, "realm", "user")
  let login_id = param(params, "login_id", "demo-user")
  let device = param(params, "device", "pc")
  let remember = param(params, "remember", "false") == "true"
  let auth = site.auth_of(realm)
  let outcome = try {
    let r = auth.login(login_id, device~, remember~)
    site.remember_token(realm, login_id, r.token)
    "登录成功　access=" +
    r.token +
    "　refresh=" +
    r.refresh_token +
    "\n" +
    "到期点=" +
    r.expire_at.to_string() +
    "（还剩 " +
    fmt_left(r.expire_at - @port.now_ms()) +
    "）\n" +
    (if r.reused {
      "※ Shared 策略下复用了既有 token，没有新签"
    } else {
      "※ 新签一枚（Coexist 策略下同设备也可并存）"
    })
  } catch {
    err => "被库拒了：" + err.message()
  }
  let token = site.token_for(realm, login_id)
  let body = pre_block(outcome) +
    paras([
      "<div class='btns'>",
      "<a href='/login'>再登录</a>",
      "<a href='/sessions'>看键位</a>",
      "<a href='/guard?realm=" +
      esc(realm) +
      "&token=" +
      esc(token) +
      "'>拿这枚 token 去守卫模拟</a>",
      "<a href='/events'>看事件流</a>",
      "</div>",
      "<h2>这一步在库里走了什么</h2>",
      pre_lines([
        "TokenAuth::login(login_id, device, remember)", "  1. ban_of(login_id)            → D: 键命中就直接 Disabled(reason, until)",
        "  2. load_family(login_id)       → A: 键解出反查族（成员 + version）",
        "  3. policy.decide_concurrent    → Coexist 新签 / Shared 复用 / Supersede 先把旧的落墓碑",
        "  4. issue()                     → 三处写一次做完：T: 会话、R: refresh 绑定、A: 族加成员",
        "  5. events.fire(LoggedIn)       → 落库之后才发，观察者异常不带崩主流程",
      ]),
      "<p class='sub'>curl 走的是同一个站点状态：登录完刷新页面就能看到新会话。</p>",
      pre_lines([
        "curl -s -XPOST 'http://127.0.0.1:18891/login?user=demo-user&device=cli'",
      ]),
    ])
  layout(
    "登录台",
    "登录结果",
    "realm " +
    esc(realm) +
    " · 账号 " +
    esc(login_id) +
    " · 设备 " +
    esc(device),
    clock_badge(site.clock),
    body,
  )
}

///|
/// 守卫台：把 RouteGuard + check_login + 权限裁决拼成一次可改参数的模拟
async fn guard_verdict(
  site : Site,
  realm : String,
  token : String,
  path : String,
  perm : String,
  mode_or : Bool,
) -> (String, String) {
  let auth = site.auth_of(realm)
  let route_guard = @guard.RouteGuard::new()
    .match_pattern("/api/**")
    .match_pattern("/admin/**")
    .not_match_pattern("/api/public/**")
  let request_fns : @guard.RequestFns = {
    path: fn() { path },
    header: fn(_name) { if token.is_empty() { None } else { Some(token) } },
  }
  let verdict = @guard.run_guard(auth, route_guard, request_fns)
  match verdict {
    Ok(login_id) => {
      let first = "守卫放行　login_id=" +
        login_id +
        "　（路径 " +
        path +
        " 命中 /api/** 或 /admin/**）"
      let second = if perm.is_empty() {
        "（本次未要求权限）"
      } else {
        bool_text_site(
          auth.has_permission(
            token,
            [perm],
            mode=if mode_or { @port.Or } else { @port.And },
          ),
        ) +
        "　要求权限 " +
        perm +
        (if mode_or { "（OR）" } else { "（AND）" })
      }
      (first, second)
    }
    Err(err) =>
      ("守卫拦下：" + err.message(), "先过鉴权，再谈权限")
  }
}

///|
fn bool_text_site(b : Bool) -> String {
  if b {
    "权限判定 true"
  } else {
    "权限判定 false"
  }
}

///|
pub async fn page_guard(site : Site, params : Map[String, String]) -> String {
  let realm = param(params, "realm", "user")
  let token = param(params, "token", "")
  let path = param(params, "path", "/api/user/info")
  let perm = param(params, "perm", "user:info")
  let mode_or = param(params, "mode", "and") == "or"
  let (verdict, perm_line) = guard_verdict(
    site, realm, token, path, perm, mode_or,
  )
  let body = text_form(
      "/guard",
      [
        ("realm", "realm", realm),
        ("path", "请求路径", path),
        ("perm", "要求权限（留空＝不要求）", perm),
        ("mode", "and / or", if mode_or { "or" } else { "and" }),
      ],
      "模拟一次",
    ) +
    paras([
      "<label>token <input name='token' size='58' value='" +
      esc(token) +
      "'></label>",
      "<a href='/sessions'>从键位矩阵点某枚 token 过来</a>",
      pre_lines([verdict, perm_line]),
      "<h2>这一步在库里走了什么</h2>",
      pre_lines([
        "RouteGuard: match_pattern(\"/api/**\") + match_pattern(\"/admin/**\") + not_match_pattern(\"/api/public/**\")",
        "  → 先匹配后豁免：/api/public/** 一律放行", "  → extract_token：读 header Authorization（可剥 token_prefix），空则 AbsentToken",
        "  → TokenAuth::check_login(token)", "        读 T: 键 → 解会话 → classify_access（Active / SessionExpired / KickedOut /",
        "        SupersededByLogin / ActiveTimeout 各报各的原因）→ 查 D: 封禁 → decide_renewal",
        "  → 通过后跑追加断言（权限/角色在这里判，判定在 core/policy）",
      ]),
      "<p class='sub'>「受保护 API」是同一套守卫挂在 JSON 门面前的效果，守卫逻辑只有一份：</p>",
      pre_lines([
        "curl -s 'http://127.0.0.1:18891/api/user/info'                      # → AbsentToken",
        "curl -s -H 'Authorization: <token>' 'http://127.0.0.1:18891/api/user/info'",
      ]),
    ])
  layout(
    "守卫模拟",
    "守卫模拟",
    "改路径 / token / 所需权限，看裁决落在哪一条原因上",
    clock_badge(site.clock),
    body,
  )
}

///|
/// 受保护 API 说明页：浏览器直接打开 /api/** 拿到的是 JSON，这里给出对照
pub async fn page_api_demo(site : Site, params : Map[String, String]) -> String {
  let realm = param(params, "realm", "user")
  let token = param(params, "token", "")
  let (verdict, perm_line) = guard_verdict(
    site, realm, token, "/api/user/info", "user:info", false,
  )
  let body = paras([
    "<p>JSON 门面（给脚本用）与页面共用同一份站点状态、同一套守卫。这一页就是把守卫结果" +
    "原样搬到 HTML 上，免得为了看效果去开终端。</p>",
    pre_lines([verdict, perm_line]),
    "<h2>curl 对照</h2>",
    pre_lines([
      "curl -s 'http://127.0.0.1:18891/health'", "curl -s -XPOST 'http://127.0.0.1:18891/login?user=demo-user&device=cli'",
      "curl -s 'http://127.0.0.1:18891/api/user/info' -H 'Authorization: <token>'",
      "curl -s -XPOST 'http://127.0.0.1:18891/kick?user=demo-user' -H 'Authorization: <token>'",
      "bash examples/curl.sh     # 全套冒烟",
    ]),
    "<p class='sub'>失败信封固定 <code>{\"code\":99999999,\"msg\":\"not login: KickedOut\",...}</code> —— " +
    "msg 里带的是库给的精确原因，不是笼统的“未登录”。</p>",
    buttons([
      ("/guard", "去守卫台自己试"),
      ("/api/user/info", "直接看 JSON（无 token，应被拦）"),
    ]),
  ])
  layout(
    "受保护 API",
    "受保护 API",
    "同一套守卫，两个门面",
    clock_badge(site.clock),
    body,
  )
}

///|
pub fn page_events(site : Site) -> String {
  let rows : Array[Array[String]] = []
  for line in site.events.tail(60) {
    rows.push([esc(line)])
  }
  let body = paras([
      "<p class='sub'>事件是<b>落库之后</b>才 fire：码 1 登录 / 2 登出 / 3 踢 / 4 顶 / 5 封 / 6 解 / 7 轮转，10+ 预留不占语义。" +
      "站点每个 auth 上都多挂了一条<b>总会抛错的观察者</b>——观察者异常不会改变任何业务结果，" +
      "这正是事件订阅该有的样子（库里的 <code>EventHub::fire</code> 逐条吞异常）。</p>",
      buttons([
        ("/login", "去登录一枚（会发 LoggedIn）"),
        ("/sessions", "看键位"),
      ]),
    ]) +
    table(["事件流水（最近 60 条）"], rows)
  layout(
    "事件流",
    "事件流",
    "realm 与剧本的事件都汇到同一格里（剧本用独立 realm，名字即剧本名）",
    clock_badge(site.clock),
    body,
    head_extra="<meta http-equiv='refresh' content='5'>",
  )
}

///|
pub fn page_clock(site : Site, params : Map[String, String]) -> String {
  let action = param(params, "act", "")
  if action == "real" {
    site.clock.manual = false
    site.install_clock()
  } else if action == "manual" {
    site.clock.to_manual()
  } else if !action.is_empty() {
    match @port.parse_int64(action) {
      None => ()
      Some(ms) => if ms > 0L { site.clock.advance(ms) }
    }
  }
  let body = buttons([
      ("/clock?act=real", "切回真实时钟"),
      ("/clock?act=manual", "切手动（以现在为起点）"),
      ("/clock?act=1000", "拨快 1 秒"),
      ("/clock?act=60000", "拨快 1 分钟"),
      ("/clock?act=300000", "拨快 5 分钟＝踢人宽窗"),
      ("/clock?act=21600001", "拨快 6h+1s＝access 到期"),
      ("/clock?act=2592000001", "拨快 30d+1s＝refresh 到期"),
    ]) +
    pre_lines([
      "now = " + site.clock.now().to_string() + " ms",
      "模式 = " + site.clock.mode_label(),
      "键位矩阵的剩余寿命、惰性过期、续期节流判定全部吃这枚时钟（库里的 @port.set_clock 环境端口）",
    ]) +
    paras([
      "<h2>为什么必须有它</h2>",
      "<p>本库有一整类特性是“时间到了才成立”的：签发时效、活跃时效、踢人保留宽窗、续期节流窗。" +
      "没有可注入时钟就只能真等六小时——所以时钟槽不是锦上添花，是<b>这些用例能被测出来、也能被演出来</b>" +
      "的前提（jeeflow 引擎侧 issues/120 的同款教训）。</p>",
      "<p class='sub'>手动模式下键位矩阵里的“剩余”是相对我们拨出来的 now 算的，不是墙钟。</p>",
    ])
  layout(
    "时间机器",
    "时间机器",
    "真实/手动两态；拨动之后回键位矩阵看寿命变化",
    clock_badge(site.clock),
    body,
  )
}

///|
pub fn page_reset(site : Site) -> String {
  site.reset()
  let body = paras([
    "<p>站点已重置：两个 realm 的存储与观察者都重建（内存档 ⇒ 等价进程重启），种子权限数据保留，" +
    "时钟模式保留。</p>",
    buttons([("/", "回总览"), ("/sessions", "看键位")]),
  ])
  layout(
    "已重置",
    "已重置",
    "所有会话作废，站点回到刚启动的样子",
    clock_badge(site.clock),
    body,
  )
}

///|
pub fn page_play_index(site : Site) -> String {
  let rows : Array[Array[String]] = []
  for (key, label, gist) in scripts_index() {
    rows.push([
      "<a href='/play?run=" + esc(key) + "'>" + esc(label) + "</a>",
      esc(key),
      esc(gist),
    ])
  }
  let body = paras([
      "<p class='sub'>每个剧本都在<b>独立 realm + 独立内存档 + 独立手动时钟</b>上跑：剧本之间、剧本与站点主状态" +
      "互不污染。剧本要演的都是“时间到了才成立”的机制，所以进去就是手动时钟。</p>",
    ]) +
    table(["剧本", "参数名", "看点"], rows)
  layout(
    "剧本剧场",
    "剧本剧场",
    "把机制演成一步步的因果",
    clock_badge(site.clock),
    body,
  )
}

///|
pub async fn page_play(site : Site, params : Map[String, String]) -> String {
  let name = param(params, "run", "")
  if name.is_empty() {
    page_play_index(site)
  } else {
    let script = run_script(site, name)
    let buf = StringBuilder()
    buf.write_string("<p class='sub'>" + esc(script.gist) + "</p>")
    let mut index = 0
    for st in script.steps {
      index += 1
      buf.write_string(
        "<h2>" + index.to_string() + ". " + esc(st.title) + "</h2>",
      )
      buf.write_string(pre_lines(["$ " + st.call, "→ " + st.outcome]))
      if !st.ops.is_empty() {
        let rows : Array[Array[String]] = []
        for op in st.ops {
          rows.push([esc(op)])
        }
        buf.write_string(
          "<p class='sub'>这一步期间 store 被调用：</p>",
        )
        buf.write_string(table(["端口调用流水"], rows))
      }
    }
    let key_rows : Array[Array[String]] = []
    for r in script.keys {
      key_rows.push([
        esc(short(r.key)),
        esc(r.kind),
        esc(r.status),
        esc(fmt_left(r.left_ms)),
      ])
    }
    buf.write_string("<h2>剧本结束时的键位快照</h2>")
    buf.write_string(
      table(["键", "键位类型", "状态", "剩余"], key_rows),
    )
    buf.write_string(
      buttons([
        ("/play", "换剧本"),
        ("/sessions", "看站点键位"),
        ("/events", "看事件流"),
      ]),
    )
    // 剧本跑在自己的手动时钟上，这里不许再挂站点的时钟徽标（会误报"真实时钟"）
    let badge = "<p><span class='badge warn'>剧本自带手动时钟</span> <span class='dim'>now=" +
      @port.now_ms().to_string() +
      "</span></p>"
    layout(
      "剧本剧场",
      "剧本 · " + script.label,
      "realm「" + script.name + "」· 跑完自动把时钟装回站点模式",
      badge,
      buf.to_string(),
    )
  }
}

///|
/// 演示站状态层：时钟槽、权限种子数据、观测型 store、站点装配。
/// 全部是**站点侧**的实现，不动库契约——观测型 store 与权限端口都只是端口的普通实现方，
/// 顺带当"端口可被第三方包一层"的活证据。
pub type Auth = @app.TokenAuth[ObservingStore, SeedPerms]

///|
/// 时间机器：真实/手动两态（owner 10-01 拍：两种都给，默认真实时钟）。
/// 库的时钟槽 `@port.set_clock` 只装一个闭包，模式切换靠读这个格子。
pub(all) struct ClockCell {
  mut manual : Bool
  mut manual_ms : Int64
}

///|
pub fn ClockCell::new() -> ClockCell {
  let c : ClockCell = { manual: false, manual_ms: 0L, }
  c
}

///|
pub fn ClockCell::now(self : ClockCell) -> Int64 {
  if self.manual {
    self.manual_ms
  } else {
    @env.now().reinterpret_as_int64()
  }
}

///|
/// 从真实时钟切到手动：以"当前真实时刻"为起点，切完时间就归我们拨
pub fn ClockCell::to_manual(self : ClockCell) -> Unit {
  if !self.manual {
    self.manual_ms = @env.now().reinterpret_as_int64()
    self.manual = true
  }
}

///|
pub fn ClockCell::advance(self : ClockCell, ms : Int64) -> Unit {
  self.to_manual()
  self.manual_ms += ms
}

///|
pub fn ClockCell::mode_label(self : ClockCell) -> String {
  if self.manual {
    "手动时钟（时间由页面拨动）"
  } else {
    "真实时钟"
  }
}

///|
/// 权限/角色供数（业务侧只给数，AND/OR 判定在库的领域服务里）。
/// 当前是内存版 ⇒ 直接初始化一份种子数据，够把 SPI 与权限裁决演清楚。
pub(all) struct SeedPerms {
  granted : Map[String, Array[String]]
  roles : Map[String, Array[String]]
}

///|
pub fn SeedPerms::demo() -> SeedPerms {
  let p : SeedPerms = {
    granted: Map::from_array([
      ("demo-user", ["user:info", "user:list"]),
      ("vip-user", ["user:info", "user:list", "order:read"]),
      ("admin", ["user:info", "user:list", "order:read", "sys:manage"]),
    ]),
    roles: Map::from_array([
      ("demo-user", ["user"]),
      ("vip-user", ["user", "vip"]),
      ("admin", ["admin"]),
    ]),
  }
  p
}

///|
pub impl @port.PermissionProvider for SeedPerms with fn get_permissions(
  self,
  login_id,
  _device,
) {
  match self.granted.get(login_id) {
    None => []
    Some(v) => v
  }
}

///|
pub impl @port.PermissionProvider for SeedPerms with fn get_roles(
  self,
  login_id,
  _device,
) {
  match self.roles.get(login_id) {
    None => []
    Some(v) => v
  }
}

///|
pub extend SeedPerms with @port.PermissionProvider::{get_permissions, get_roles}

///|
pub fn SeedPerms::known_accounts(self : SeedPerms) -> Array[String] {
  self.granted.to_array().map((pair : (String, Array[String])) => pair.0)
}

///|
pub fn SeedPerms::grant_for(self : SeedPerms, login_id : String) -> String {
  match self.granted.get(login_id) {
    None => "—"
    Some(v) => v.join(" ")
  }
}

///|
pub fn SeedPerms::role_for(self : SeedPerms, login_id : String) -> String {
  match self.roles.get(login_id) {
    None => "—"
    Some(v) => v.join(" ")
  }
}

///|
/// 观测型 store：委托内存适配器，顺手记一条操作流水。
/// 站点"这一步落库写了什么"那一栏全靠它——也是端口能被装饰的证据。
pub(all) struct ObservingStore {
  inner : @mem.MemoryStore
  ops : Array[String]
}

///|
pub fn ObservingStore::new(realm : String) -> ObservingStore {
  let s : ObservingStore = { inner: @mem.MemoryStore::new(realm), ops: [], }
  s
}

///|
pub fn short(token : String) -> String {
  if token.length() <= 10 {
    token
  } else {
    token[:10].to_owned() + "…"
  }
}

///|
fn note(store : ObservingStore, line : String) -> Unit {
  store.ops.push(line)
  // 只留最近 120 条：长驻演示不涨内存
  if store.ops.length() > 120 {
    store.ops.remove(0) |> ignore
  }
}

///|
/// 补丁意图 → 人能读的一行（反向索引的唯一写入口，所以这一行就是"库里发生了什么"）
fn patch_text(patch : @port.FamilyPatch) -> String {
  match patch {
    @port.AddToken(login_id, device, token, expire_at) =>
      "apply AddToken " +
      login_id +
      "/" +
      device.id +
      " tok=" +
      short(token) +
      " exp=" +
      expire_at.to_string()
    @port.MarkStatus(tokens, status, deadline) =>
      "apply MarkStatus n=" +
      tokens.length().to_string() +
      " status=" +
      status.to_code() +
      " deadline=" +
      deadline.to_string()
    @port.RemoveTokens(login_id, tokens) =>
      "apply RemoveTokens " + login_id + " n=" + tokens.length().to_string()
    @port.TouchExpire(tokens, expire_at) =>
      "apply TouchExpire n=" +
      tokens.length().to_string() +
      " exp=" +
      expire_at.to_string()
    @port.PutRecord(key, payload, expire_at) =>
      "apply PutRecord " +
      key +
      " " +
      payload.length().to_string() +
      "B exp=" +
      expire_at.to_string()
    @port.RemoveKeys(keys) =>
      "apply RemoveKeys n=" +
      keys.length().to_string() +
      " " +
      keys.map(short).join(" ")
  }
}

///|
pub impl @port.TokenStore for ObservingStore with fn get(self, key) {
  let value = self.inner.get(key)
  note(
    self,
    "get   " +
    key +
    " → " +
    (match value {
      None => "miss"
      Some(_) => "hit"
    }),
  )
  value
}

///|
pub impl @port.TokenStore for ObservingStore with fn set(
  self,
  key,
  payload,
  expire_at,
) {
  note(
    self,
    "set   " +
    key +
    " " +
    payload.length().to_string() +
    "B exp=" +
    expire_at.to_string(),
  )
  self.inner.set(key, payload, expire_at)
}

///|
pub impl @port.TokenStore for ObservingStore with fn del(self, keys) {
  note(
    self,
    "del   n=" + keys.length().to_string() + " " + keys.map(short).join(" "),
  )
  self.inner.del(keys)
}

///|
pub impl @port.TokenStore for ObservingStore with fn get_and_del(self, key) {
  let value = self.inner.get_and_del(key)
  note(
    self,
    "take  " +
    key +
    " → " +
    (match value {
      None => "miss"
      Some(_) => "hit（原子取删：重放防护就在这一步）"
    }),
  )
  value
}

///|
pub impl @port.TokenStore for ObservingStore with fn apply(self, patch) {
  note(self, patch_text(patch))
  self.inner.apply(patch)
}

///|
pub impl @port.TokenStore for ObservingStore with fn sweep(self, now) {
  let cleared = self.inner.sweep(now)
  note(
    self,
    "sweep now=" +
    now.to_string() +
    " → 清掉 " +
    cleared.to_string() +
    " 条",
  )
  cleared
}

///|
pub extend ObservingStore with @port.TokenStore::{
  get,
  set,
  del,
  get_and_del,
  apply,
  sweep,
}

///|
pub fn ObservingStore::ops_len(self : ObservingStore) -> Int {
  self.ops.length()
}

///|
/// 从第 `from` 条起的流水（剧本用它取"这一步期间"写进去的那几条）
pub fn ObservingStore::ops_since(
  self : ObservingStore,
  from : Int,
) -> Array[String] {
  if self.ops.length() <= from {
    []
  } else {
    let out : Array[String] = []
    let mut index = from
    while index < self.ops.length() {
      out.push(self.ops[index])
      index += 1
    }
    out
  }
}

///|
/// 键位快照：五种键各归一类，`T:` 解会话载荷取状态。
/// 直接读 `inner.entries` 是演示站的特权——真实后端没有"扫全库"这一说，
/// 所以这一栏演的是内存档，不是契约。
pub(all) struct KeyRow {
  key : String
  kind : String
  status : String
  left_ms : Int64
  login_id : String
  device : String
}

///|
fn key_row(
  key : String,
  kind : String,
  status : String,
  left_ms : Int64,
  login_id : String,
  device : String,
) -> KeyRow {
  let r : KeyRow = { key, kind, status, left_ms, login_id, device, }
  r
}

///|
fn left_of(expire_at : Int64, now : Int64) -> Int64 {
  if expire_at <= 0L {
    -1L
  } else if expire_at <= now {
    0L
  } else {
    expire_at - now
  }
}

///|
pub fn ObservingStore::dump(self : ObservingStore) -> Array[KeyRow] {
  let now = @port.now_ms()
  let out : Array[KeyRow] = []
  for (key, entry) in self.inner.entries.to_array() {
    let left = left_of(entry.expire_at, now)
    if key.contains(":T:") {
      match @port.SessionRecord::decode(entry.payload) {
        None =>
          out.push(key_row(key, "T 会话", "载荷解不开", left, "", ""))
        Some(record) => {
          let alive = record.status.same(@port.SessionStatus::Active)
          let status = if alive { "Active" } else { record.status.to_code() }
          out.push(
            key_row(
              key,
              "T 会话",
              (if alive { "Active" } else { "墓碑 " + status }) +
              (if left == 0L { "（已到期，未回收）" } else { "" }),
              left,
              record.login_id,
              record.device.id,
            ),
          )
        }
      }
    } else if key.contains(":A:") {
      match @port.FamilyRecord::decode(entry.payload) {
        None =>
          out.push(key_row(key, "A 反查族", "载荷解不开", left, "", ""))
        Some(record) =>
          out.push(
            key_row(
              key,
              "A 反查族",
              "members=" +
              record.members.length().to_string() +
              " ver=" +
              record.version.to_string(),
              left,
              record.login_id,
              "",
            ),
          )
      }
    } else if key.contains(":R:") {
      match @port.RefreshRecord::decode(entry.payload) {
        None =>
          out.push(key_row(key, "R refresh", "载荷解不开", left, "", ""))
        Some(record) =>
          out.push(
            key_row(
              key,
              "R refresh",
              "绑定 access " + short(record.access_token),
              left,
              record.login_id,
              record.device_id,
            ),
          )
      }
    } else if key.contains(":D:") {
      match @port.BanRecord::decode(entry.payload) {
        None =>
          out.push(key_row(key, "D 封禁", "载荷解不开", left, "", ""))
        Some(record) =>
          out.push(
            key_row(
              key,
              "D 封禁",
              "至 " + record.until.to_string() + "（" + record.reason + "）",
              left,
              "",
              "",
            ),
          )
      }
    } else {
      match @port.AccountSessionRecord::decode(entry.payload) {
        None =>
          out.push(
            key_row(key, "S 账号会话", "载荷解不开", left, "", ""),
          )
        Some(record) =>
          out.push(
            key_row(
              key,
              "S 账号会话",
              "属性 " + record.attrs.to_array().length().to_string() + " 项",
              left,
              record.login_id,
              "",
            ),
          )
      }
    }
  }
  out
}

///|
/// 事件流水格子：listener 往里塞，页面读尾巴若干条。
pub(all) struct EventSink {
  items : Array[String]
}

///|
pub fn EventSink::new() -> EventSink {
  let s : EventSink = { items: [], }
  s
}

///|
pub fn EventSink::record(self : EventSink, line : String) -> Unit {
  self.items.push(line)
  if self.items.length() > 150 {
    self.items.remove(0) |> ignore
  }
}

///|
pub fn EventSink::count(self : EventSink) -> Int {
  self.items.length()
}

///|
pub fn EventSink::tail(self : EventSink, n : Int) -> Array[String] {
  let total = self.items.length()
  if total <= n {
    self.items.copy()
  } else {
    let out : Array[String] = []
    let mut index = total - n
    while index < total {
      out.push(self.items[index])
      index += 1
    }
    out
  }
}

///|
/// 事件流水一行的形状（站点 auth 与剧本 auth 共用，故剧本事件也进同一格）
fn event_line(ev : @event.TokenEvent) -> String {
  "\{ev.at.to_string()} · \{ev.event_type.code()} \{ev.event_type.name()} · \{ev.login_id}/\{ev.device} · tok=\{short(ev.token)}"
}

///|
pub fn attach_recorder(auth : Auth, events : EventSink) -> Unit {
  auth.on_event(ev => events.record(event_line(ev)))
}

///|
/// 站点装配：两个 realm（user / admin）各一个 auth；重置＝重建 store+auth 并重挂观察者。
pub(all) struct Site {
  mut user : Auth
  mut admin : Auth
  clock : ClockCell
  perms : SeedPerms
  events : EventSink
  mut last_tokens : Map[String, String]
  mut resets : Int
}

///|
/// 一个 auth 实例 + 两个观察者：一个记账，一个**总会抛错**（演"观察者坏掉不带崩主流程"）。
fn new_auth(realm : String, perms : SeedPerms, events : EventSink) -> Auth {
  let auth = @app.TokenAuth::new(
    realm,
    @app.TokenConfig::default(),
    ObservingStore::new(realm),
    perms,
    @style.opaque_style(),
  )
  auth.on_event(ev => events.record(event_line(ev)))
  auth.on_event(_ev => raise @port.Store("演示：这条观察者总是抛错"))
  auth
}

///|
pub fn Site::new() -> Site {
  let events = EventSink::new()
  let perms = SeedPerms::demo()
  let s : Site = {
    user: new_auth("user", perms, events),
    admin: new_auth("admin", perms, events),
    clock: ClockCell::new(),
    perms,
    events,
    last_tokens: Map::from_array([]),
    resets: 0,
  }
  s
}

///|
pub fn Site::auth_of(self : Site, realm : String) -> Auth {
  if realm == "admin" {
    self.admin
  } else {
    self.user
  }
}

///|
/// 重置：换掉 store 与 auth（等价进程重启），配置与时钟模式保留
/// （时钟槽是全局环境端口，不受重建影响，故模式不用重装）。
pub fn Site::reset(self : Site) -> Unit {
  self.resets += 1
  self.user = new_auth("user", self.perms, self.events)
  self.admin = new_auth("admin", self.perms, self.events)
  self.last_tokens = Map::from_array([])
  self.events.record(
    "— 站点已重置（内存档：等价进程重启）—",
  )
}

///|
pub fn Site::remember_token(
  self : Site,
  realm : String,
  login_id : String,
  token : String,
) -> Unit {
  self.last_tokens[realm + "|" + login_id] = token
}

///|
pub fn Site::token_for(
  self : Site,
  realm : String,
  login_id : String,
) -> String {
  match self.last_tokens.get(realm + "|" + login_id) {
    None => ""
    Some(v) => v
  }
}

///|
/// 把库的时钟槽装成站点的时钟格子（真实/手动都由它裁决）
pub fn Site::install_clock(self : Site) -> Unit {
  let cell = self.clock
  @port.set_clock(Some(fn() { cell.now() }))
}

///|
/// 只读探针：不抛错地拿"下一次调用会是什么结果"（页面演因果用）
pub async fn reason_text(auth : Auth, token : String) -> String {
  try {
    let login_id = auth.check_login(token)
    "放行 → login_id=" + login_id
  } catch {
    err => "拦下 → " + err.message()
  }
}

///|
pub async fn expire_of(
  auth : Auth,
  token : String,
) -> Int64 raise @port.TokenError {
  match auth.get_token_session(token) {
    None => 0L
    Some(session) => session.expire_at()
  }
}

///|
pub async fn rotate_text(auth : Auth, refresh : String) -> String {
  try {
    let result = auth.rotate(refresh)
    "轮转成功 → 新 access " + short(result.token)
  } catch {
    err => "拦下 → " + err.message()
  }
}

///|
pub async fn online_count(
  auth : Auth,
  login_id : String,
) -> Int raise @port.TokenError {
  auth.get_token_list_by_login_id(login_id).length()
}

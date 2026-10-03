///|
/// 环境端口：可注入时钟。core 里没有 time 包，唯一时间源是 `@env.now() -> UInt64`（ms）。
/// 测试注入固定时刻（不可注入就测不了过期——jeeflow issues/120 的教训）。
pub(all) struct ClockSlot {
  mut override_fn : (() -> Int64)?
}

///|
let clock_slot : ClockSlot = { override_fn: None, }

///|
pub fn set_clock(f : (() -> Int64)?) -> Unit {
  clock_slot.override_fn = f
}

///|
pub fn now_ms() -> Int64 {
  match clock_slot.override_fn {
    Some(f) => f()
    None => @env.now().reinterpret_as_int64()
  }
}

///|
/// 仓储端口错误：v2 的 Redis/moondb 后端把 IO 失败投到这里，`TokenError::Store` 再包一层。

///|

///|

///|

///|

///|

///|
/// 仓储端口：全部状态的出入口。声明 async 但本模块不 import 运行时
/// （`moonbitstack/moondb` 的 `AsyncDriver` 同款做法）⇒ 契约零依赖成本，v2 后端可直接实现。
pub(open) trait TokenStore {
  /// 读；**已过期的键视为不存在**（并顺手回收），这是内存与后端共同的语义
  async fn get(Self, String) -> String? raise TokenError
  /// 写；`expire_at <= 0` 表示不过期
  async fn set(Self, String, String, Int64) -> Unit raise TokenError
  async fn del(Self, Array[String]) -> Unit raise TokenError
  /// 原子取删（refresh 全量轮转的重放防护靠它）
  async fn get_and_del(Self, String) -> String? raise TokenError
  /// 反向索引的唯一写入口
  async fn apply(Self, FamilyPatch) -> Unit raise TokenError
  /// 过期清扫，返回清掉的条目数
  async fn sweep(Self, Int64) -> Int raise TokenError
  /// 批量读：一次拿多个键的载荷，返回顺序与入参一致、缺失项为 `None`。
  /// 存在理由：在线列表是"枚举一页 + 取这页详情"，没有它就退化成 N 次往返。
  async fn get_many(Self, Array[String]) -> Array[(String, String?)] raise TokenError
  /// 枚举会话：按**登录时刻反序**（最新在前）翻页，游标见 `make_cursor`。
  /// 返回的是索引级条目（无载荷）；判活不在这一步做——索引不裁决，权威在 `T:`。
  async fn list_sessions(
    Self,
    SessionFilter,
    String,
    Int,
  ) -> SessionPage raise TokenError
}

///|
/// 会话枚举的过滤条件：**只开放我们建模的精确字段**，空串＝该维度不限。
/// 不给模糊匹配、不暴露裸扫描——鉴权库里开一条全库扫的路，等于送业务方一个 DoS 入口。
pub(all) struct SessionFilter {
  login_id : String
  device : String
}

///|
pub fn SessionFilter::all() -> SessionFilter {
  let f : SessionFilter = { login_id: "", device: "", }
  f
}

///|
pub fn SessionFilter::make(login_id : String, device : String) -> SessionFilter {
  let f : SessionFilter = { login_id, device, }
  f
}

///|
/// 索引级条目（不含载荷）：详情交给 `get_many`，这样一页的大小不会被子文档撑爆
pub(all) struct SessionListing {
  token : String
  login_id : String
  device : String
  login_time : Int64
  expire_at : Int64
}

///|
pub fn SessionListing::make(
  token : String,
  login_id : String,
  device : String,
  login_time : Int64,
  expire_at : Int64,
) -> SessionListing {
  let i : SessionListing = {
    token,
    login_id,
    device,
    login_time,
    expire_at,
  }
  i
}

///|
pub(all) struct SessionPage {
  items : Array[SessionListing]
  /// 下一页游标；空串＝到底了
  next_cursor : String
}

///|
pub fn SessionPage::make(
  items : Array[SessionListing],
  next_cursor : String,
) -> SessionPage {
  let p : SessionPage = { items, next_cursor, }
  p
}

///|
/// 单页硬上限：调用方给多大的 limit 都不许超过它，"取全部"在这里被挡在端口层
pub let max_page_size : Int = 100

///|
/// `limit <= 0` 时的默认页大小
pub let default_page_size : Int = 20

///|
pub fn clamp_page_size(limit : Int) -> Int {
  if limit <= 0 {
    default_page_size
  } else if limit > max_page_size {
    max_page_size
  } else {
    limit
  }
}

///|
/// 游标＝`(登录时刻, token)` 的线格式编码。走 `escape` 是因为 token 是外部可传入的不透明串，
/// 里面出现分隔符不能把游标撑成三段。
pub fn make_cursor(item : SessionListing) -> String {
  "\{escape(item.login_time.to_string())}|\{escape(item.token)}"
}

///|
pub fn parse_cursor(text : String) -> (Int64, String)? {
  let parts = split_by(text, '|')
  if parts.length() != 2 {
    None
  } else {
    match parse_int64(unescape(parts[0])) {
      None => None
      Some(login_time) => Some((login_time, unescape(parts[1])))
    }
  }
}

///|
/// 权限源端口：业务只供数，判定归库（`core/policy`）。
///
/// 三个方法的返回都进 `P:` 授权快照、按会话缓存（见 `PermissionRecord`），**每会话至多问一次**——
/// 所以这里可以放心查库；但也因此"业务改了角色权限"不会自动生效，得由 `invalidate_grants` 或
/// 重新登录来推翻快照。
///
/// `extra` 是登录时随 `login(extra=...)` 写进会话的附加属性（appCode/ip/ua 这类供数要用、
/// 又不该编进 login_id 的会话级属性——编 login_id 会污染按身份搜索的 API）。**没带属性时是空表，
/// 不是"缺失"**，所以实现处不用判可选，直接按缺键走自己的缺省。
pub(open) trait PermissionProvider {
  async fn get_permissions(Self, String, Device?, Map[String, String]) -> Array[String] raise TokenError
  async fn get_roles(Self, String, Device?, Map[String, String]) -> Array[String] raise TokenError
  /// 超级管理员判定：业务侧的事实（常见形状是用户表上有一个管理员类型字段）。
  /// 库只把这个布尔原样存进快照，并在权限/角色校验前问一次——"谁是超管"没有通用推导规则。
  async fn is_super_admin(Self, String, Device?, Map[String, String]) -> Bool raise TokenError
}

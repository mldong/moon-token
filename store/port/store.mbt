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
}

///|
/// 权限源端口：业务只供数，判定归库（`core/policy`）
pub(open) trait PermissionProvider {
  async fn get_permissions(Self, String, Device?) -> Array[String] raise TokenError
  async fn get_roles(Self, String, Device?) -> Array[String] raise TokenError
}

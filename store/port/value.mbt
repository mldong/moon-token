///|
/// 值对象：时长。MoonBit core 没有 `Duration` 类型、也没有 time 包，
/// 唯一时间源是 `@env.now() -> UInt64`（ms since epoch），故自带薄类型，全链路以 Int64 毫秒计。
pub(all) struct Duration {
  ms : Int64
}

///|
pub fn Duration::from_millis(ms : Int64) -> Duration {
  let d : Duration = { ms, }
  d
}

///|
pub fn Duration::from_secs(secs : Int64) -> Duration {
  Duration::from_millis(secs * 1000L)
}

///|
pub fn Duration::from_minutes(minutes : Int64) -> Duration {
  Duration::from_millis(minutes * 60_000L)
}

///|
pub fn Duration::from_hours(hours : Int64) -> Duration {
  Duration::from_millis(hours * 3_600_000L)
}

///|
pub fn Duration::from_days(days : Int64) -> Duration {
  Duration::from_millis(days * 86_400_000L)
}

///|
pub fn Duration::to_millis(self : Duration) -> Int64 {
  self.ms
}

///|
pub fn Duration::is_zero(self : Duration) -> Bool {
  self.ms == 0L
}

///|
/// 值对象：登录设备维度。反查族（`A:` 键）按它分组。
pub(all) struct Device {
  id : String
}

///|
pub const DEFAULT_DEVICE_ID : String = "default"

///|
pub fn Device::of(id : String) -> Device {
  let d : Device = { id, }
  d
}

///|
/// 未显式给设备时的归一值：空串/纯空白一律落到 `default`
/// （避免"同一个人"因空格被当成两个设备——13 栈归属值归一的同款尺子）。
pub fn Device::normalize(id : String?) -> Device {
  match id {
    None => Device::of(DEFAULT_DEVICE_ID)
    Some(raw) => {
      let trimmed = raw.trim().to_owned()
      if trimmed.is_empty() {
        Device::of(DEFAULT_DEVICE_ID)
      } else {
        Device::of(trimmed)
      }
    }
  }
}

///|
pub fn Device::to_string(self : Device) -> String {
  self.id
}

///|
pub fn Device::same(self : Device, other : Device) -> Bool {
  self.id == other.id
}

///|
/// 会话状态机：Active 是唯一入口态，Kicked/Superseded 是"带原因的墓碑态"，
/// 只允许 Active→墓碑 的单向迁移（聚合根方法保证）。
pub(all) enum SessionStatus {
  Active
  Kicked
  Superseded
}

///|
pub fn SessionStatus::to_code(self : SessionStatus) -> String {
  match self {
    Active => "0"
    Kicked => "1"
    Superseded => "2"
  }
}

///|
pub fn SessionStatus::of_code(code : String) -> SessionStatus? {
  match code {
    "0" => Some(Active)
    "1" => Some(Kicked)
    "2" => Some(Superseded)
    _ => None
  }
}

///|
pub fn SessionStatus::same(self : SessionStatus, other : SessionStatus) -> Bool {
  self.to_code() == other.to_code()
}

///|
/// 并发登录策略（三态语义定死）
pub(all) enum ConcurrentPolicy {
  Coexist
  Supersede
  Shared
}

///|
pub fn ConcurrentPolicy::code(self : ConcurrentPolicy) -> String {
  match self {
    Coexist => "coexist"
    Supersede => "supersede"
    Shared => "shared"
  }
}

///|
pub fn ConcurrentPolicy::of_code(code : String) -> ConcurrentPolicy? {
  match code {
    "coexist" => Some(Coexist)
    "supersede" => Some(Supersede)
    "shared" => Some(Shared)
    _ => None
  }
}

///|
/// 续期模式：IdleMark=活跃标记独立计时；SlideOnAccess=每次访问滑动续期（mldong 13 栈口径）
pub(all) enum RenewalMode {
  IdleMark
  SlideOnAccess
}

///|
/// 权限/角色判定的组合方式
pub(all) enum MatchMode {
  And
  Or
}

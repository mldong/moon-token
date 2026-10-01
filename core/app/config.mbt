///|
/// 应用层配置。时长统一用共享内核的 `Duration`（core 无 time 包），
/// 默认值即 §9 的既得教训：并发共存不共享、访问即滑动续期、续期 60s 节流、被踢留 5 分钟。
pub(all) struct TokenConfig {
  mut token_name : String
  /// 读取侧剥前缀；空串表示裸值
  mut token_prefix : String
  mut timeout : @port.Duration
  /// "记住我"档：长时效
  mut remember_timeout : @port.Duration
  /// 活跃时效；is_zero() 表示不限
  mut active_timeout : @port.Duration
  mut renewal : @port.RenewalMode
  mut renew_min_interval : @port.Duration
  mut kick_grace : @port.Duration
  mut concurrent : @port.ConcurrentPolicy
  mut refresh_timeout : @port.Duration
}

///|
pub fn TokenConfig::default() -> TokenConfig {
  let c : TokenConfig = {
    token_name: "Authorization",
    token_prefix: "",
    timeout: @port.Duration::from_hours(6L),
    remember_timeout: @port.Duration::from_days(30L),
    active_timeout: @port.Duration::from_millis(0L),
    renewal: @port.SlideOnAccess,
    renew_min_interval: @port.Duration::from_millis(60_000L),
    kick_grace: @port.Duration::from_millis(300_000L),
    concurrent: @port.Coexist,
    refresh_timeout: @port.Duration::from_days(30L),
  }
  c
}

///|
pub fn TokenConfig::timeout_ms(self : TokenConfig) -> Int64 {
  self.timeout.to_millis()
}

///|
pub fn TokenConfig::remember_timeout_ms(self : TokenConfig) -> Int64 {
  self.remember_timeout.to_millis()
}

///|
pub fn TokenConfig::active_timeout_ms(self : TokenConfig) -> Int64 {
  self.active_timeout.to_millis()
}

///|
pub fn TokenConfig::renew_min_interval_ms(self : TokenConfig) -> Int64 {
  self.renew_min_interval.to_millis()
}

///|
pub fn TokenConfig::kick_grace_ms(self : TokenConfig) -> Int64 {
  self.kick_grace.to_millis()
}

///|
pub fn TokenConfig::refresh_timeout_ms(self : TokenConfig) -> Int64 {
  self.refresh_timeout.to_millis()
}

///|
/// 签发结果。`reused` 为真表示 Shared 策略下复用了既有 token，未新签。
pub(all) struct LoginResult {
  token : String
  login_id : String
  device : String
  expire_at : Int64
  refresh_token : String
  reused : Bool
}

///|
pub fn LoginResult::make(
  token : String,
  login_id : String,
  device : String,
  expire_at : Int64,
  refresh_token : String,
  reused : Bool,
) -> LoginResult {
  let r : LoginResult = {
    token,
    login_id,
    device,
    expire_at,
    refresh_token,
    reused,
  }
  r
}

///|
/// 在线列表条目
pub(all) struct TokenInfo {
  token : String
  device : String
  expire_at : Int64
  login_time : Int64
}

///|
pub fn TokenInfo::make(
  token : String,
  device : String,
  expire_at : Int64,
  login_time : Int64,
) -> TokenInfo {
  let i : TokenInfo = { token, device, expire_at, login_time, }
  i
}

///|
/// 领域事件：事实进事件名、码粗载荷细、**落库后 fire**、订阅统一成列表
/// （沿用 jeeflow issues/132 定稿的四原则；码 10+ 预留不发，占号防分叉）。
pub(all) enum TokenEventType {
  LoggedIn
  LoggedOut
  Kicked
  Superseded
  Disabled
  Enabled
  Refreshed
}

///|
pub fn TokenEventType::code(self : TokenEventType) -> Int {
  match self {
    LoggedIn => 1
    LoggedOut => 2
    Kicked => 3
    Superseded => 4
    Disabled => 5
    Enabled => 6
    Refreshed => 7
  }
}

///|
pub fn TokenEventType::name(self : TokenEventType) -> String {
  match self {
    LoggedIn => "TOKEN_LOGGED_IN"
    LoggedOut => "TOKEN_LOGGED_OUT"
    Kicked => "TOKEN_KICKED"
    Superseded => "TOKEN_SUPERSEDED"
    Disabled => "TOKEN_DISABLED"
    Enabled => "TOKEN_ENABLED"
    Refreshed => "TOKEN_REFRESHED"
  }
}

///|
pub(all) struct TokenEvent {
  event_type : TokenEventType
  login_id : String
  device : String
  token : String
  at : Int64
}

///|
pub fn TokenEvent::make(
  event_type : TokenEventType,
  login_id : String,
  device : String,
  token : String,
  at : Int64,
) -> TokenEvent {
  let e : TokenEvent = { event_type, login_id, device, token, at, }
  e
}

///|
/// 事件订阅中心。listener 允许抛错，但 `fire` 一律吞掉——
/// 观察者坏掉不能把主流程（登录/登出/踢人）带崩，这与 13 栈的拦截器口径一致。
pub(all) struct EventHub {
  mut listeners : Array[(TokenEvent) -> Unit raise]
}

///|
pub fn EventHub::new() -> EventHub {
  let hub : EventHub = { listeners: [], }
  hub
}

///|
pub fn EventHub::subscribe(
  self : EventHub,
  listener : (TokenEvent) -> Unit raise,
) -> Unit {
  self.listeners.push(listener)
}

///|
pub fn EventHub::listener_count(self : EventHub) -> Int {
  self.listeners.length()
}

///|
pub fn EventHub::fire(self : EventHub, event : TokenEvent) -> Unit {
  for listener in self.listeners {
    listener(event) catch {
      // 订阅方异常不外溢：主流程的结果不因观察者而变
      _ => ()
    }
  }
}

///|
/// 意图补丁：聚合一致性边界内的变更意图（不是 setter 序列）。
/// **`apply` 是反向索引（`A:` 族与 `T:` 状态）的唯一写入口**，裸 `set/del` 只服务附加数据。
/// 契约三条：① 同一批内按序生效；② 整体幂等（重复投递结果一致——故版本号只随成员增删变化）；
/// ③ 不带时钟——需要绝对时刻的地方一律传算好的 `deadline`/`expire_at`，保证多后端同判据同答案。
pub(all) enum FamilyPatch {
  /// 反向索引加成员：login_id, device, token, 该 token 的到期时刻, 登录时刻
  AddToken(String, Device, String, Int64, Int64)
  /// 置状态墓碑并改写到期时刻（"被踢方拿精确原因"靠它）：tokens, status, deadline
  MarkStatus(Array[String], SessionStatus, Int64)
  /// 摘除成员并删对应 `T:` 键：login_id, tokens
  RemoveTokens(String, Array[String])
  /// 复用同一枚 token 重新登录：login_id, token, 新的登录时刻。
  /// 把该成员移到队尾并刷新 `lt`，**不推版本号**（成员集合没变，不变量 3 只管增删）。
  /// 存在理由：上限是"先进先出"，天天复登的设备必须回到队列尾部，否则它会被当成最老的先剔掉。
  RefreshLogin(String, String, Int64)
  /// 只摘成员、**保留 `T:` 键**：login_id, tokens。
  /// 存在理由：`max_sessions` 选 Kick/Supersede 档时，被剔的那枚要留墓碑让对端读到精确原因，
  /// 但它已经不算"这个账号还活着的会话"——成员不摘掉，上限就会把保留窗内的墓碑数进去。
  ForgetTokens(String, Array[String])
  /// 续期：tokens, 新的到期时刻
  TouchExpire(Array[String], Int64)
  /// 附加数据直写（`S:`/`D:`/`R:`）：key, payload, expire_at（<=0 表示不过期）
  PutRecord(String, String, Int64)
  /// 删任意键
  RemoveKeys(Array[String])
}

///|
/// 键位约定（realm 由 TokenAuth 持有并拼进前缀）
pub(all) struct KeySpace {
  realm : String
}

///|
pub fn KeySpace::of(realm : String) -> KeySpace {
  let k : KeySpace = { realm, }
  k
}

///|
pub fn KeySpace::token(self : KeySpace, token : String) -> String {
  "\{self.realm}:T:\{token}"
}

///|
pub fn KeySpace::family(self : KeySpace, login_id : String) -> String {
  "\{self.realm}:A:\{login_id}"
}

///|
pub fn KeySpace::account_session(self : KeySpace, login_id : String) -> String {
  "\{self.realm}:S:\{login_id}"
}

///|
pub fn KeySpace::refresh(self : KeySpace, refresh_token : String) -> String {
  "\{self.realm}:R:\{refresh_token}"
}

///|
pub fn KeySpace::ban(self : KeySpace, login_id : String) -> String {
  "\{self.realm}:D:\{login_id}"
}

///|
/// 授权快照（`{realm}:P:{token}`）：权限集/角色集/超管位的会话级缓存。
/// **按 token 键，不按 login_id**：口径是"超管位和 token 一个生命周期，权限与角色码也是"。
/// 这样一来会话终结即快照同键作废，失效也不必猜设备（族里能枚举出全部 token）。
/// 代价是同账号多端登录各问业务一次，仍远比"每请求问一次"便宜。
pub fn KeySpace::grants(self : KeySpace, token : String) -> String {
  "\{self.realm}:P:\{token}"
}

///|
/// 活会话索引（`{realm}:Z`）：在线列表枚举与 `max_sessions` 淘汰共用的一条派生索引。
/// 无载荷、非第六类记录——权威永远在 `T:`；索引落后于事实时，枚举出来的 token 会在
/// 批量取载荷那一轮被丢弃，宁可少几条也不返回错数据。
/// 内存版不必真建这条键（遍历自有表即可），但排序与游标必须与 Redis ZSET 等价。
pub fn KeySpace::session_index(self : KeySpace) -> String {
  "\{self.realm}:Z"
}

///|
/// **键位预留（进过发布版本就不可回收，别拿去当空闲字母用）**：
/// - `X:` = `token → realm` 反查（多 realm 网关场景，当前不做）
/// - `E:` = 事件/审计流水（v1 事件只在内存回调，不落库）
/// 已占用：`T:` 会话、`A:` 反查族、`S:` 账号会话数据、`R:` refresh 绑定、`D:` 封禁、
/// `P:` 授权快照（按 token）、`Z` 活会话索引。
/// 后端实现验收清单见 `docs/storage-port.md`。

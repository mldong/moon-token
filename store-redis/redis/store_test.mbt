///|
/// RS 系列：真机测试。判据都落在"两台服务端给出同一个答案"和"上一代驱动翻过的三个坑"上。
///
/// 这批用例刻意不碰 `@port.set_clock`：同一个测试二进制里的 async 用例之间会互相覆盖那个
/// 全局时钟槽（`store-file` 那批先踩过），所以一律用绝对时刻——`FAR` 远在未来、`PAST` 远在过去，
/// 判过期只走 `PXAT` 与 `sweep(now)` 这两条显式的路。
///
/// 开关：默认**跳过**（CI 里没有 redis 服务时不炸门），设 `MT_REDIS_TEST=1` 才真跑。
/// ⚠ 跳过不等于测过——真跑请走 `scripts/redis-gate.sh`，它会把任何 SKIP 判成失败。

///|
const FAR : Int64 = 4_000_000_000_000L

///|
const PAST : Int64 = 1L

///|
const SWEEP_NOW : Int64 = 2_000_000_000_000L

///|
fn enabled() -> Bool {
  match @env.get_env_var("MT_REDIS_TEST") {
    Some(v) => v == "1"
    None => false
  }
}

///|
fn env_or(name : String, fallback : String) -> String {
  match @env.get_env_var(name) {
    Some(v) => if v.is_empty() { fallback } else { v }
    None => fallback
  }
}

///|
fn port_of() -> Int {
  let text = env_or("MT_REDIS_PORT", "6379")
  match @port.parse_int64(text) {
    Some(v) => v.to_int()
    None => 6379
  }
}

///|
fn db_of() -> Int {
  let text = env_or("MT_REDIS_DB", "0")
  match @port.parse_int64(text) {
    Some(v) => v.to_int()
    None => 0
  }
}

///|
/// 会话载荷：`expire_at` 是**会话自己**的时效截止，与键的 TTL（已加保留宽窗）刻意分开传，
/// 这样"过期但还在"这一档能被真的测到。
fn session_payload(login_id : String, token_expire : Int64) -> String {
  @port.SessionRecord::make(
    login_id,
    @port.Device::of("pc"),
    1_000_000L,
    token_expire,
  ).encode()
}

///|
async fn open(realm : String) -> @redis.RedisStore raise @port.TokenError {
  @redis.RedisStore::open(
    realm,
    env_or("MT_REDIS_HOST", "localhost"),
    port=port_of(),
    password=env_or("MT_REDIS_PWD", ""),
    db=db_of(),
  )
}

///|
/// 把某个 realm 名下的键全清掉并返回清掉的条数——每个用例收尾自证无残骸。
async fn wipe(
  store : @redis.RedisStore,
  realm : String,
) -> Int raise @port.TokenError {
  let keys = store.scan_keys("\{realm}:*")
  if !keys.is_empty() {
    let _ = store.del(keys)
  }
  keys.length()
}

///|
async test "RS1 会话值往返：含中文的 UA 形状必须等值、服务端存的是字节全长" {
  if !enabled() {
    println("SKIP RS1: 未设 MT_REDIS_TEST=1")
    return
  }
  let realm = "mtrs1"
  let store = open(realm)
  defer store.close()
  let key = store.keys.token("tok-ua")
  // 与登录链路里 extra.ua 同形状：原始 User-Agent 含中文机型名
  let payload = session_payload("u1", FAR) +
    "|ua:华为Mate60Pro/微信8.0.44 张三"
  let _ = store.set(key, payload, FAR)
  let back = store.get(key)
  match back {
    None => fail("RS1 读不回会话值")
    Some(v) => assert_eq(v, payload)
  }
  // 服务端自己说存了多少字节：必须等于 UTF-8 全长，不是字符数
  let bytes = @encoding/utf8.encode(payload).length()
  let len = store.ask(["STRLEN", key])
  match len {
    @redis_client.RedisValue::Integer(n) => assert_eq(n, bytes)
    _ => fail("RS1 STRLEN 的回复不是整数")
  }
  let _ = store.del([key])
  assert_eq(wipe(store, realm), 0)
}

///|
async test "RS2 190KB 载荷往返等值，且之后连接照旧可用" {
  if !enabled() {
    println("SKIP RS2: 未设 MT_REDIS_TEST=1")
    return
  }
  let realm = "mtrs2"
  let store = open(realm)
  defer store.close()
  let key = store.keys.token("tok-big")
  let unit = "abcdefghijklmnopqrstuvwxyz0123456789AB"
  let parts : Array[String] = []
  for _ in 0..<5000 {
    parts.push(unit)
  }
  let payload = parts.join("")
  let _ = store.set(key, payload, FAR)
  match store.get(key) {
    None => fail("RS2 大载荷读不回来")
    Some(v) => {
      assert_eq(v.length(), payload.length())
      assert_true(v == payload)
    }
  }
  // 上一代驱动在这里会把读帧错位，之后的每条命令都报错
  let ping = store.ask(["PING"])
  match ping {
    @redis_client.RedisValue::SimpleString(v) => assert_eq(v, "PONG")
    _ => fail("RS2 大载荷之后的 PING 不是 +PONG")
  }
  let _ = wipe(store, realm)
}

///|
async test "RS3 get_and_del 原子取删，重放第二次读作缺失" {
  if !enabled() {
    println("SKIP RS3: 未设 MT_REDIS_TEST=1")
    return
  }
  let realm = "mtrs3"
  let store = open(realm)
  defer store.close()
  let key = store.keys.refresh("rt-1")
  let _ = store.set(key, "taken", FAR)
  let first = store.get_and_del(key)
  assert_eq(first, Some("taken"))
  let second = store.get_and_del(key)
  // 取删不原子就会让同一枚 refresh 轮转出两个会话，重放防护当场失效
  assert_true(second is None)
  let _ = wipe(store, realm)
}

///|
async test "RS4 惰性过期分两档：过期但还在要交回载荷，过窗读作缺失" {
  if !enabled() {
    println("SKIP RS4: 未设 MT_REDIS_TEST=1")
    return
  }
  let realm = "mtrs4"
  let store = open(realm)
  defer store.close()
  // ① 会话时效已过、键的保留宽窗还在（core 传下来的 expire_at 已加过窗）⇒ 必须读得到载荷
  let live = store.keys.token("tok-expired-session")
  let _ = store.set(live, session_payload("u1", PAST), FAR)
  let tier_one = store.get(live)
  assert_true(tier_one is Some(_))
  match tier_one {
    None =>
      fail("RS4 第一档被吞掉：SessionExpired 会塌成 UnknownToken")
    Some(blob) => {
      let record = @port.SessionRecord::decode(blob)
      match record {
        None => fail("RS4 第一档载荷解不开")
        Some(r) => assert_true(r.expire_at == PAST)
      }
    }
  }
  // ② 墓碑已过保留宽窗 ⇒ 读作缺失（Redis 侧靠 TTL 天然做到）
  let tomb = store.keys.token("tok-tombstone")
  let _ = store.set(tomb, session_payload("u1", PAST), PAST)
  assert_true(store.get(tomb) is None)
  let _ = wipe(store, realm)
}

///|
async test "RS5 apply 幂等：同补丁投两次版本只 +1，Forget 留 T:、Remove 删 T:" {
  if !enabled() {
    println("SKIP RS5: 未设 MT_REDIS_TEST=1")
    return
  }
  let realm = "mtrs5"
  let store = open(realm)
  defer store.close()
  let token = "tk-idem"
  let tkey = store.keys.token(token)
  let _ = store.set(tkey, session_payload("u5", FAR), FAR)
  let patch = @port.AddToken("u5", @port.Device::of("pc"), token, FAR, 1_000L)
  let _ = store.apply(patch)
  let _ = store.apply(patch)
  let blob = store.get(store.keys.family("u5"))
  match blob {
    None => fail("RS5 族没写进去")
    Some(text) => {
      let record = @port.FamilyRecord::decode(text)
      match record {
        None => fail("RS5 族解不开")
        Some(r) => {
          // 重复投递不重复加成员、不重复推版本号
          assert_eq(r.members.length(), 1)
          assert_eq(r.version, 1L)
        }
      }
    }
  }
  // ForgetTokens：只摘成员，`T:` 必须还在（墓碑要能被对端读到精确原因）
  let _ = store.apply(@port.ForgetTokens("u5", [token]))
  assert_true(store.get(tkey) is Some(_))
  // RemoveTokens：成员与 `T:` 一起走
  let _ = store.set(tkey, session_payload("u5", FAR), FAR)
  let _ = store.apply(
    @port.AddToken("u5", @port.Device::of("pc"), token, FAR, 1_000L),
  )
  let _ = store.apply(@port.RemoveTokens("u5", [token]))
  assert_true(store.get(tkey) is None)
  let _ = wipe(store, realm)
}

///|
async test "RS6 族写走 CAS：两个实例交替加成员，谁都不许丢" {
  if !enabled() {
    println("SKIP RS6: 未设 MT_REDIS_TEST=1")
    return
  }
  let realm = "mtrs6"
  let a = open(realm)
  let b = open(realm)
  defer {
    a.close()
    b.close()
  }
  let _ = a.apply(
    @port.AddToken("u6", @port.Device::of("pc"), "tk-a", FAR, 1_000L),
  )
  let _ = b.apply(
    @port.AddToken("u6", @port.Device::of("pad"), "tk-b", FAR, 2_000L),
  )
  let _ = a.apply(
    @port.AddToken("u6", @port.Device::of("web"), "tk-c", FAR, 3_000L),
  )
  let blob = a.get(a.keys.family("u6"))
  match blob {
    None => fail("RS6 族丢失")
    Some(text) =>
      match @port.FamilyRecord::decode(text) {
        None => fail("RS6 族解不开")
        Some(r) => {
          // 整块覆盖的后端在这里会只剩最后写的那一个成员
          assert_eq(r.members.length(), 3)
          assert_true(r.has_token("tk-a"))
          assert_true(r.has_token("tk-b"))
          assert_true(r.has_token("tk-c"))
        }
      }
  }
  let _ = wipe(a, realm)
  let _ = wipe(b, realm)
}

///|
async test "RS7 在线列表：与内存版同序、游标翻页不重不漏" {
  if !enabled() {
    println("SKIP RS7: 未设 MT_REDIS_TEST=1")
    return
  }
  let realm = "mtrs7"
  let store = open(realm)
  defer store.close()
  let mem = @mem.MemoryStore::new(realm)
  // 同一批会话、同一批补丁，喂两个后端
  let plan : Array[(String, Int64)] = [
    ("tk-a", 5_000L),
    ("tk-b", 4_000L),
    ("tk-c", 4_000L),
    ("tk-d", 3_000L),
  ]
  for (token, lt) in plan {
    let record = @port.SessionRecord::make(
      "u7",
      @port.Device::of("pc"),
      lt,
      FAR,
    )
    let _ = store.set(store.keys.token(token), record.encode(), FAR)
    let _ = store.apply(
      @port.AddToken("u7", @port.Device::of("pc"), token, FAR, lt),
    )
    let _ = mem.set(mem.keys.token(token), record.encode(), FAR)
    let _ = mem.apply(
      @port.AddToken("u7", @port.Device::of("pc"), token, FAR, lt),
    )
  }
  let memory_page = mem.scan_sessions(@port.SessionFilter::all(), "", 10)
  let redis_page = store.scan_sessions(@port.SessionFilter::all(), "", 10)
  let of = (page : @port.SessionPage) => {
    page.items.map((item : @port.SessionListing) => item.token).join(",")
  }
  // 同刻的 tk-b/tk-c 按 token 倒排：两个后端必须给同一个答案，否则游标会漂
  assert_eq(of(redis_page), of(memory_page))
  assert_eq(of(memory_page), "tk-a,tk-c,tk-b,tk-d")
  // 一页一条地翻：四页拿完、不重不漏，最后一页之后游标归空
  let seen : Array[String] = []
  let mut cursor = ""
  let mut rounds = 0
  while true {
    let one = store.scan_sessions(@port.SessionFilter::all(), cursor, 1)
    for item in one.items {
      seen.push(item.token)
    }
    rounds += 1
    if one.next_cursor.is_empty() || rounds > 8 {
      break
    }
    cursor = one.next_cursor
  }
  assert_eq(seen.join(","), "tk-a,tk-c,tk-b,tk-d")
  let _ = wipe(store, realm)
  let _ = mem.sweep(SWEEP_NOW)
}

///|
async test "RS8 sweep 真数得出脏成员，收尾自证无残骸" {
  if !enabled() {
    println("SKIP RS8: 未设 MT_REDIS_TEST=1")
    return
  }
  let realm = "mtrs8"
  let store = open(realm)
  defer store.close()
  // 族里塞一个已过期的成员：sweep 要把它摘掉并返回真实条数
  let _ = store.apply(
    @port.AddToken("u8", @port.Device::of("pc"), "tk-dead", PAST, 1L),
  )
  let _ = store.apply(
    @port.AddToken("u8", @port.Device::of("pc"), "tk-live", FAR, 2L),
  )
  let cleaned = store.sweep(SWEEP_NOW)
  assert_true(cleaned >= 1)
  let blob = store.get(store.keys.family("u8"))
  match blob {
    None => ()
    // 族里只剩活的那个（会话已经不在了的成员也要摘——索引不裁决，但脏行不留）
    Some(text) =>
      match @port.FamilyRecord::decode(text) {
        None => fail("RS8 族解不开")
        Some(r) => {
          assert_false(r.has_token("tk-dead"))
          assert_true(r.has_token("tk-live"))
        }
      }
  }
  let _ = wipe(store, realm)
  // 自证：这个 realm 名下一个键都不该留（连索引一起）
  assert_eq(store.scan_keys("\{realm}:*").length(), 0)
}

///|
/// 与内存版对同一批会话给出同一页序——尺子对齐的正证。
/// 用 `MemoryStore` 造数据（不需要服务端），再拿我的排序函数摆它。
async test "RM5 内存版枚举的序，我的排序函数原样复现" {
  let mem = @mem.MemoryStore::new("rm5")
  let times = [5000L, 4000L, 4000L, 3000L]
  let tokens = ["tk-e", "tk-b", "tk-d", "tk-a"]
  for i in 0..<times.length() {
    let token = tokens[i]
    let lt = times[i]
    let record = @port.SessionRecord::make(
      "u1",
      @port.Device::of("pc"),
      lt,
      lt + 30_000L,
    )
    let _ = mem.set(mem.keys.token(token), record.encode(), lt + 60_000L)
    let _ = mem.apply(
      @port.AddToken("u1", @port.Device::of("pc"), token, lt + 60_000L, lt),
    )
  }
  let page = mem.scan_sessions(@port.SessionFilter::all(), "", 10)
  assert_eq(page.items.length(), 4)
  let memory_order = page.items.map((item : @port.SessionListing) => item.token)
  // 打乱后用我的尺子排，必须落回同一个序
  let reversed : Array[@port.SessionListing] = []
  let total = page.items.length()
  for i = total - 1; i >= 0; i = i - 1 {
    reversed.push(page.items[i])
  }
  let mine = @redis.sort_listings(reversed).map((item : @port.SessionListing) => {
    item.token
  })
  assert_eq(mine.join(","), memory_order.join(","))
  // 5000 最新在前；两个 4000 同刻按 token 倒排（tk-d 在 tk-b 前）
  assert_eq(memory_order.join(","), "tk-e,tk-d,tk-b,tk-a")
}

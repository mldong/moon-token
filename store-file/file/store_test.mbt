///|
/// FS1–FS8：文件后端的三场景。判据都落在"重新打开一个实例"上，因为这一层存在的唯一理由
/// 就是**重启不丢**；至于是不是真写了盘，用 readdir 数文件核对，不接受"内存里当然在"这种自证。
///
/// 这批用例刻意不碰 `@port.set_clock`。本轮实测到：同一个测试二进制里的 async 用例之间会互相
/// 覆盖那个全局时钟槽（自己 `set_clock(Some(1e6))` 之后读到的是别家设的值），拿它写断言等于
/// 写一批看运气的用例。这里全部改用绝对时刻：`FAR` 是远未来的 epoch ms、`PAST` 远在过去，
/// 判过期只剩 `sweep(now)` 这条显式传时参的路。

///|
const FAR : Int64 = 4_000_000_000_000L

///|
const PAST : Int64 = 1L

///|
const SWEEP_NOW : Int64 = 2_000_000_000_000L

///|
fn session_payload(login_id : String, expire_at : Int64) -> String {
  @port.SessionRecord::make(login_id, @port.Device::of("pc"), 1_000_000L, expire_at)
    .encode()
}

///|
async fn file_count(dir : String) -> Int {
  @fs.readdir(dir).length()
}

///|
fn family_key(login_id : String) -> String {
  @port.KeySpace::of("user").family(login_id)
}

///|
async test "FS1 写穿透：换实例重开，全部键原样读回" {
  let dir = @fs.tmpdir(prefix="mt-fs1.")
  let a = @file.FileStore::open("user", dir)
  a.set("user:T:tok1", session_payload("u1", FAR), FAR)
  a.set("user:S:u1", "v=1|login=u1", 0L)
  // 2 个键 + 库自己写的 .gitignore
  assert_eq(file_count(dir), 3)
  let b = @file.FileStore::open("user", dir)
  assert_eq(b.get("user:T:tok1"), a.get("user:T:tok1"))
  assert_eq(b.get("user:S:u1"), Some("v=1|login=u1"))
  assert_eq(b.persisted_size(), 2)
  @fs.rmdir(dir, recursive=true)
}

///|
async test "FS2 载入不判时间，过期键要等 sweep 才连文件一起带走" {
  let dir = @fs.tmpdir(prefix="mt-fs2.")
  let a = @file.FileStore::open("user", dir)
  a.set("user:T:live", session_payload("u1", FAR), FAR)
  a.set("user:T:dead", session_payload("u1", PAST), PAST)
  let b = @file.FileStore::open("user", dir)
  // 两条键都原样载入：这一步一次时间都不读，也就不会把活键当过期删掉
  assert_eq(b.persisted_size(), 2)
  assert_eq(file_count(dir), 3)
  // 出窗的活会话照旧交回载荷，这是 §4.2 的两档契约，与内存版同判据
  assert_true(b.get("user:T:dead") is Some(_))
  b.sweep(SWEEP_NOW) |> ignore
  assert_eq(b.get("user:T:dead"), None)
  match b.get("user:T:live") {
    None => fail("活键不该被 sweep 吃掉")
    Some(_) => ()
  }
  // dead 出内存之后，写穿透层把它的文件一并删掉：只剩 live + .gitignore
  assert_eq(file_count(dir), 2)
  @fs.rmdir(dir, recursive=true)
}

///|
async test "FS3 注销与取删跨重启有效（不会复活）" {
  let dir = @fs.tmpdir(prefix="mt-fs3.")
  let a = @file.FileStore::open("user", dir)
  a.set("user:T:gone", session_payload("u1", FAR), FAR)
  a.set("user:T:take", "v=1|login=u1", FAR)
  a.del(["user:T:gone"])
  let taken = a.get_and_del("user:T:take")
  assert_true(taken is Some(_))
  let b = @file.FileStore::open("user", dir)
  assert_eq(b.get("user:T:gone"), None)
  assert_eq(b.get("user:T:take"), None)
  assert_eq(b.persisted_size(), 0)
  @fs.rmdir(dir, recursive=true)
}

///|
async test "FS4 意图补丁也落盘：重开后族键与在线枚举都在" {
  let dir = @fs.tmpdir(prefix="mt-fs4.")
  let a = @file.FileStore::open("user", dir)
  a.set("user:T:tok1", session_payload("u1", FAR), FAR)
  a.apply(@port.AddToken("u1", @port.Device::of("pc"), "tok1", FAR, 1_000_000L))
  let b = @file.FileStore::open("user", dir)
  match b.get(family_key("u1")) {
    None => fail("族键没落盘")
    Some(text) => assert_true(text.contains("tok1"))
  }
  let page = b.list_sessions(@port.SessionFilter::all(), "", 10)
  assert_eq(page.items.length(), 1)
  assert_eq(page.items[0].token, "tok1")
  @fs.rmdir(dir, recursive=true)
}

///|
async test "FS5 同目录不同 realm 互不认也互不删" {
  let dir = @fs.tmpdir(prefix="mt-fs5.")
  let user = @file.FileStore::open("user", dir)
  user.set("user:T:tok1", session_payload("u1", FAR), FAR)
  let admin = @file.FileStore::open("admin", dir)
  admin.set("admin:T:tok1", session_payload("a1", FAR), FAR)
  assert_eq(admin.get("user:T:tok1"), None)
  assert_eq(admin.get("admin:T:tok1"), Some(session_payload("a1", FAR)))
  // 重新打开 user 那一侧：它自己的键还在，也没把 admin 的文件吃掉
  let again = @file.FileStore::open("user", dir)
  assert_eq(again.persisted_size(), 1)
  assert_eq(file_count(dir), 3)
  @fs.rmdir(dir, recursive=true)
}

///|
async test "FS6 库里自动写 .gitignore（会话数据不该进 git）" {
  let dir = @fs.tmpdir(prefix="mt-fs6.")
  let a = @file.FileStore::open("user", dir)
  a.set("user:T:x", "v=1", 0L)
  let text = (@fs.read_file(dir + "/.gitignore")).text()
  assert_eq(text, "*\n")
  @fs.rmdir(dir, recursive=true)
}

///|
async test "FS7 上次被中途杀掉留下的 .tmp 残骸，重开时清掉且不载入" {
  let dir = @fs.tmpdir(prefix="mt-fs7.")
  @fs.write_file(dir + "/userTx.0000000000000000.tmp", "半截载荷")
  let a = @file.FileStore::open("user", dir)
  assert_eq(a.persisted_size(), 0)
  assert_eq(file_count(dir), 1)
  @fs.rmdir(dir, recursive=true)
}

///|
/// FS8 语义等价抽查：同一串操作打在内存版与文件版上，读出必须逐项相同。
/// 这一条是"写穿透层不另起一套语义"的护栏，不是锦上添花。
async test "FS8 与内存版逐项同判据" {
  let dir = @fs.tmpdir(prefix="mt-fs8.")
  let mem = @mem.MemoryStore::new("user")
  let file = @file.FileStore::open("user", dir)
  mem.set("user:T:t1", session_payload("u1", FAR), FAR)
  file.set("user:T:t1", session_payload("u1", FAR), FAR)
  mem.set("user:T:t2", session_payload("u1", FAR), FAR)
  file.set("user:T:t2", session_payload("u1", FAR), FAR)
  mem.set("user:S:u1", "v=1|login=u1", 0L)
  file.set("user:S:u1", "v=1|login=u1", 0L)
  let patches : Array[@port.FamilyPatch] = [
    @port.AddToken("u1", @port.Device::of("pc"), "t1", FAR, 1_000_000L),
    @port.AddToken("u1", @port.Device::of("app"), "t2", FAR, 1_100_000L),
    @port.MarkStatus(["t1"], @port.Kicked, SWEEP_NOW),
    @port.TouchExpire(["t2"], FAR),
    @port.RemoveTokens("u1", ["t2"]),
    @port.RemoveKeys(["user:S:u1"]),
  ]
  for patch in patches {
    mem.apply(patch)
    file.apply(patch)
  }
  let keys = ["user:T:t1", "user:T:t2", family_key("u1"), "user:S:u1"]
  let m = mem.get_many(keys)
  let f = file.get_many(keys)
  for i in 0..<keys.length() {
    assert_eq(
      f[i].1,
      m[i].1,
      msg="第 " + i.to_string() + " 项两侧不一致：" + keys[i],
    )
  }
  assert_eq(
    file.list_sessions(@port.SessionFilter::all(), "", 10).items.length(),
    mem.list_sessions(@port.SessionFilter::all(), "", 10).items.length(),
  )
  @fs.rmdir(dir, recursive=true)
}

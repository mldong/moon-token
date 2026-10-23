///|
const STORAGE_FAR : Int64 = 4_000_000_000_000L

///|
fn storage_session(expire_at : Int64) -> String {
  @port.SessionRecord::make("u1", @port.Device::of("pc"), 100L, expire_at).encode()
}

///|
test "MS1 lookup retains only owned expired active token records" {
  let store = MemoryStore::new("a")
  let token = store.keys.token("own")
  let other = store.keys.account_session("data:T:embedded")
  let foreign = @port.KeySpace::of("b").token("foreign")
  for key in [token, other, foreign] {
    store.put(key, storage_session(1L), 1L)
  }
  assert_true(store.lookup(token) is Some(_))
  assert_eq(store.lookup(other), None)
  assert_eq(store.lookup(foreign), None)
  assert_eq(store.size(), 1)
}

///|
test "MS2 sweep prunes only owned family keys" {
  let store = MemoryStore::new("a")
  let family = @port.FamilyRecord::make("u1", 1L, [
    @port.FamilyMember::make(
      @port.Device::of("pc"),
      "absent",
      STORAGE_FAR,
      100L,
    ),
  ]).encode()
  let own = store.keys.family("u1")
  let other = store.keys.account_session("data:A:embedded")
  let foreign = @port.KeySpace::of("b").family("u1")
  for key in [own, other, foreign] {
    store.put(key, family, STORAGE_FAR)
  }
  assert_eq(store.sweep_at(2L), 1)
  assert_eq(store.lookup(own), None)
  assert_eq(store.lookup(other), Some(family))
  assert_eq(store.lookup(foreign), Some(family))
}

///|
test "MS3 nested realm session listing excludes parent token lookalikes" {
  let store = MemoryStore::new("a:T:x")
  store.put(store.keys.token("own"), storage_session(STORAGE_FAR), STORAGE_FAR)
  store.put(
    @port.KeySpace::of("a").token("x:T:foreign"),
    storage_session(STORAGE_FAR),
    STORAGE_FAR,
  )
  let page = store.scan_sessions(@port.SessionFilter::all(), "", 10)
  assert_eq(page.items.length(), 1)
  assert_eq(page.items[0].token, "own")
}

///|
test "MS4 TouchExpire keeps logical expiry separate from explicit key expiry" {
  let store = MemoryStore::new("user")
  let key = store.keys.token("t")
  let device = @port.Device::of("pc")
  let logical = STORAGE_FAR - 10_000L
  store.put(key, storage_session(logical - 10_000L), logical - 5_000L)
  store.apply_patch(@port.AddToken("u1", device, "t", logical - 10_000L, 100L))
  for physical in [STORAGE_FAR, STORAGE_FAR, STORAGE_FAR - 100L, 0L] {
    store.apply_patch(
      @port.TouchExpire("u1", device, "t", logical, 100L, physical),
    )
    let entry = store.entries.get(key).unwrap()
    assert_eq(entry.expire_at, physical)
    let session = @port.SessionRecord::decode(entry.payload).unwrap()
    assert_eq(session.expire_at, logical)
    assert_true(session.status.same(@port.Active))
    let family = store.load_family("u1")
    assert_eq(family.version, 1L)
    assert_eq(family.members.length(), 1)
    assert_eq(family.members[0].expire_at, logical)
    assert_eq(family.members[0].login_time, 100L)
    assert_eq(
      store.entries.get(store.keys.family("u1")).unwrap().expire_at,
      logical,
    )
  }
  store.apply_patch(@port.TouchExpire("u1", device, "t", 0L, 100L, 0L))
  let persistent = store.entries.get(key).unwrap()
  assert_eq(persistent.expire_at, 0L)
  assert_eq(@port.SessionRecord::decode(persistent.payload).unwrap().expire_at, 0L)
  assert_eq(store.load_family("u1").members[0].expire_at, 0L)
}

///|
test "MS5 TouchExpire repairs a missing family without overwriting a prewritten retention window" {
  let store = MemoryStore::new("user")
  let key = store.keys.token("t")
  let logical = STORAGE_FAR - 20_000L
  store.put(key, storage_session(logical), STORAGE_FAR)
  let patch = @port.TouchExpire(
    "u1",
    @port.Device::of("pc"),
    "t",
    logical,
    100L,
    STORAGE_FAR,
  )
  store.apply_patch(patch)
  store.apply_patch(patch)
  assert_eq(store.entries.get(key).unwrap().expire_at, STORAGE_FAR)
  let family = store.load_family("u1")
  assert_eq(family.members.length(), 1)
  assert_eq(family.members[0].expire_at, logical)
  assert_eq(family.members[0].device.id, "pc")
  assert_eq(family.members[0].login_time, 100L)
  assert_eq(family.version, 1L)
  assert_eq(store.sweep_at(logical), 1)
  assert_true(store.lookup(key) is Some(_))
  assert_eq(store.sweep_at(STORAGE_FAR), 1)
  assert_eq(store.lookup(key), None)
}

///|
test "MS6 MarkStatus uses the deadline for both logical and physical expiry" {
  for status in [@port.Kicked, @port.Superseded] {
    let store = MemoryStore::new("user")
    let key = store.keys.token("t")
    let deadline = STORAGE_FAR - 10_000L
    store.put(key, storage_session(STORAGE_FAR), STORAGE_FAR + 10_000L)
    store.apply_patch(@port.MarkStatus(["t"], status, deadline))
    store.apply_patch(@port.MarkStatus(["t"], status, deadline))
    let entry = store.entries.get(key).unwrap()
    assert_eq(entry.expire_at, deadline)
    let session = @port.SessionRecord::decode(entry.payload).unwrap()
    assert_eq(session.expire_at, deadline)
    assert_true(session.status.same(status))
    assert_eq(store.sweep_at(deadline - 1L), 0)
    assert_eq(store.sweep_at(deadline), 1)
    assert_eq(store.lookup(key), None)
  }
}

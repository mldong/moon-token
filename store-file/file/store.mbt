///|
/// 文件后端：**内存为主 + 写穿透**。
///
/// 判据来源是探针（`G:\dev-tools\tmp\moon-file-probe`，可复跑）而不是想象：
/// - wasm(moonrun) 上 mkdir / 写 / 读 / rename(replace) / readdir / remove 全部可用；
/// - 每次写都 fsync 的代价实测约 36 ms/次，NoSync 约 0.5 ms/次，差 45 倍 ⇒ 默认 NoSync，
///   `durable=true` 才加 fsync。进程崩了不丢（写穿透已落 OS 页缓存），整机断电才丢最后几页；
/// - 启动扫 200 个键约 2 ms ⇒ 冷启动全量载入是免费的，读路径因此可以完全不碰磁盘。
///
/// 为什么是"包一层 MemoryStore"而不是另写一套存储：惰性判过期、`apply` 幂等、
/// 族↔会话一致性收敛这些语义已经在内存版里被用例钉住了，重写一遍就是给同一个问题养第二套语义。
/// 这一层只做三件事：启动时把盘上的键读回内存、每次变更后把**变化过的键**写盘、
/// 内存里没了的键把文件删掉。

///|
pub struct FileStore {
  mem : @mem.MemoryStore
  dir : String
  realm : String
  /// 上一次落盘时的条目镜像，用来算 diff（只写真正变过的键）
  persisted : Map[String, @mem.Entry]
  durable : Bool
}

///|
fn envelope_of(key : String, entry : @mem.Entry) -> String {
  @port.encode_record([
    ("exp", entry.expire_at.to_string()),
    ("key", key),
    ("data", entry.payload),
  ])
}

///|
/// 认键靠文件里的 `key` 字段，不靠文件名（文件名可能被别的程序改花）。
fn parse_envelope(text : String) -> (String, @mem.Entry)? {
  match @port.decode_record(text) {
    None => None
    Some(fields) => {
      let key = @port.record_field_or(fields, "key", "")
      let payload = @port.record_field_or(fields, "data", "")
      if key.is_empty() {
        None
      } else {
        let entry = @mem.Entry::make(payload, @port.record_field_int64(fields, "exp"))
        Some((key, entry))
      }
    }
  }
}

///|
fn path_of(dir : String, key : String) -> String {
  dir + "/" + file_name(key)
}

///|
/// 落一个键：先写 `.tmp` 再 rename 覆盖。探针实测这条路在 Windows 与 Linux 都成立，
/// 而"直接写目标文件"在进程中途被杀时会留下半截载荷。
async fn FileStore::write_entry(
  self : FileStore,
  key : String,
  entry : @mem.Entry,
) -> Unit raise @port.TokenError {
  let target = path_of(self.dir, key)
  let tmp = target + ".tmp"
  let mode : @fs.SyncMode = if self.durable {
    @fs.Data
  } else {
    @fs.NoSync
  }
  try {
    @fs.write_file(tmp, envelope_of(key, entry), sync=mode)
    @fs.rename(tmp, target, replace=true)
  } catch {
    err => raise @port.Store("写键 " + key + " 失败：\{err}")
  }
  self.persisted[key] = entry
}

///|
async fn FileStore::drop_file(self : FileStore, key : String) -> Unit raise @port.TokenError {
  try {
    @fs.remove(path_of(self.dir, key))
  } catch {
    err => raise @port.Store("删键 " + key + " 失败：\{err}")
  }
  self.persisted.remove(key) |> ignore
}

///|
/// 把内存与盘面对齐：只写变过的，只删没的。
/// 每次变更后都跑一遍，所以"读路径顺手回收的过期键"（`lookup` 会当场删内存条目）
/// 也会在下一次写时把文件带走，不留复活素材。
async fn FileStore::flush(self : FileStore) -> Unit raise @port.TokenError {
  let current = self.mem.entries
  let changed : Array[(String, @mem.Entry)] = []
  for (key, entry) in current {
    let dirty = match self.persisted.get(key) {
      None => true
      Some(old) => old.payload != entry.payload || old.expire_at != entry.expire_at
    }
    if dirty {
      changed.push((key, entry))
    }
  }
  let gone : Array[String] = []
  for (key, _) in self.persisted.to_array() {
    match current.get(key) {
      None => gone.push(key)
      Some(_) => ()
    }
  }
  for (key, entry) in changed {
    self.write_entry(key, entry)
  }
  for key in gone {
    self.drop_file(key)
  }
}

///|
/// 打开一个文件后端：建目录、防污染地写一份 `.gitignore`、把盘上还活着的键读回内存。
/// `dir` 必填——库不替用户决定会话数据落在哪。要一个"不进 git"的默认位置，
/// 传 `@fs.tmpdir(prefix=~"moon-token.")` 的结果即可（README 与 docs/file-store.md 有示例）。
/// `durable=true` 时每次写加 fsync（实测约 36 ms/次，默认关）。
pub async fn FileStore::open(
  realm : String,
  dir : String,
  durable? : Bool = false,
) -> FileStore raise @port.TokenError {
  let store : FileStore = {
    mem: @mem.MemoryStore::new(realm),
    dir,
    realm,
    persisted: Map([]),
    durable: durable,
  }
  try {
    @fs.mkdir(dir, recursive=true, allow_exist=true)
  } catch {
    err => raise @port.Store("建数据目录 " + dir + " 失败：\{err}")
  }
  let gitignore = dir + "/.gitignore"
  let have_ignore = try {
    (@fs.read_file(gitignore)).text() |> ignore
    true
  } catch {
    _ => false
  }
  if !have_ignore {
    try {
      @fs.write_file(gitignore, "*\n")
    } catch {
      err => raise @port.Store("写 .gitignore 失败：\{err}")
    }
  }
  store.load_from_disk()
  store
}

///|
/// 冷启动载入。**刻意不在这里判过期**：过期与否由内存版那一条惰性判活路径裁决
/// （`get` 读到过期即回收、`sweep` 批量收），载入这一步一次时间都不读。
/// 理由是用例实测出来的：在同一个测试二进制里，包外测试设置的注入时钟与包内实现读到的
/// 全局时钟槽不是同一份状态，载入时自判一次就等于给"现在几点"引入第二个源，
/// 结果是活键被当过期删掉。语义交给内存版之后，这类分叉不存在。
///
/// 认两条：① 键必须落在本 realm 前缀下；② 文件名必须与键应派生出的名字一致
/// （被人挪动过、或哈希撞名的文件直接跳过，宁可少认一条会话也不认错人）。
async fn FileStore::load_from_disk(self : FileStore) -> Unit raise @port.TokenError {
  let names = try {
    @fs.readdir(self.dir, sort=true)
  } catch {
    err => raise @port.Store("扫数据目录失败：\{err}")
  }
  let owned = self.realm + ":"
  for name in names {
    if name == ".gitignore" {
      ()
    } else if name.has_suffix(".tmp") {
      // 上一次进程被中途杀掉留下的半截临时文件：直接清掉，不参与判定
      try {
        @fs.remove(self.dir + "/" + name)
      } catch {
        err => raise @port.Store("清临时文件 " + name + " 失败：\{err}")
      }
    } else {
      let path = self.dir + "/" + name
      let text = try {
        Some((@fs.read_file(path)).text())
      } catch {
        _ => None
      }
      match text {
        None => ()
        Some(body) => match parse_envelope(body) {
          None => ()
          Some((key, entry)) =>
            if !key.has_prefix(owned) || file_name(key) != name {
              ()
            } else {
              self.mem.put(key, entry.payload, entry.expire_at)
              self.persisted[key] = entry
            }
        }
      }
    }
  }
}

///|
/// 盘上现有键的条数（给"重启不丢"这类断言用，也便于排障时核对差异）
pub fn FileStore::persisted_size(self : FileStore) -> Int {
  self.persisted.length()
}

///|
pub fn FileStore::dir_of(self : FileStore) -> String {
  self.dir
}

///|
pub impl @port.TokenStore for FileStore with fn get(self, key) {
  self.mem.get(key)
}

///|
pub impl @port.TokenStore for FileStore with fn get_many(self, keys) {
  self.mem.get_many(keys)
}

///|
pub impl @port.TokenStore for FileStore with fn list_sessions(
  self,
  filter,
  cursor,
  limit,
) {
  self.mem.list_sessions(filter, cursor, limit)
}

///|
pub impl @port.TokenStore for FileStore with fn set(self, key, payload, expire_at) {
  self.mem.set(key, payload, expire_at)
  self.flush()
}

///|
pub impl @port.TokenStore for FileStore with fn del(self, keys) {
  self.mem.del(keys)
  self.flush()
}

///|
pub impl @port.TokenStore for FileStore with fn get_and_del(self, key) {
  let value = self.mem.get_and_del(key)
  self.flush()
  value
}

///|
pub impl @port.TokenStore for FileStore with fn apply(self, patch) {
  self.mem.apply(patch)
  self.flush()
}

///|
pub impl @port.TokenStore for FileStore with fn sweep(self, now) {
  let n = self.mem.sweep(now)
  self.flush()
  n
}

///|
/// trait 方法升成常规方法要显式写出来，否则吃 implicit_impl_as_method 弃用警告
/// （内存版同款做法，见 `store/memory/memory.mbt` 末尾）。
pub extend FileStore with @port.TokenStore::{
  get,
  get_many,
  list_sessions,
  set,
  del,
  get_and_del,
  apply,
  sweep,
}

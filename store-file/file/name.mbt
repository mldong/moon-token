///|
/// 文件名派生。**原始键绝不直接当文件名**：探针实测在 Windows 上键里的 `:` 会让落盘名被截断
/// （写 `probe:tail` 之后 readdir 只看到 `probe`，不报错、数据错位），`* ? < > |` 直接被系统拒，
/// `\` 还会被当路径分隔符。所以文件名只由"可读前缀 + 两条哈希 lane"组成，
/// 真正的键写在文件内容里（`store.mbt` 信封的 `key` 字段）。

///|
const MOD32 : Int64 = 4294967296L

const PRIME : Int64 = 16777619L

///|
let hex_digits : Array[String] = [
  "0", "1", "2", "3", "4", "5", "6", "7",
  "8", "9", "a", "b", "c", "d", "e", "f",
]

///|
/// 只留这些字符进可读前缀，其余不算前缀的一部分
fn is_name_safe(ch : Char) -> Bool {
  (ch >= 'a' && ch <= 'z') ||
    (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-'
}

///|
/// 取键里前 `limit` 个安全字符当可读前缀：目录里一眼能看出是哪一类键，排查省时间。
/// 纯装饰，认键靠文件内容里的 `key`，不靠这个名字。
fn head_of(key : String, limit : Int) -> String {
  let out = StringBuilder()
  let mut taken = 0
  for ch in key {
    if taken < limit && is_name_safe(ch) {
      out.write_char(ch)
      taken += 1
    }
  }
  if taken == 0 {
    "k"
  } else {
    out.to_string()
  }
}

///|
/// FNV-1a 的 32 位版。刻意只用普通乘除加取模，一步一掩码，理由有两个：
/// ① 不碰 wrap 语义也不在 Int64 上溢出（`h` 恒 < 2^32，乘 16777619 约 2^56，离 2^63 远）；
/// ② 同一个键在 wasm32/wasm64/native/js 上必须得到同一个文件名，
///    否则换个档跑就把数据留在地上认不回来（Int 位宽随目标变，Int64 不变）。
fn lane_a(seed : Int64, key : String) -> Int64 {
  let mut h = seed % MOD32
  for ch in key {
    h = ((h ^ ch.to_int().to_int64()) * PRIME) % MOD32
  }
  h
}

///|
/// 第二条 lane 用不同的混合次序（先乘后加）与不同种子，与 lane_a 相互独立
fn lane_b(seed : Int64, key : String) -> Int64 {
  let mut h = (seed + 7L) % MOD32
  for ch in key {
    h = ((h * PRIME) + ch.to_int().to_int64()) % MOD32
  }
  h
}

///|
fn hex8(v : Int64) -> String {
  let out = StringBuilder()
  let mut shift = 28
  while shift >= 0 {
    let nibble = (v >> shift) & 0xFL
    out.write_string(hex_digits[nibble.to_int()])
    shift -= 4
  }
  out.to_string()
}

///|
/// 两条 lane 拼成 16 位十六进制（64 位空间）。万级键的生日碰撞概率约 2.7e-11，
/// 可以当"不会撞"处理；真撞了也不静默：载入时校验文件里的 `key` 派生出的名字与实际文件名一致，
/// 不一致就跳过那个文件（宁可少认一条会话，也不要认错人）。
fn file_name(key : String) -> String {
  let a = lane_a(2166136261L, key)
  let b = lane_b(4224542477L, key)
  head_of(key, 20) + "." + hex8((a ^ b) % MOD32) + hex8((a + b) % MOD32)
}

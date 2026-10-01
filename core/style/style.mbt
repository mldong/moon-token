///|
/// token 风格（值对象工厂端口，sync 小 SPI = 闭包组）。
/// **熵源纪律**（设计文档 §7.1/§7.2 的三档实测结论）：
/// · wasm 档有平台熵（`@env.rand(32)=Some`，跨进程三次首值全不同）⇒ 默认档可用；
/// · wasm-gc 档无熵，且 `@random.Rand::new()` 在无熵时**静默回落硬编码种子**
///   （实测两次序列完全相同）⇒ 必须先守卫、拿不到熵就 `abort`，绝不静默回落；
/// · Windows native 需 MSVC 运行时（MinGW 下 `rand_s` 编不过）⇒ 由 CI 的档覆盖。
/// core 提供的是 **ChaCha8（8 轮变体）**，对外不宣称等同 ChaCha20 强度。
const ALPHABET : String = "abcdefghijklmnopqrstuvwxyz012345"

///|
pub const DEFAULT_TOKEN_CHARS : Int = 40

///|
pub(all) struct TokenStyleFns {
  generate : () -> String
  verify_shape : (String) -> Bool
}

///|
/// 无平台熵即响亮失败（wasm-gc 档会走到这里）
pub fn require_platform_entropy() -> Unit {
  match @env.rand(0) {
    Some(_) => ()
    None =>
      abort(
        "moon-token: no platform entropy; refuse to generate predictable tokens",
      )
  }
}

///|
pub fn token_chars(len : Int) -> Int {
  if len <= 0 {
    DEFAULT_TOKEN_CHARS
  } else {
    len
  }
}

///|
fn alphabet_at(index : Int) -> Char {
  let chars = ALPHABET.to_array()
  chars[index]
}

///|
/// 从随机流取字符拼 token（32 字符表，URL 安全、无填充歧义）
fn draw(source : @random.Rand, len : Int) -> String {
  let buf = StringBuilder()
  let mut taken = 0
  while taken < len {
    buf.write_char(alphabet_at(source.int(limit=32)))
    taken += 1
  }
  buf.to_string()
}

///|
pub fn verify_token(token : String, len : Int) -> Bool {
  if token.length() != token_chars(len) {
    false
  } else {
    let alphabet_chars = ALPHABET.to_array()
    token.to_array().all((ch : Char) => alphabet_chars.contains(ch))
  }
}

///|
fn build_style(source : @random.Rand, size : Int) -> TokenStyleFns {
  let fns : TokenStyleFns = {
    generate: fn() { draw(source, size) },
    verify_shape: fn(token) { verify_token(token, size) },
  }
  fns
}

///|
/// 默认档：平台熵播种的 ChaCha8 流。无熵即 abort（不静默回落固定种子）。
pub fn opaque_style(len? : Int = DEFAULT_TOKEN_CHARS) -> TokenStyleFns {
  require_platform_entropy()
  build_style(@random.Rand::new(), token_chars(len))
}

///|
/// 可复现档：显式 32 字节种子（测试与夹具用）。长度不合即由 core abort（响亮失败）。
pub fn opaque_style_with_seed(
  seed : Bytes,
  len? : Int = DEFAULT_TOKEN_CHARS,
) -> TokenStyleFns {
  build_style(@random.Rand::chacha8(seed~), token_chars(len))
}

///|
/// 宿主自带 CSPRNG 档（wasm-gc 环境、HSM、自行混熵的场景）
pub fn opaque_style_with(
  entropy : () -> Bytes,
  len? : Int = DEFAULT_TOKEN_CHARS,
) -> TokenStyleFns {
  let seed = entropy()
  if seed.length() != 32 {
    abort("moon-token: entropy provider must return 32 bytes")
  }
  build_style(@random.Rand::chacha8(seed~), token_chars(len))
}

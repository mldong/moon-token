///|
/// 紧凑记录编解码：`k=v|k=v`，键与值都做过转义，因此任何字符（含分隔符、中文、JSON 片段、
/// 换行）都能安全往返。**数值以十进制字符串承载**，避开浮点精度坑。
/// 自带实现而不依赖序列化宏：v2 换 Redis/moondb 时 payload 形状不变。
pub const SCHEMA_VERSION : String = "1"

///|
pub fn escape(s : String) -> String {
  let out = StringBuilder()
  for ch in s {
    if ch == '\\' {
      out.write_string("\\\\")
    } else if ch == '|' {
      out.write_string("\\p")
    } else if ch == '=' {
      out.write_string("\\e")
    } else if ch == '&' {
      out.write_string("\\a")
    } else if ch == ';' {
      out.write_string("\\s")
    } else if ch == '\n' {
      out.write_string("\\n")
    } else {
      out.write_char(ch)
    }
  }
  out.to_string()
}

///|
/// 反 escaping 是全集函数：无法识别的转义序列按字面回填，绝不吞字符。
pub fn unescape(s : String) -> String {
  let out = StringBuilder()
  let mut pending = false
  for ch in s {
    if pending {
      pending = false
      if ch == '\\' {
        out.write_string("\\")
      } else if ch == 'p' {
        out.write_string("|")
      } else if ch == 'e' {
        out.write_string("=")
      } else if ch == 'a' {
        out.write_string("&")
      } else if ch == 's' {
        out.write_string(";")
      } else if ch == 'n' {
        out.write_string("\n")
      } else {
        out.write_string("\\")
        out.write_char(ch)
      }
    } else if ch == '\\' {
      pending = true
    } else {
      out.write_char(ch)
    }
  }
  if pending {
    out.write_string("\\")
  }
  out.to_string()
}

///|
/// 按单个分隔字符切开（不丢空段）
pub fn split_by(s : String, sep : Char) -> Array[String] {
  let parts : Array[String] = []
  let mut buf = StringBuilder()
  for ch in s {
    if ch == sep {
      parts.push(buf.to_string())
      buf = StringBuilder()
    } else {
      buf.write_char(ch)
    }
  }
  parts.push(buf.to_string())
  parts
}

///|
/// 十进制串 → Int64（自带实现：不依赖版本间漂移的 String 解析扩展，且能明确拒绝空串/杂字符）
pub fn parse_int64(s : String) -> Int64? {
  let mut acc : Int64 = 0L
  let mut negative = false
  let mut seen_digit = false
  let mut at_head = true
  for ch in s {
    if at_head && (ch == '-' || ch == '+') {
      negative = ch == '-'
      at_head = false
      continue
    }
    at_head = false
    let digit : Int64 = match ch {
      '0' => 0L
      '1' => 1L
      '2' => 2L
      '3' => 3L
      '4' => 4L
      '5' => 5L
      '6' => 6L
      '7' => 7L
      '8' => 8L
      '9' => 9L
      _ => return None
    }
    acc = acc * 10L + digit
    seen_digit = true
  }
  if !seen_digit {
    None
  } else if negative {
    Some(0L - acc)
  } else {
    Some(acc)
  }
}

///|
pub fn encode_record(fields : Array[(String, String)]) -> String {
  let buf = StringBuilder()
  buf.write_string("v=")
  buf.write_string(SCHEMA_VERSION)
  for (k, v) in fields {
    buf.write_string("|")
    buf.write_string(escape(k))
    buf.write_string("=")
    buf.write_string(escape(v))
  }
  buf.to_string()
}

///|
/// 解码记录；形状不合（首段不是 `v=`、段内 `=` 数量不对）返回 None，由调用方决定报什么错。
pub fn decode_record(text : String) -> Map[String, String]? {
  let fields : Map[String, String] = Map([])
  let segments = split_by(text, '|')
  let mut checked_version = false
  for segment in segments {
    // 键与值都做过转义，所以段内只剩一个裸 `=`（分隔符本身）
    let kv = split_by(segment, '=')
    if kv.length() != 2 {
      return None
    }
    let key = unescape(kv[0])
    let value = unescape(kv[1])
    if !checked_version {
      if key != "v" {
        // 首段必须是 schema 版本号，否则视为不认识的形状
        return None
      }
      checked_version = true
    } else {
      fields[key] = value
    }
  }
  Some(fields)
}

///|
pub fn record_field_or(fields : Map[String, String], key : String, fallback : String) -> String {
  match fields.get(key) {
    None => fallback
    Some(v) => v
  }
}

///|
/// 取整型字段；缺失或形状不合按 0（0 的语义＝"不过期/未设置"，调用方另有把关）
pub fn record_field_int64(fields : Map[String, String], key : String) -> Int64 {
  match fields.get(key) {
    None => 0L
    Some(raw) =>
      match parse_int64(raw) {
        None => 0L
        Some(v) => v
      }
  }
}

///|
/// 列表承载：成员各自是编码过的记录，转义后以 `;` 连接（转义已保证成员内不含裸 `;`）。
pub fn encode_list(items : Array[String]) -> String {
  let mut first = true
  let buf = StringBuilder()
  for item in items {
    if !first {
      buf.write_string(";")
    }
    first = false
    buf.write_string(escape(item))
  }
  buf.to_string()
}

///|
pub fn decode_list(blob : String) -> Array[String] {
  if blob.is_empty() {
    []
  } else {
    split_by(blob, ';').map(unescape)
  }
}

///|
/// 渲染原语：转义、路由拆分、版式与表格。服务端直出 HTML，零前端构建、零模板引擎。
/// 本工具链只有**双引号单行**字符串字面量（`'x'` 只能当 Char，`'''`/`"""` 都不存在），
/// 所以 HTML 里的属性一律用单引号写，字符串拼接一律走 StringBuilder——这是这个文件写法
/// 和别的语言不一样的原因。

///|
pub fn esc(s : String) -> String {
  let out = StringBuilder()
  for ch in s {
    if ch == '<' {
      out.write_string("&lt;")
    } else if ch == '>' {
      out.write_string("&gt;")
    } else if ch == '&' {
      out.write_string("&amp;")
    } else if ch == '"' {
      out.write_string("&quot;")
    } else if ch == '\'' {
      out.write_string("&#39;")
    } else {
      out.write_char(ch)
    }
  }
  out.to_string()
}

///|
/// `Request.path` 带完整请求目标（含 `?a=1&b=2`）——parser 实测只按空格切，故这里自己拆。
/// 查询值按字面取用：演示站的输入项全是 select 里的固定 ASCII 值，不做 percent 解码。
pub fn split_path_query(target : String) -> (String, Map[String, String]) {
  let parts = @port.split_by(target, '?')
  let route = parts[0]
  let params : Map[String, String] = Map([])
  if parts.length() > 1 {
    for pair in @port.split_by(parts[1], '&') {
      let kv = @port.split_by(pair, '=')
      if kv.length() == 2 {
        params[kv[0]] = kv[1]
      } else if kv.length() == 1 && !kv[0].is_empty() {
        params[kv[0]] = ""
      }
    }
  }
  (route, params)
}

///|
pub fn param(
  params : Map[String, String],
  key : String,
  fallback : String,
) -> String {
  match params.get(key) {
    None => fallback
    Some(v) => v
  }
}

///|
pub fn fmt_left(ms : Int64) -> String {
  if ms < 0L {
    "不过期"
  } else if ms == 0L {
    "已到期"
  } else if ms < 60_000L {
    (ms / 1000L).to_string() + "s"
  } else if ms < 3_600_000L {
    (ms / 60_000L).to_string() + "min"
  } else {
    (ms / 3_600_000L).to_string() +
    "h" +
    (ms % 3_600_000L / 60_000L).to_string() +
    "m"
  }
}

///|
/// 本工具链的 `const` 只收原始类型，故样式行以函数给出
fn css_lines() -> Array[String] {
  [
    "body{font:14px/1.65 ui-monospace,Consolas,monospace;margin:0;color:#14171a;background:#f6f7f9}",
    "header{background:#14171a;color:#fff;padding:14px 22px}", "header a{color:#cfd6dd;text-decoration:none;margin-right:16px}",
    "header a:hover{color:#fff}", "main{padding:20px 22px 44px;max-width:1180px}",
    "h1{font-size:19px;margin:0 0 4px}", "h2{font-size:15px;margin:26px 0 8px;color:#34404b}",
    ".sub{color:#6c7885;font-size:12px;margin:0 0 18px}", ".badge{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;background:#e7efff;color:#23406e}",
    ".badge.warn{background:#ffeede;color:#7a4512}", "table{border-collapse:collapse;width:100%;background:#fff;font-size:13px}",
    "th,td{border-bottom:1px solid #e6e9ed;padding:6px 9px;text-align:left;vertical-align:top}",
    "th{background:#eef1f4;font-weight:600}", ".cards{display:flex;gap:14px;flex-wrap:wrap}",
    ".card{background:#fff;border:1px solid #e2e6ea;border-radius:8px;padding:12px 14px;min-width:200px}",
    ".card b{font-size:22px}", "pre{background:#14171a;color:#dfe6ee;padding:12px 14px;border-radius:8px;overflow-x:auto;font-size:12.5px}",
    "form{display:flex;gap:10px;align-items:center;flex-wrap:wrap;background:#fff;border:1px solid #e2e6ea;border-radius:8px;padding:10px 12px;margin:0 0 16px}",
    "input,select,button{font:inherit;padding:4px 8px;border:1px solid #c9d0d7;border-radius:5px;background:#fff;color:inherit}",
    "button{background:#14171a;color:#fff;border:0;cursor:pointer}", ".btns{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:14px}",
    ".btns a{text-decoration:none;background:#fff;border:1px solid #c9d0d7;border-radius:5px;padding:4px 10px}",
    ".dim{color:#6c7885}", "li{margin:2px 0}",
  ]
}

///|
fn css() -> String {
  let buf = StringBuilder()
  for line in css_lines() {
    buf.write_string(line)
    buf.write_string("\n")
  }
  buf.to_string()
}

///|
fn nav(route : String) -> String {
  let items = [
    ("/", "总览"),
    ("/sessions", "键位矩阵"),
    ("/play", "剧本剧场"),
    ("/guard", "守卫模拟"),
    ("/events", "事件流"),
    ("/clock", "时间机器"),
    ("/login", "登录台"),
    ("/api-demo", "受保护 API"),
  ]
  let buf = StringBuilder()
  for (path, label) in items {
    if path == route {
      buf.write_string(
        "<a href='" +
        path +
        "' style='color:#fff;font-weight:700'>" +
        label +
        "</a>",
      )
    } else {
      buf.write_string("<a href='" + path + "'>" + label + "</a>")
    }
  }
  buf.to_string()
}

///|
/// `route` 用于高亮导航条当前项，`title` 是页面标题（两者常不同：/login 的标题是「登录台」）
pub fn layout(
  route : String,
  title : String,
  subtitle : String,
  badge : String,
  body : String,
  head_extra? : String = "",
) -> String {
  let buf = StringBuilder()
  buf.write_string("<!doctype html>\n")
  buf.write_string("<html lang='zh'><head><meta charset='utf-8'>")
  buf.write_string(head_extra)
  buf.write_string("<title>" + esc(title) + " · moon-token</title>")
  buf.write_string("<style>" + css() + "</style></head>")
  buf.write_string("<body><header>")
  buf.write_string("<b>moon-token</b> 演示站 &nbsp; " + nav(route))
  buf.write_string("</header><main>")
  buf.write_string("<h1>" + esc(title) + "</h1>")
  buf.write_string("<p class='sub'>" + subtitle + "</p>")
  buf.write_string(badge)
  buf.write_string("\n")
  buf.write_string(body)
  buf.write_string("<p class='sub' style='margin-top:26px'>")
  buf.write_string(
    "库＝<code>mldong/moon-token</code> + <code>mldong/moon-token-store</code>（内存档）",
  )
  buf.write_string(
    "· 本页由 MoonBit 服务端直出，无前端构建 · 状态在进程内存里，<a href='/reset'>重置</a>即清空</p>",
  )
  buf.write_string("</main></body></html>")
  buf.to_string()
}

///|
pub fn clock_badge(clock : ClockCell) -> String {
  let label = esc(clock.mode_label())
  let now = clock.now().to_string()
  if clock.manual {
    "<p><span class='badge warn'>" +
    label +
    "</span> <span class='dim'>now=" +
    now +
    "</span></p>"
  } else {
    "<p><span class='badge'>" +
    label +
    "</span> <span class='dim'>now=" +
    now +
    "</span></p>"
  }
}

///|
/// 表格：表头转义，单元格按已渲染的 HTML 传入（链接等原样输出）
pub fn table(headers : Array[String], rows : Array[Array[String]]) -> String {
  if rows.is_empty() {
    return "<p class='dim'>（空）</p>"
  }
  let buf = StringBuilder()
  buf.write_string("<table><thead><tr>")
  for h in headers {
    buf.write_string("<th>" + esc(h) + "</th>")
  }
  buf.write_string("</tr></thead><tbody>")
  for row in rows {
    buf.write_string("<tr>")
    for cell in row {
      buf.write_string("<td>" + cell + "</td>")
    }
    buf.write_string("</tr>")
  }
  buf.write_string("</tbody></table>")
  buf.to_string()
}

///|
pub fn cards(items : Array[(String, String)]) -> String {
  let buf = StringBuilder()
  buf.write_string("<div class='cards'>")
  for (label, value) in items {
    buf.write_string(
      "<div class='card'><div class='dim'>" +
      esc(label) +
      "</div><b>" +
      esc(value) +
      "</b></div>",
    )
  }
  buf.write_string("</div>")
  buf.to_string()
}

///|
/// 预格式块：内容整体转义，用于展示调用序列与源码片段
pub fn pre_block(text : String) -> String {
  "<pre>" + esc(text) + "</pre>"
}

///|
/// 逐行拼一个 `<pre>`：本工具链没有多行字符串字面量，长段文本一律按行传进来
pub fn pre_lines(lines : Array[String]) -> String {
  let buf = StringBuilder()
  for line in lines {
    buf.write_string(line)
    buf.write_string("\n")
  }
  pre_block(buf.to_string())
}

///|
/// 有序说明段：一段一句的正文，避免把整页写成一条超长字符串
pub fn paras(lines : Array[String]) -> String {
  let buf = StringBuilder()
  for line in lines {
    buf.write_string(line)
    buf.write_string("\n")
  }
  buf.to_string()
}

///|
/// GET 表单（无 JS：所有动作都是带查询串的 GET，提交即跳转）
pub fn form(
  action : String,
  fields : Array[(String, String, Array[String])],
  submit : String,
) -> String {
  let buf = StringBuilder()
  buf.write_string("<form method='get' action='" + esc(action) + "'>")
  for (name, label, options) in fields {
    buf.write_string(
      "<label>" + esc(label) + " <select name='" + esc(name) + "'>",
    )
    for o in options {
      buf.write_string("<option value='" + esc(o) + "'>" + esc(o) + "</option>")
    }
    buf.write_string("</select></label>")
  }
  buf.write_string("<button>" + esc(submit) + "</button></form>")
  buf.to_string()
}

///|
/// 同一套字段既可做 select 也可做文本框：`inputs` 每项 = (参数名, 标签, 默认值)
pub fn text_form(
  action : String,
  inputs : Array[(String, String, String)],
  submit : String,
) -> String {
  let buf = StringBuilder()
  buf.write_string("<form method='get' action='" + esc(action) + "'>")
  for (name, label, value) in inputs {
    buf.write_string(
      "<label>" +
      esc(label) +
      " <input name='" +
      esc(name) +
      "' value='" +
      esc(value) +
      "'></label>",
    )
  }
  buf.write_string("<button>" + esc(submit) + "</button></form>")
  buf.to_string()
}

///|
pub fn buttons(items : Array[(String, String)]) -> String {
  let buf = StringBuilder()
  buf.write_string("<div class='btns'>")
  for (href, label) in items {
    buf.write_string("<a href='" + esc(href) + "'>" + esc(label) + "</a>")
  }
  buf.write_string("</div>")
  buf.to_string()
}

///|
/// moonback 适配层：把 moon-token 的"认证 + 路由权限策略"接到 moonback 的 handler 上。
///
/// 拦截点选**逐路由包装**而不是 App 级中间件：moonback 的 `add_middleware` 是 App 全局作用域，
/// 且**先于路由匹配**执行（404 与方法不匹配的路径也会先过鉴权，实测记在 hub 的复测报告里）。
/// 在中间件里按路径查权限表等于自己重做一遍路径匹配，所以这里两个入口都给：
/// `secure(handler)` 逐路由挂（推荐），`middleware()` 整模块挂（想让所有路由都受保护时用它）。
///
/// 一次受保护请求在本层只做**一次** `T:` 读：`authenticate` 拿登录号 + 授权快照，
/// 权限/角色裁决走纯函数 `check_principal`（不再回头读会话）。快照在不在盘上、什么时候问业务，
/// 都由 core 那套 `P:` 授权快照决定，本层不碰。

///|
/// 认证后的主体。业务在 handler 里用 `principal_of(req)` 取，不要自己去解析 token。
pub(all) struct Principal {
  login_id : String
  permissions : Array[String]
  roles : Array[String]
  super_admin : Bool
}

///|
pub fn Principal::make(login_id : String, record : @port.PermissionRecord) -> Principal {
  let p : Principal = {
    login_id,
    permissions: record.perms,
    roles: record.roles,
    super_admin: record.super_admin,
  }
  p
}

///|
priv extenum @mb.TypedBox += {
  MoonTokenPrincipal(Principal)
}

///|
let principal_key : @mb.TypedKey[Principal] = @mb.TypedKey(
  name="moon-token-principal",
  box=fn(p) { MoonTokenPrincipal(p) },
  unbox=fn(box) {
    match box {
      MoonTokenPrincipal(p) => Some(p)
      _ => None
    }
  },
)

///|
/// handler 里读当前登录主体。`None` 有两种含义：这条路由没挂守卫，或者它是豁免路由
/// （豁免面**没有主体**，别拿 `None` 当"未登录"用）。
pub fn principal_of(request : @mb.Request) -> Principal? {
  request.ctx.get_userdata(principal_key)
}

///|
/// 鉴权失败的默认 HTTP 状态映射。**只映射状态码，不发明业务错误码**：
/// code 表（各框架的 99990403 之类）由业务在自己的全局异常处理里转，
/// 那才是知道"这个 code 该给前端什么"的地方。要换就传 `with_on_error`。
pub fn status_of(err : @port.TokenError) -> Int {
  match err {
    @port.NotLogin(_) => 401
    @port.NotPermission(_) => 403
    @port.NotRole(_) => 403
    @port.Disabled(_, _) => 403
    @port.InvalidInput(_) => 400
    @port.Store(_) => 500
  }
}

///|
async fn default_on_error(
  _request : @mb.Request,
  responder : @mb.Responder,
  err : @port.TokenError,
) -> Unit {
  responder.send_text(err.message(), status=status_of(err))
}

///|
/// 一个 realm 一套守卫：`auth` 带配置与存储，`policy` 带豁免面与例外清单。
pub(all) struct Guard[S, P] {
  auth : @app.TokenAuth[S, P]
  policy : @core_guard.RoutePolicy
  on_error : async (@mb.Request, @mb.Responder, @port.TokenError) -> Unit
}

///|
pub fn[S, P] Guard::new(
  auth : @app.TokenAuth[S, P],
  policy : @core_guard.RoutePolicy,
) -> Guard[S, P] {
  let g : Guard[S, P] = { auth, policy, on_error: default_on_error }
  g
}

///|
/// 换掉失败响应写法（比如回自己的信封 JSON，或者把 code 交给全局异常处理去转）。
pub fn[S, P] Guard::with_on_error(
  self : Guard[S, P],
  handler : async (@mb.Request, @mb.Responder, @port.TokenError) -> Unit,
) -> Guard[S, P] {
  { auth: self.auth, policy: self.policy, on_error: handler }
}

///|
/// 判决本体：**只吃两个闭包**（取路径、取头），不碰 moonback 的 `Request`。
///
/// 这么拆有两个理由。一是 `Request` 在包外造不出来——moonback 的 `Context::new` 与
/// `ConnectionInfo` 都不是公开的，外部包想测判决就得真起一个服务器；把入参降成闭包，
/// 判决就能照 core 那套 `guard_test` 的写法直接喂假请求。二是这一层存在的意义就是
/// "一次 `T:` 读"：`authenticate` 拿登录号 + 授权快照，权限/角色裁决走纯函数
/// `check_principal`，不回头读会话——这条只能在纯函数上钉死。
///
/// `None` 只有一种来源：命中豁免面。**豁免路由没有主体**，别把 `None` 当"未登录"用。
pub async fn[S : @port.TokenStore, P : @port.PermissionProvider] decide(
  auth : @app.TokenAuth[S, P],
  policy : @core_guard.RoutePolicy,
  fns : @core_guard.RequestFns,
) -> Principal? raise @port.TokenError {
  let path = (fns.path)()
  match policy.resolve(path) {
    @core_guard.Public => None
    @core_guard.Guarded(rule) => {
      let (login_id, record) = auth.authenticate(@core_guard.extract_token(auth, fns))
      auth.check_principal(
        record,
        rule.perms,
        rule.perm_mode,
        rule.roles,
        rule.role_mode,
      )
      Some(Principal::make(login_id, record))
    }
    @core_guard.LoginOnly => {
      let (login_id, record) = auth.authenticate(@core_guard.extract_token(auth, fns))
      Some(Principal::make(login_id, record))
    }
  }
}

///|
/// 取 token 的第一/第四来源：**头优先，同名 cookie 兜底**。
/// 空串按"没有"处理（有些客户端会带一个空的 `Authorization`）。
fn header_or_cookie(
  headers : @mb.Headers,
  cookies : Map[String, String],
  name : String,
) -> String? {
  let from_header = match headers.get(name) {
    None => ""
    Some(v) => v.to_owned()
  }
  if from_header.is_empty() {
    cookies.get(name)
  } else {
    Some(from_header)
  }
}

///|
/// 单条请求的完整判定链：把 moonback 的 `Request` 供成两个闭包，再交给 `decide`。
///
/// cookie 在这里只是 token 的第四个来源（载体），裁决永远走 `TokenStore`——把"cookie 模式"
/// 做成一条不过 store 的通路，等于交付一个"改掉字符串就能冒充任何人"的对照组。
pub async fn[S : @port.TokenStore, P : @port.PermissionProvider] Guard::authorize(
  self : Guard[S, P],
  request : @mb.Request,
) -> Principal? raise @port.TokenError {
  let path = request.path.to_owned()
  let cookies = request.cookie()
  let fns : @core_guard.RequestFns = {
    path: fn() { path },
    header: fn(name) { header_or_cookie(request.headers, cookies, name) },
  }
  decide(self.auth, self.policy, fns)
}

///|
/// 包一个 handler：过不了就按 `on_error` 出响应，过了就把主体塞进请求上下文再放行。
pub fn[S : @port.TokenStore, P : @port.PermissionProvider] Guard::secure(
  self : Guard[S, P],
  handler : @mb.Handler,
) -> @mb.Handler {
  let g = self
  async fn(request, responder) {
    let decided = try {
      Ok(g.authorize(request))
    } catch {
      err => Err(err)
    }
    match decided {
      Ok(subject) => {
        match subject {
          None => ()
          Some(principal) => request.ctx.set_userdata(principal_key, principal)
        }
        handler(request, responder)
      }
      Err(err) => (g.on_error)(request, responder, err)
    }
  }
}

///|
/// 整模块形态（`ModuleContext::add_middleware` 用）。注意它是 App 全局作用域、
/// 先于路由匹配，所以逐路由 `secure` 才是默认推荐；这张表是按 path 决策的，
/// 挂全局也不会漏判，只是 404 也会先过一次鉴权。
pub fn[S : @port.TokenStore, P : @port.PermissionProvider] Guard::middleware(
  self : Guard[S, P],
) -> @mb.Middleware {
  let g = self
  @mb.Middleware(fn(h) { g.secure(h) })
}

///|
/// 注册一条受保护的 GET 路由。
pub fn[S : @port.TokenStore, P : @port.PermissionProvider] Guard::get(
  self : Guard[S, P],
  ctx : @mb.ModuleContext,
  path : String,
  handler : @mb.Handler,
) -> Unit raise @mb.RouterError {
  ctx.get(path, self.secure(handler))
}

///|
/// 注册一条受保护的 POST 路由。
pub fn[S : @port.TokenStore, P : @port.PermissionProvider] Guard::post(
  self : Guard[S, P],
  ctx : @mb.ModuleContext,
  path : String,
  handler : @mb.Handler,
) -> Unit raise @mb.RouterError {
  ctx.post(path, self.secure(handler))
}

///|
/// 任意方法（`add_route` 的转发位）。
pub fn[S : @port.TokenStore, P : @port.PermissionProvider] Guard::add(
  self : Guard[S, P],
  ctx : @mb.ModuleContext,
  meth : @http.RequestMethod,
  path : String,
  handler : @mb.Handler,
) -> Unit raise @mb.RouterError {
  ctx.add_route(meth, path, self.secure(handler))
}

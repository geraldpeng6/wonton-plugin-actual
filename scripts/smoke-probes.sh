# shellcheck shell=bash
# Actual Budget：sso=proxy（网关代填 x-actual-password）；MCP 有工具，确认标记以运行期注解为准。
SMOKE_NOTE="单用户应用，用户表没有用户名，身份按 validate 的 ADMIN + userId 断言"

web_assert() { grep -qi 'actual'; }   # 标准输入：应用真实页面

# 应用是单用户的：用户表没有用户名（userName 为空），应用侧能断言的是“认出来的是管理员本人”。
identity_check() { # 应用自己的登录 + validate 接口：认出来的是用户管理员
  SMOKE_WEB_URL="${SMOKE_WEB_URL%/}"  # 套件给的地址带尾斜杠，拼路径前剥掉，避免 // 打不进路由
  local r tok v
  r="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Content-Type: application/json' \
    -d '{"loginMethod":"header"}' "$SMOKE_WEB_URL/account/login")" || { echo "login 失败：$r"; return 1; }
  tok="$(jq -r '.data.token // empty' <<<"$r")"
  [[ -n "$tok" ]] || { echo "login 没给 token：$r"; return 1; }
  v="$(web_get /account/validate -H "x-actual-token: $tok" -H 'Accept: application/json')" || { echo "validate 失败：$v"; return 1; }
  jq -e '.data.validated == true and (.data.permission | ascii_upcase) == "ADMIN" and (.data.userId | length) > 0' <<<"$v" >/dev/null ||
    { echo "validate 不是用户管理员：$v"; return 1; }
}

mcp_check() { # 有只读工具就真调一个，否则只断言 tools/list 有工具
  local n_mine tool out
  n_mine="$(jq --arg s "$SMOKE_SLUG" '[.[] | select(.name | startswith($s + "__"))] | length' "$SMOKE_TOOLS")"
  [[ "$n_mine" -ge 1 ]] || { echo "tools/list 没有 ${SMOKE_SLUG}__ 前缀工具"; return 1; }
  # 注意 select 里 and 的两侧上下文：管道后 . 是 name，注解要回到工具对象上取。
  tool="$(jq -r --arg s "$SMOKE_SLUG" '[.[] | select((.name | startswith($s + "__")) and .annotations.readOnlyHint == true)][0].name // ""' "$SMOKE_TOOLS")"
  if [[ -z "$tool" ]]; then
    SMOKE_NOTE="${SMOKE_NOTE}；工具没标 readOnlyHint，仅 tools/list，未调"
    return 0
  fi
  if out="$(mcp call "$tool" '{}' 2>&1)"; then
    return 0
  fi
  # 一次性实例是首装：零账本时工具报这句是设计行为（健康保持绿，见 README），有账本才可调。
  if grep -q 'No budgets found\. Please create a budget in Actual first\.' <<<"$out"; then
    SMOKE_NOTE="${SMOKE_NOTE}；一次性实例零账本，只读工具按设计报要先建账本（有账本才可调）"
    return 0
  fi
  echo "只读工具 $tool 调用失败：$(head -c 300 <<<"$out")"
  return 1
}

# 数据：账本（budget 文件）只存服务端数据目录，且只能由客户端经同步协议创建（服务端没有创建接口，
# 官方文档：服务端不做账本分析修改）。冒烟没有浏览器：data_write 在插件的 MCP 容器里用官方客户端库
# @actual-app/api 建一本带随机标记的账本（create-budget 不带 avoidUpload 就会同步上传远端，和网页
# 是同一条通道），再经服务端 /sync/list-user-files 核实；data_check 在升级、重装后用同一条接口找回。
_ac_container() { printf 'wonton-%s--%s--mcp' "${SMOKE_INSTANCE:-}" "${SMOKE_SLUG:-}"; }

_ac_marker_file() { # 标记文件：SMOKE_STATE 在 dev.sh probes 里是目录，目录里放标记文件
  if [[ -d "${SMOKE_STATE:-}" ]]; then printf '%s/data-marker' "$SMOKE_STATE"; else printf '%s' "${SMOKE_STATE:-}"; fi
}

_ac_api_entry() { # 在 MCP 容器里定位 @actual-app/api 的入口（镜像 cwd 是 /app）
  docker exec "$(_ac_container)" node -e 'console.log(require.resolve("@actual-app/api"))' 2>/dev/null
}

_ac_create_budget() { # <名字>：官方客户端库建账本并上传远端；失败原因打到标准错误
  local entry script
  entry="$(_ac_api_entry)" || { echo "MCP 容器里找不到 @actual-app/api" >&2; return 1; }
  script='const api = require(process.argv[1]);
(async () => {
  const lib = await api.init({ data: "/tmp/wonton-smoke-budget", serverURL: process.env.ACTUAL_SERVER_URL, password: process.env.ACTUAL_PASSWORD });
  await lib.send("create-budget", { budgetName: process.argv[2] });
  await api.shutdown();
})().catch(e => { console.error((e && e.message) || e); process.exit(1); });'
  docker exec "$(_ac_container)" node -e "$script" "$entry" "$1"
}

_ac_login_token() { # 经网关会话登录（网关代填密码），输出 x-actual-token；失败原因打到标准错误
  local r
  r="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H 'Content-Type: application/json' \
    -d '{"loginMethod":"header"}' "$SMOKE_WEB_URL/account/login")" || { echo "login 请求失败" >&2; return 1; }
  jq -r '.data.token // empty' <<<"$r"
}

_ac_find_budget() { # <名字> <token>：list-user-files 里找没删的账本；找到返回 0
  local files
  files="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "x-actual-token: $2" \
    "$SMOKE_WEB_URL/sync/list-user-files")" || { echo "list-user-files 失败" >&2; return 2; }
  jq -e --arg n "$1" 'any(.data[]; .name == $n and (.deleted | not))' <<<"$files" >/dev/null
}

data_write() {
  local marker tok
  marker="wonton-smoke-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  dweb --fresh / -L >/dev/null || { echo "重建网关会话失败"; return 1; }
  _ac_create_budget "$marker" || { echo "建账本失败（原因见日志）"; return 1; }
  tok="$(_ac_login_token)" || { echo "登录拿不到 token（原因见日志）"; return 1; }
  if ! _ac_find_budget "$marker" "$tok"; then
    echo "建了但服务端没有账本 $marker（上传失败？）"; return 1
  fi
  printf '%s' "$marker" >"$(_ac_marker_file)" || { echo "写不进标记文件 $(_ac_marker_file)"; return 1; }
  echo "已建账本 $marker"
}

data_check() {
  local marker tok
  marker="$(cat "$(_ac_marker_file)" 2>/dev/null)" || true
  [[ -n "$marker" ]] || { echo "没有 data_write 留下的标记（SMOKE_STATE=${SMOKE_STATE:-未设置}）"; return 1; }
  dweb --fresh / -L >/dev/null || { echo "重建网关会话失败"; return 1; }
  tok="$(_ac_login_token)" || { echo "登录拿不到 token（原因见日志）"; return 1; }
  if ! _ac_find_budget "$marker" "$tok"; then
    echo "账本 $marker 不见了（升级/重装丢了？）"; return 1
  fi
  echo "账本 $marker 还在"
}

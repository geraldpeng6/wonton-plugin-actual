# shellcheck shell=bash
# Actual Budget：sso=proxy（网关代填 x-actual-password）；MCP 有工具，确认标记以运行期注解为准。
SMOKE_NOTE="单用户应用，用户表没有用户名，身份按 validate 的 ADMIN + userId 断言"

web_assert() { grep -qi 'actual'; }   # 标准输入：应用真实页面

# 应用是单用户的：用户表没有用户名（userName 为空），应用侧能断言的是“认出来的是管理员本人”。
identity_check() { # 应用自己的登录 + validate 接口：认出来的是用户管理员
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
# 按 <服务名> 找本实例里这个服务的容器：核心给插件容器打了 wonton.plugin / wonton.service / wonton.instance
# 标签，按标签找，不自己拼容器名。
_container() {
  local name
  name="$(docker ps --format '{{.Names}}' \
    --filter "label=wonton.plugin=$SMOKE_PLUGIN_ID" \
    --filter "label=wonton.service=$1" \
    --filter "label=wonton.instance=$SMOKE_INSTANCE" | head -1)"
  [[ -n "$name" ]] || { echo "找不到 $SMOKE_PLUGIN_ID 的 $1 服务容器（实例 $SMOKE_INSTANCE）" >&2; return 1; }
  printf '%s\n' "$name"
}

_ac_api_entry() { # 在 MCP 容器里定位 @actual-app/api 的入口（镜像 cwd 是 /app）
  local c
  c="$(_container mcp)" || return 1
  docker exec "$c" node -e 'console.log(require.resolve("@actual-app/api"))' 2>/dev/null
}

_ac_budget_script() { # <create|check> <名字>：建并上传账本 / 核对账本还在。建和查都走官方客户端库
  # 与服务端的同步接口（MCP 容器内直连应用，和网页同一条通道）；网关侧的 /sync 路径不在
  # webui 代理范围，核对不能经网关。失败原因打到标准错误。
  local mode="$1" name="$2" entry script c
  entry="$(_ac_api_entry)" || { echo "MCP 容器里找不到 @actual-app/api" >&2; return 1; }
  script='const api = require(process.argv[1]);
const remote = async () => {
  const login = await fetch(process.env.ACTUAL_SERVER_URL + "/account/login", {
    method: "POST", headers: { "content-type": "application/json", "x-actual-password": process.env.ACTUAL_PASSWORD }, body: "{}",
  });
  const token = (await login.json()).data?.token;
  if (!token) throw new Error("登录拿不到 token");
  const list = await fetch(process.env.ACTUAL_SERVER_URL + "/sync/list-user-files", { headers: { "x-actual-token": token } });
  const j = await list.json();
  if (j.status !== "ok" || !Array.isArray(j.data)) throw new Error("list-user-files: " + JSON.stringify(j));
  return j.data.filter(f => !f.deleted).map(f => f.name);
};
(async () => {
  const mode = process.argv[2], name = process.argv[3];
  if (mode === "create") {
    const lib = await api.init({ data: "/tmp/wonton-smoke-budget", serverURL: process.env.ACTUAL_SERVER_URL, password: process.env.ACTUAL_PASSWORD });
    await lib.send("create-budget", { budgetName: name });
    // create-budget 内部的上传失败会被吞掉（离线也能建账本是上游设计），显式再传一次并把错误抛出来。
    const up = await lib.send("upload-budget");
    if (up && up.error) throw new Error("upload-budget: " + JSON.stringify(up.error));
    await api.shutdown();
  }
  const names = await remote();
  if (!names.includes(name)) {
    throw new Error((mode === "create" ? "上传后服务端没有账本" : "远端没有账本") + "（远端有：" + JSON.stringify(names) + "）");
  }
})().catch(e => { console.error((e && e.message) || e); process.exit(1); });'
  c="$(_container mcp)" || { echo "找不到 MCP 容器" >&2; return 1; }
  docker exec -w /tmp "$c" node -e "$script" "$entry" "$mode" "$name"
}

data_write() {
  local marker
  marker="wonton-smoke-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  _ac_budget_script create "$marker" || { echo "建账本失败（原因见日志）"; return 1; }
  printf '%s' "$marker" >"$SMOKE_STATE" || { echo "写不进标记文件 $SMOKE_STATE"; return 1; }
  echo "已建账本 $marker"
}

data_check() {
  local marker
  marker="$(cat "$SMOKE_STATE" 2>/dev/null)" || true
  [[ -n "$marker" ]] || { echo "没有 data_write 留下的标记（SMOKE_STATE=$SMOKE_STATE）"; return 1; }
  _ac_budget_script check "$marker" || { echo "账本 $marker 读回失败（原因见日志）"; return 1; }
  echo "账本 $marker 还在"
}

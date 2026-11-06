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

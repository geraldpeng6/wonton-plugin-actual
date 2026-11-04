// actual-mcp v1.15.1：下载必须用同步 ID；暖连接的账本身份与同步错误不能被缓存掩盖。
// 固定镜像的源码必须逐项匹配，升级时不允许补丁静默失效。
const FIXES = [
  [
    "/build/integrations/actual/connection.js",
    "import * as api from '@actual-app/api';",
    "import * as api from '@actual-app/api';\nimport { selectedRemoteBudget, loadedBudgetPath } from '/app/remote-budget.mjs';",
  ],
  [
    "/build/integrations/actual/connection.js",
    `const budgets = await api.getBudgets();
            if (!budgets || budgets.length === 0) {
                throw new Error('No budgets found. Please create a budget in Actual first.');
            }
            const budgetId = process.env.ACTUAL_BUDGET_SYNC_ID || budgets[0].cloudFileId || budgets[0].id || '';`,
    `const budgetId = await selectedRemoteBudget();
            if (!budgetId) throw new Error('No budgets found. Please create a budget in Actual first.');
            this.budgetId = budgetId;`,
  ],
  [
    "/build/integrations/actual/connection.js",
    "this.lastSyncAt = Date.now();",
    "fs.writeFileSync(loadedBudgetPath, budgetId);",
  ],
  [
    "/build/integrations/actual/connection.js",
    "return this.syncIfStale();",
    "return this.syncCurrentBudget();",
  ],
  [
    "/build/integrations/actual/connection.js",
    "const DEFAULT_SYNC_TTL_MS = 60_000;",
    "",
  ],
  [
    "/build/integrations/actual/connection.js",
    "    lastSyncAt = 0;\n",
    "",
  ],
  [
    "/build/integrations/actual/connection.js",
    "            this.lastSyncAt = 0;\n",
    "",
  ],
  [
    "/build/integrations/actual/connection.js",
    "// Reason: seed lastSyncAt so the first call after init does not immediately sync.",
    "// The healthcheck must distinguish first install from a previously loaded budget disappearing.",
  ],
  [
    "/build/tools/index.js",
    "tools: allTools.map((tool) => tool.schema),",
    "tools: allTools.map((tool) => readTools.includes(tool) ? { ...tool.schema, annotations: { readOnlyHint: true } } : tool.schema),",
  ],
];

export async function load(url, context, nextLoad) {
  const result = await nextLoad(url, context);
  const fixes = FIXES.filter(([path]) => url.endsWith(path));
  if (fixes.length === 0) return result;
  let source = result.source.toString();
  if (url.endsWith('/build/integrations/actual/connection.js')) {
    const start = source.indexOf('    syncTtlMs() {');
    const end = source.indexOf('    /**\n     * Stop accepting new operations', start);
    if (start < 0 || end < 0) throw new Error('actual-mcp sync patch did not match');
    source = source.slice(0, start) + `    syncCurrentBudget() {
        if (this.inflightSync) return this.inflightSync;
        this.inflightSync = this.enqueue(async () => {
            const currentId = await selectedRemoteBudget();
            if (currentId !== this.budgetId) {
                throw new Error('Loaded budget is no longer selected on the server; restart MCP after choosing a budget');
            }
            await api.sync();
        }).finally(() => { this.inflightSync = null; });
        return this.inflightSync;
    }
` + source.slice(end);
  }
  for (const [, from, to] of fixes) {
    if (!source.includes(from)) throw new Error(`actual-mcp patch did not match ${from}`);
    source = source.replace(from, to);
  }
  return { ...result, source };
}

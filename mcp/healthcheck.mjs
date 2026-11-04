import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { existsSync, readFileSync } from 'node:fs';
import { selectedRemoteBudget, loadedBudgetPath } from './remote-budget.mjs';

const signal = AbortSignal.timeout(10000);
// Leave time for logout and MCP session cleanup before Docker's 15 s timeout.
const watchdog = setTimeout(() => {
  console.error('healthcheck exceeded 14 s');
  process.exit(1);
}, 14000);
watchdog.unref();
const client = new Client({ name: 'actual-healthcheck', version: '1.0.0' });
let transport;
let cleanupSignal;

async function check() {
  const budgetId = await selectedRemoteBudget();
  if (existsSync(loadedBudgetPath) && readFileSync(loadedBudgetPath, 'utf8') !== budgetId) {
    throw new Error('Loaded MCP budget no longer matches the remote selection');
  }

  transport = new StreamableHTTPClientTransport(new URL('http://127.0.0.1:3000/mcp'), {
    // The SDK overrides requestInit.signal; bound its actual fetches, including SSE.
    fetch: (url, init) => fetch(url, {
      ...init,
      signal: AbortSignal.any([init.signal, cleanupSignal ?? signal].filter(Boolean)),
    }),
  });
  await client.connect(transport, { signal, timeout: 10000 });
  await client.listTools({}, { signal, timeout: 10000 });
  // 空预算仅在从未成功加载过账本时健康；暖连接不能借首装条件掩盖删除。
  if (budgetId) {
    const accounts = await client.callTool(
      { name: 'get-accounts', arguments: {} },
      undefined,
      { signal, timeout: 10000 },
    );
    if (accounts.isError) throw new Error(JSON.stringify(accounts.content));
  }
}

try {
  await check();
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  cleanupSignal = AbortSignal.timeout(2000);
  try {
    await transport?.terminateSession();
  } catch (error) {
    console.error('cleanup: ' + error.message);
    process.exitCode = 1;
  } finally {
    await client.close();
  }
}

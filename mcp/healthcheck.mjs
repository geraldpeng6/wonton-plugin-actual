import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

// 只验证 mcp 自己的 MCP 服务可用（握手 + 工具列表），刻意不登录 Actual：Actual 的登录接口会限流
// （{"status":"error","reason":"too-many-requests"}），健康检查每分钟登录一次既触发限流，也挤占
// 真用户的登录。Actual 服务是否可达由 actual 自己的 /health（无需登录）检查，头认证能否登录由
// init 服务启动时验证；登录后才能查的深状态（预算被删、密钥失效）由 Bot 真正调工具时如实报错。
// Docker 的 healthcheck timeout 是 10 s；9 s 自杀，给会话清理留 1 s。
const signal = AbortSignal.timeout(9000);
const watchdog = setTimeout(() => {
  console.error('healthcheck exceeded 9 s');
  process.exit(1);
}, 9000);
watchdog.unref();
const client = new Client({ name: 'actual-healthcheck', version: '1.0.0' });
let transport;
let cleanupSignal;

async function check() {
  transport = new StreamableHTTPClientTransport(new URL('http://127.0.0.1:3000/mcp'), {
    // The SDK overrides requestInit.signal; bound its actual fetches, including SSE.
    fetch: (url, init) => fetch(url, {
      ...init,
      signal: AbortSignal.any([init.signal, cleanupSignal ?? signal].filter(Boolean)),
    }),
  });
  await client.connect(transport, { signal, timeout: 9000 });
  // 工具列表来自静态定义，不触 Actual；空列表说明打补丁后的服务没把工具装上。
  const tools = await client.listTools({}, { signal, timeout: 9000 });
  if (tools.tools.length === 0) throw new Error('MCP server exposes no tools');
}

try {
  await check();
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  cleanupSignal = AbortSignal.timeout(1000);
  try {
    await transport?.terminateSession();
  } catch (error) {
    console.error('cleanup: ' + error.message);
    process.exitCode = 1;
  } finally {
    await client.close();
  }
}

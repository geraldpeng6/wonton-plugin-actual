import path from 'node:path';

export const loadedBudgetPath = path.join(process.env.ACTUAL_DATA_DIR, '.loaded-budget');

// getBudgets() merges local cache with remote files; it cannot prove that a cached budget still exists.
export async function selectedRemoteBudget() {
  const base = process.env.ACTUAL_SERVER_URL;
  const signal = AbortSignal.timeout(10000);
  const headers = { 'content-type': 'application/json' };
  let token;
  try {
    const login = await fetch(base + '/account/login', {
      method: 'POST',
      headers: { ...headers, 'x-actual-password': process.env.ACTUAL_PASSWORD },
      body: '{}', signal,
    });
    const result = await login.json();
    token = result.data?.token;
    if (!login.ok || result.status !== 'ok') {
      throw new Error('header login: ' + JSON.stringify(result));
    }
    const response = await fetch(base + '/sync/list-user-files', {
      headers: { 'x-actual-token': token }, signal,
    });
    const files = await response.json();
    if (!response.ok || files.status !== 'ok' || !Array.isArray(files.data)) {
      throw new Error('list budgets: ' + JSON.stringify(files));
    }
    const budgets = files.data.filter(file => !file.deleted);
    const selectedId = process.env.ACTUAL_BUDGET_SYNC_ID;
    if (!selectedId && budgets.length > 1) {
      throw new Error('Multiple budgets found and ACTUAL_BUDGET_SYNC_ID is not set');
    }
    const budget = selectedId ? budgets.find(file => file.groupId === selectedId) : budgets[0];
    if (selectedId && !budget) throw new Error('Selected ACTUAL_BUDGET_SYNC_ID not found in remote budgets');
    if (!budget) return null;
    if (!budget.groupId) throw new Error('Budget sync state was reset; reopen the budget in Actual');
    if (budget.encryptKeyId && !process.env.ACTUAL_BUDGET_ENCRYPTION_PASSWORD) {
      throw new Error('Selected budget is encrypted but ACTUAL_BUDGET_ENCRYPTION_PASSWORD is not set');
    }
    return budget.groupId;
  } finally {
    if (token) {
      const response = await fetch(base + '/account/logout', {
        method: 'POST', headers, body: JSON.stringify({ token }),
        signal: AbortSignal.timeout(2000),
      });
      const result = await response.json();
      if (!response.ok || result.status !== 'ok') throw new Error('logout: ' + JSON.stringify(result));
    }
  }
}

export async function postSettings(path, body) {
  try {
    const response = await fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
      signal: AbortSignal.timeout(10000),
    });
    return response.ok && (await response.json()).status === true;
  } catch {
    return false;
  }
}

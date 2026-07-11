const CURATED_HEADERS = [
  'content-type',
  'authorization',
  'x-api-key',
  'anthropic-version',
  'anthropic-beta',
  'openai-organization',
  'openai-project',
];

export function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value == null || typeof value !== 'object') return value;
  return Object.fromEntries(
    Object.keys(value)
      .sort()
      .map(key => [key, canonicalize(value[key])]),
  );
}

function parseBody(rawBody) {
  if (rawBody === '') return null;
  try {
    return canonicalize(JSON.parse(rawBody));
  } catch {
    return rawBody;
  }
}

export function normalizeRequest(request, { retryOnly = false } = {}) {
  const common = {
    ordinal: request.ordinal,
    method: request.method.toUpperCase(),
    path: request.path,
  };
  if (retryOnly) return common;

  const source = Object.fromEntries(
    Object.entries(request.headers ?? {}).map(([name, value]) => [
      name.toLowerCase(),
      value,
    ]),
  );
  const headers = Object.fromEntries(
    CURATED_HEADERS.map(name => [name, source[name] ?? null]),
  );
  // Fidelity-ledger item 10 deliberately changes the runtime suffix.
  headers['user-agent'] = source['user-agent'] != null;

  return {
    ...common,
    headers,
    body: parseBody(request.raw_body ?? ''),
  };
}

export function normalizeRun(run, scenario) {
  const retryOnly =
    scenario.comparison?.requests === 'count-and-order';
  return canonicalize({
    requests: run.requests.map(request =>
      normalizeRequest(request, { retryOnly }),
    ),
    result: run.result,
  });
}

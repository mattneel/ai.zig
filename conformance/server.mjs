import http from 'node:http';

const immediate = () => new Promise(resolve => setImmediate(resolve));

export function formatSseEvent(event) {
  const value = typeof event === 'string' ? { data: event } : event;
  let output = '';
  if (value.event != null) output += `event: ${value.event}\n`;
  if (value.id != null) output += `id: ${value.id}\n`;
  if (value.retry != null) output += `retry: ${value.retry}\n`;
  for (const line of String(value.data ?? '').split(/\r\n|\r|\n/)) {
    output += `data: ${line}\n`;
  }
  return `${output}\n`;
}

async function sendResponse(response, res) {
  const status = response.status ?? 200;
  const headers = { ...(response.headers ?? {}) };

  if (response.sse != null) {
    if (!Object.keys(headers).some(name => name.toLowerCase() === 'content-type')) {
      headers['content-type'] = 'text/event-stream';
    }
    res.writeHead(status, headers);
    for (const event of response.sse) {
      res.write(formatSseEvent(event));
      // A separate turn makes each fixture event observable as an independent
      // write without introducing wall-clock sleeps into conformance runs.
      await immediate();
    }
    res.end();
    return;
  }

  const body =
    typeof response.body === 'string'
      ? response.body
      : JSON.stringify(response.body ?? null);
  if (
    typeof response.body !== 'string' &&
    !Object.keys(headers).some(name => name.toLowerCase() === 'content-type')
  ) {
    headers['content-type'] = 'application/json';
  }
  res.writeHead(status, headers);
  res.end(body);
}

function normalizedHeaders(headers) {
  return Object.fromEntries(
    Object.entries(headers).map(([name, value]) => [
      name.toLowerCase(),
      Array.isArray(value) ? value.join(', ') : (value ?? ''),
    ]),
  );
}

export async function startScenarioServer(responses, options = {}) {
  const host = options.host ?? '127.0.0.1';
  const queue = structuredClone(responses);
  const requests = [];
  let responseIndex = 0;

  const server = http.createServer(async (req, res) => {
    const chunks = [];
    try {
      for await (const chunk of req) chunks.push(Buffer.from(chunk));
      requests.push({
        ordinal: requests.length + 1,
        method: req.method ?? 'GET',
        path: req.url ?? '/',
        headers: normalizedHeaders(req.headers),
        raw_body: Buffer.concat(chunks).toString('utf8'),
      });

      const response = queue[responseIndex++];
      if (response == null) {
        res.writeHead(500, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'No canned response remains.' }));
        return;
      }
      await sendResponse(response, res);
    } catch (error) {
      if (!res.headersSent) {
        res.writeHead(500, { 'content-type': 'application/json' });
      }
      res.end(JSON.stringify({ error: String(error) }));
    }
  });

  server.on('clientError', (_error, socket) => {
    socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
  });

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, host, () => {
      server.off('error', reject);
      resolve();
    });
  });

  const address = server.address();
  if (address == null || typeof address === 'string') {
    throw new Error('Fake provider server did not bind a TCP port.');
  }

  let closed = false;
  return {
    baseURL: `http://${host}:${address.port}`,
    requests,
    get usedResponses() {
      return responseIndex;
    },
    get remainingResponses() {
      return Math.max(0, queue.length - responseIndex);
    },
    async close() {
      if (closed) return;
      closed = true;
      server.closeIdleConnections?.();
      await new Promise((resolve, reject) => {
        server.close(error => (error ? reject(error) : resolve()));
      });
    },
  };
}

export async function withScenarioServer(responses, callback) {
  const server = await startScenarioServer(responses);
  try {
    return await callback(server);
  } finally {
    await server.close();
  }
}

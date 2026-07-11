import assert from 'node:assert/strict';
import test from 'node:test';

import { formatSseEvent, startScenarioServer } from '../server.mjs';

test('server serves responses in order and records exact requests', async () => {
  const server = await startScenarioServer([
    {
      status: 201,
      headers: { 'content-type': 'application/json', 'x-fixture': 'one' },
      body: { ok: 1 },
    },
    {
      status: 200,
      headers: { 'content-type': 'text/event-stream' },
      sse: [{ event: 'message', id: '7', data: 'first\nsecond' }, '[DONE]'],
    },
  ]);
  try {
    const first = await fetch(`${server.baseURL}/v1/messages`, {
      method: 'POST',
      headers: { authorization: 'Bearer test-key', 'content-type': 'application/json' },
      body: '{"hello":"world"}',
    });
    assert.equal(first.status, 201);
    assert.deepEqual(await first.json(), { ok: 1 });

    const second = await fetch(`${server.baseURL}/v1/stream`, { method: 'POST' });
    assert.equal(
      await second.text(),
      'event: message\nid: 7\ndata: first\ndata: second\n\ndata: [DONE]\n\n',
    );

    assert.equal(server.remainingResponses, 0);
    assert.deepEqual(
      server.requests.map(({ ordinal, method, path, raw_body }) => ({
        ordinal,
        method,
        path,
        raw_body,
      })),
      [
        {
          ordinal: 1,
          method: 'POST',
          path: '/v1/messages',
          raw_body: '{"hello":"world"}',
        },
        { ordinal: 2, method: 'POST', path: '/v1/stream', raw_body: '' },
      ],
    );
    assert.equal(server.requests[0].headers.authorization, 'Bearer test-key');
  } finally {
    await server.close();
  }
});

test('server reports an exhausted response queue instead of reusing a fixture', async () => {
  const server = await startScenarioServer([{ body: { ok: true } }]);
  try {
    assert.equal((await fetch(server.baseURL)).status, 200);
    const exhausted = await fetch(server.baseURL);
    assert.equal(exhausted.status, 500);
    assert.match(await exhausted.text(), /No canned response remains/);
    assert.equal(server.requests.length, 2);
  } finally {
    await server.close();
  }
});

test('formatSseEvent emits every data line and optional fields', () => {
  assert.equal(
    formatSseEvent({ event: 'delta', id: 'abc', retry: 10, data: 'a\r\nb' }),
    'event: delta\nid: abc\nretry: 10\ndata: a\ndata: b\n\n',
  );
});

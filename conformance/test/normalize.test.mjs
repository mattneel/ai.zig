import assert from 'node:assert/strict';
import test from 'node:test';

import { canonicalize, normalizeRun } from '../normalize.mjs';

test('canonicalize sorts object keys recursively without reordering arrays', () => {
  assert.deepEqual(canonicalize({ z: 1, a: { d: 2, b: 1 }, x: [{ q: 2, a: 1 }] }), {
    a: { b: 1, d: 2 },
    x: [{ a: 1, q: 2 }],
    z: 1,
  });
});

test('normalization ignores JSON key order, transport headers, and user-agent value', () => {
  const scenario = { comparison: {} };
  const upstream = normalizeRun(
    {
      requests: [
        {
          ordinal: 1,
          method: 'post',
          path: '/v1/chat/completions',
          headers: {
            host: '127.0.0.1:1',
            connection: 'keep-alive',
            'content-length': '13',
            'content-type': 'application/json',
            authorization: 'Bearer test-key',
            'user-agent': 'ai-sdk/openai/node',
          },
          raw_body: '{"b":2,"a":1}',
        },
      ],
      result: { ok: true },
    },
    scenario,
  );
  const zig = normalizeRun(
    {
      requests: [
        {
          ordinal: 1,
          method: 'POST',
          path: '/v1/chat/completions',
          headers: {
            'accept-encoding': 'gzip',
            'content-type': 'application/json',
            authorization: 'Bearer test-key',
            'user-agent': 'zig/0.16 ai-sdk-zig/openai',
          },
          raw_body: '{"a":1,"b":2}',
        },
      ],
      result: { ok: true },
    },
    scenario,
  );
  assert.deepEqual(upstream, zig);
  assert.equal(upstream.requests[0].headers['user-agent'], true);
  assert.equal('host' in upstream.requests[0].headers, false);
});

test('retry request normalization compares count and order only', () => {
  const scenario = { comparison: { requests: 'count-and-order' } };
  const makeRun = rawBodies => ({
    requests: rawBodies.map((raw_body, index) => ({
      ordinal: index + 1,
      method: 'POST',
      path: '/v1/chat/completions',
      headers: { authorization: `different-${index}` },
      raw_body,
    })),
    result: { text: 'ok' },
  });
  assert.deepEqual(
    normalizeRun(makeRun(['{"a":1}', '{"a":1}']), scenario),
    normalizeRun(makeRun(['not compared', 'still not compared']), scenario),
  );
});

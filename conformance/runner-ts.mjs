import { APICallError } from '@ai-sdk/provider';
import { createAnthropic } from '@ai-sdk/anthropic';
import { createOpenAI } from '@ai-sdk/openai';
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';
import {
  embed,
  embedMany,
  generateObject,
  generateText,
  isLoopFinished,
  jsonSchema,
  streamObject,
  streamText,
  tool,
} from 'ai';

function nullUsage() {
  return {
    input_tokens: null,
    input_token_details: {
      no_cache_tokens: null,
      cache_read_tokens: null,
      cache_write_tokens: null,
    },
    output_tokens: null,
    output_token_details: {
      text_tokens: null,
      reasoning_tokens: null,
    },
    total_tokens: null,
    tokens: null,
  };
}

function languageUsage(usage) {
  if (usage == null) return null;
  return {
    input_tokens: usage.inputTokens ?? null,
    input_token_details: {
      no_cache_tokens: usage.inputTokenDetails?.noCacheTokens ?? null,
      cache_read_tokens: usage.inputTokenDetails?.cacheReadTokens ?? null,
      cache_write_tokens: usage.inputTokenDetails?.cacheWriteTokens ?? null,
    },
    output_tokens: usage.outputTokens ?? null,
    output_token_details: {
      text_tokens: usage.outputTokenDetails?.textTokens ?? null,
      reasoning_tokens: usage.outputTokenDetails?.reasoningTokens ?? null,
    },
    total_tokens: usage.totalTokens ?? null,
    tokens: null,
  };
}

function embeddingUsage(usage) {
  const result = nullUsage();
  result.tokens = usage?.tokens ?? null;
  return result;
}

function emptyPart(type) {
  return {
    type,
    id: null,
    text: null,
    tool_name: null,
    tool_call_id: null,
    input: null,
    output: null,
    object: null,
    finish_reason: null,
    usage: null,
    error: null,
  };
}

function mapToolCall(call) {
  return {
    tool_call_id: call.toolCallId,
    tool_name: call.toolName,
    input: call.input,
  };
}

function mapToolResult(result) {
  return {
    tool_call_id: result.toolCallId,
    tool_name: result.toolName,
    input: result.input ?? null,
    output: result.output,
  };
}

function mapStep(step) {
  return {
    text: step.text,
    finish_reason: step.finishReason,
    usage: languageUsage(step.usage),
    tool_calls: step.toolCalls.map(mapToolCall),
    tool_results: step.toolResults.map(mapToolResult),
  };
}

function mapTextPart(part) {
  const mapped = emptyPart(part.type);
  switch (part.type) {
    case 'text-start':
    case 'text-end':
    case 'reasoning-start':
    case 'reasoning-end':
      mapped.id = part.id;
      break;
    case 'text-delta':
    case 'reasoning-delta':
      mapped.id = part.id;
      mapped.text = part.text;
      break;
    case 'tool-input-start':
      mapped.id = part.id;
      mapped.tool_name = part.toolName;
      break;
    case 'tool-input-delta':
      mapped.id = part.id;
      mapped.text = part.delta;
      break;
    case 'tool-input-end':
      mapped.id = part.id;
      break;
    case 'tool-call':
      mapped.tool_call_id = part.toolCallId;
      mapped.tool_name = part.toolName;
      mapped.input = part.input;
      break;
    case 'tool-result':
      mapped.tool_call_id = part.toolCallId;
      mapped.tool_name = part.toolName;
      mapped.input = part.input ?? null;
      mapped.output = part.output;
      break;
    case 'finish-step':
      mapped.finish_reason = part.finishReason;
      mapped.usage = languageUsage(part.usage);
      break;
    case 'finish':
      mapped.finish_reason = part.finishReason;
      mapped.usage = languageUsage(part.totalUsage);
      break;
    case 'error':
      mapped.error = { category: 'stream_error' };
      break;
  }
  return mapped;
}

function mapObjectPart(part) {
  const mapped = emptyPart(part.type);
  switch (part.type) {
    case 'object':
      mapped.object = part.object;
      break;
    case 'text-delta':
      mapped.text = part.textDelta;
      break;
    case 'finish':
      mapped.finish_reason = part.finishReason;
      mapped.usage = languageUsage(part.usage);
      break;
    case 'error':
      mapped.error = { category: 'stream_error' };
      break;
  }
  return mapped;
}

function emptyEnvelope(surface) {
  return {
    surface,
    result: {
      text: null,
      object: null,
      embedding: null,
      embeddings: null,
      value: null,
      values: null,
    },
    stream_parts: [],
    usage: null,
    finish_reason: null,
    steps: [],
    messages: [],
    error: null,
  };
}

function jsonClone(value) {
  return normalizeMessageDefaults(JSON.parse(JSON.stringify(value)));
}

function normalizeMessageDefaults(value) {
  if (Array.isArray(value)) {
    for (const item of value) normalizeMessageDefaults(item);
    return value;
  }
  if (value == null || typeof value !== 'object') return value;
  if (value.providerExecuted === false) delete value.providerExecuted;
  for (const item of Object.values(value)) normalizeMessageDefaults(item);
  return value;
}

function languageModel(scenario, baseURL) {
  const providerBaseURL = `${baseURL}/v1`;
  switch (scenario.provider) {
    case 'openai':
      return createOpenAI({
        baseURL: providerBaseURL,
        apiKey: 'test-key',
      }).chat(scenario.model);
    case 'anthropic':
      return createAnthropic({
        baseURL: providerBaseURL,
        apiKey: 'test-key',
      }).messages(scenario.model);
    case 'openai-compatible':
      return createOpenAICompatible({
        name: 'conformance',
        baseURL: providerBaseURL,
        apiKey: 'test-key',
        includeUsage: true,
        supportsStructuredOutputs: true,
      }).chatModel(scenario.model);
    default:
      throw new Error(`Unsupported provider: ${scenario.provider}`);
  }
}

function embeddingModel(scenario, baseURL) {
  if (scenario.provider !== 'openai') {
    throw new Error(`Unsupported embedding provider: ${scenario.provider}`);
  }
  return createOpenAI({
    baseURL: `${baseURL}/v1`,
    apiKey: 'test-key',
  }).embedding(scenario.model);
}

function toolsFor(input) {
  if (input.tools == null) return undefined;
  return Object.fromEntries(
    input.tools.map(definition => [
      definition.name,
      tool({
        description: definition.description,
        inputSchema: jsonSchema(definition.input_schema),
        execute: async () => structuredClone(definition.output),
      }),
    ]),
  );
}

function callOptions(scenario, baseURL) {
  const tools = toolsFor(scenario.input);
  return {
    model: languageModel(scenario, baseURL),
    messages: scenario.input.messages,
    maxRetries: scenario.input.settings?.maxRetries ?? 0,
    ...(tools == null ? {} : { tools, stopWhen: isLoopFinished() }),
  };
}

async function runGenerateText(scenario, baseURL) {
  const native = await generateText(callOptions(scenario, baseURL));
  const result = emptyEnvelope(scenario.surface);
  result.result.text = native.text;
  result.usage = languageUsage(native.usage);
  result.finish_reason = native.finishReason;
  result.steps = native.steps.map(mapStep);
  result.messages = jsonClone(native.responseMessages);
  return result;
}

async function runStreamText(scenario, baseURL) {
  const native = streamText(callOptions(scenario, baseURL));
  const result = emptyEnvelope(scenario.surface);
  for await (const part of native.fullStream) {
    result.stream_parts.push(mapTextPart(part));
  }
  result.result.text = await native.text;
  result.usage = languageUsage(await native.totalUsage);
  result.finish_reason = await native.finishReason;
  result.steps = (await native.steps).map(mapStep);
  result.messages = jsonClone(await native.responseMessages);
  return result;
}

function objectOptions(scenario, baseURL) {
  return {
    model: languageModel(scenario, baseURL),
    messages: scenario.input.messages,
    maxRetries: scenario.input.settings?.maxRetries ?? 0,
    schema: jsonSchema(scenario.input.schema),
    schemaName: scenario.input.schema_name,
    schemaDescription: scenario.input.schema_description,
  };
}

async function runGenerateObject(scenario, baseURL) {
  const native = await generateObject(objectOptions(scenario, baseURL));
  const result = emptyEnvelope(scenario.surface);
  result.result.object = native.object;
  result.usage = languageUsage(native.usage);
  result.finish_reason = native.finishReason;
  return result;
}

async function runStreamObject(scenario, baseURL) {
  const native = streamObject(objectOptions(scenario, baseURL));
  const result = emptyEnvelope(scenario.surface);
  for await (const part of native.fullStream) {
    result.stream_parts.push(mapObjectPart(part));
  }
  result.result.object = await native.object;
  result.usage = languageUsage(await native.usage);
  result.finish_reason = await native.finishReason;
  return result;
}

async function runEmbeddings(scenario, baseURL) {
  const model = embeddingModel(scenario, baseURL);
  const single = await embed({
    model,
    value: scenario.input.value,
    maxRetries: scenario.input.settings?.maxRetries ?? 0,
  });
  const many = await embedMany({
    model,
    values: scenario.input.values,
    maxRetries: scenario.input.settings?.maxRetries ?? 0,
  });
  const result = emptyEnvelope(scenario.surface);
  result.result.embedding = single.embedding;
  result.result.embeddings = many.embeddings;
  result.result.value = single.value;
  result.result.values = many.values;
  result.usage = embeddingUsage({
    tokens: (single.usage?.tokens ?? 0) + (many.usage?.tokens ?? 0),
  });
  return result;
}

function classifyError(error) {
  if (APICallError.isInstance(error)) return 'api_call_error';
  const name = String(error?.name ?? 'unknown_error');
  return name
    .replace(/^AI_/, '')
    .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
    .toLowerCase();
}

export async function runTsScenario(scenario, baseURL) {
  try {
    switch (scenario.surface) {
      case 'generateText':
        return await runGenerateText(scenario, baseURL);
      case 'streamText':
        return await runStreamText(scenario, baseURL);
      case 'generateObject':
        return await runGenerateObject(scenario, baseURL);
      case 'streamObject':
        return await runStreamObject(scenario, baseURL);
      case 'embed+embedMany':
        return await runEmbeddings(scenario, baseURL);
      default:
        throw new Error(`Unsupported surface: ${scenario.surface}`);
    }
  } catch (error) {
    const result = emptyEnvelope(scenario.surface);
    result.error = { category: classifyError(error) };
    return result;
  }
}

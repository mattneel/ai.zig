const std = @import("std");
const ai = @import("ai");
const provider = @import("provider");
const client_api = @import("client.zig");

const FakeLanguageModel = struct {
    actions: []const Action,
    call_count: usize = 0,
    prompts: [4]?provider.Prompt = .{null} ** 4,

    const Action = provider.GenerateResult;

    fn languageModel(self: *FakeLanguageModel) provider.LanguageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn providerName(_: *anyopaque) []const u8 {
        return "mcp-bridge-fake";
    }

    fn modelId(_: *anyopaque) []const u8 {
        return "scripted";
    }

    fn urlSupported(_: *anyopaque, _: []const u8, _: []const u8) bool {
        return true;
    }

    fn doGenerate(
        raw: *anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
        options: *const provider.CallOptions,
        _: ?*provider.Diagnostics,
    ) provider.CallError!provider.GenerateResult {
        const self: *FakeLanguageModel = @ptrCast(@alignCast(raw));
        const index = self.call_count;
        self.call_count += 1;
        self.prompts[index] = options.prompt;
        return self.actions[index];
    }

    fn doStream(
        _: *anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
        _: *const provider.CallOptions,
        _: ?*provider.Diagnostics,
    ) provider.CallError!provider.StreamResult {
        return error.UnsupportedFunctionalityError;
    }

    const vtable: provider.LanguageModel.VTable = .{
        .provider = providerName,
        .modelId = modelId,
        .urlIsSupported = urlSupported,
        .doGenerate = doGenerate,
        .doStream = doStream,
    };
};

fn generated(content: []const provider.Content, finish: provider.FinishReasonUnified) provider.GenerateResult {
    return .{
        .content = content,
        .finish_reason = .{ .unified = finish, .raw = @tagName(finish) },
        .usage = .{ .input_tokens = .{ .total = 1 }, .output_tokens = .{ .total = 1 } },
        .warnings = &.{},
    };
}

test "generateText executes an MCP-derived tool and feeds its result into the next model step" {
    const test_options = @import("mcp_test_options");
    const io = std.testing.io;
    const client = try client_api.createMcpClient(std.testing.allocator, io, .{
        .transport = .{ .stdio = .{ .command = test_options.test_server_path } },
        .client_name = "money-shot-client",
    });
    defer client.deinit(io);

    var tools_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tools_arena_state.deinit();
    const mcp_tools = try client.tools(io, tools_arena_state.allocator(), .{});
    try std.testing.expectEqual(1, mcp_tools.len);
    try std.testing.expectEqualStrings("money-shot-client", mcp_tools[0].tool.metadata.?.object.get("clientName").?.string);

    const first_content = [_]provider.Content{.{ .tool_call = .{
        .tool_call_id = "mcp-call-1",
        .tool_name = "echo",
        .input = "{\"value\":\"from-mcp\"}",
    } }};
    const second_content = [_]provider.Content{.{ .text = .{ .text = "MCP echo completed." } }};
    const actions = [_]FakeLanguageModel.Action{
        generated(&first_content, .tool_calls),
        generated(&second_content, .stop),
    };
    var fake: FakeLanguageModel = .{ .actions = &actions };
    var result = try ai.generateText(io, std.testing.allocator, .{
        .model = .{ .model = fake.languageModel() },
        .prompt = .{ .text = "Use the echo tool" },
        .tools = mcp_tools,
        .stop_when = &.{ai.loopFinished()},
    });
    defer result.deinit();

    try std.testing.expectEqual(2, fake.call_count);
    try std.testing.expectEqualStrings("MCP echo completed.", result.text());
    try std.testing.expectEqual(1, result.toolResults().len);
    const second_prompt = fake.prompts[1].?;
    try std.testing.expectEqual(3, second_prompt.len);
    const output = second_prompt[2].tool.content[0].tool_result.output;
    try std.testing.expect(output == .content);
    try std.testing.expectEqualStrings("{\"value\":\"from-mcp\"}", output.content.value[0].text.text);
}

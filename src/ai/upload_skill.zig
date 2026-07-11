//! Skill-upload orchestration over Skills V4.

const std = @import("std");
const provider = @import("provider");
const provider_utils = @import("provider_utils");
const media_data = @import("media_data.zig");
const upload_file = @import("upload_file.zig");

const Allocator = std.mem.Allocator;

pub const SkillsApi = union(enum) {
    skills: provider.Skills,
    provider: provider.Provider,
};

pub const SkillFile = struct {
    path: []const u8,
    data: upload_file.UploadData,
};

pub const UploadSkillOptions = struct {
    api: SkillsApi,
    files: []const SkillFile,
    display_title: ?[]const u8 = null,
    provider_options: ?provider.ProviderOptions = null,
    diag: ?*provider.Diagnostics = null,
};

pub const UploadSkillResult = struct {
    arena_state: std.heap.ArenaAllocator,
    provider_reference: provider.ProviderReference,
    display_title: ?[]const u8,
    name: ?[]const u8,
    description: ?[]const u8,
    latest_version: ?[]const u8,
    provider_metadata: ?provider.ProviderMetadata,
    warnings: []const provider.Warning,

    pub fn deinit(self: *UploadSkillResult) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

pub fn uploadSkill(
    io: std.Io,
    gpa: Allocator,
    options: UploadSkillOptions,
) anyerror!UploadSkillResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    const skills_api = switch (options.api) {
        .skills => |skills| skills,
        .provider => |selected| try selected.skills(options.diag),
    };
    const files = try arena.alloc(provider.SkillFile, options.files.len);
    for (options.files, files) |file, *destination| destination.* = .{
        .path = try arena.dupe(u8, file.path),
        .data = switch (file.data) {
            .bytes => |bytes| .{ .data = .{ .data = .{ .bytes = try arena.dupe(u8, bytes) } } },
            .base64 => |encoded| .{ .data = .{ .data = .{ .base64 = try arena.dupe(u8, encoded) } } },
            .text => |text| .{ .text = .{ .text = try arena.dupe(u8, text) } },
            .tagged => |tagged| try cloneUploadData(arena, tagged),
        },
    };
    const model_result = try skills_api.uploadSkill(io, arena, &.{
        .files = files,
        .display_title = options.display_title,
        .provider_options = options.provider_options,
    }, options.diag);
    const warnings = try arena.alloc(provider.Warning, model_result.warnings.len);
    for (model_result.warnings, warnings) |warning, *destination| {
        destination.* = try media_data.cloneWarning(arena, warning);
    }
    return .{
        .arena_state = arena_state,
        .provider_reference = try provider_utils.cloneJsonValue(arena, model_result.provider_reference),
        .display_title = try cloneOptional(arena, model_result.display_title),
        .name = try cloneOptional(arena, model_result.name),
        .description = try cloneOptional(arena, model_result.description),
        .latest_version = try cloneOptional(arena, model_result.latest_version),
        .provider_metadata = if (model_result.provider_metadata) |metadata|
            try provider_utils.cloneJsonValue(arena, metadata)
        else
            null,
        .warnings = warnings,
    };
}

fn cloneUploadData(arena: Allocator, data: provider.UploadFileData) Allocator.Error!provider.UploadFileData {
    return switch (data) {
        .text => |text| .{ .text = .{ .text = try arena.dupe(u8, text.text) } },
        .data => |value| .{ .data = .{ .data = switch (value.data) {
            .bytes => |bytes| .{ .bytes = try arena.dupe(u8, bytes) },
            .base64 => |encoded| .{ .base64 = try arena.dupe(u8, encoded) },
        } } },
    };
}

fn cloneOptional(arena: Allocator, value: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (value) |text| try arena.dupe(u8, text) else null;
}

test "uploadSkill normalizes per-file shorthand" {
    const Mock = struct {
        saw_bytes: bool = false,
        saw_text: bool = false,

        fn providerName(_: *anyopaque) []const u8 {
            return "mock";
        }
        fn upload(
            raw: *anyopaque,
            _: std.Io,
            arena: Allocator,
            options: *const provider.UploadSkillCallOptions,
            _: ?*provider.Diagnostics,
        ) provider.skills_module.CallError!provider.UploadSkillResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.saw_bytes = options.files[0].data == .data;
            self.saw_text = options.files[1].data == .text;
            var reference: std.json.ObjectMap = .empty;
            try reference.put(arena, "mock", .{ .string = "skill-1" });
            return .{
                .provider_reference = .{ .object = reference },
                .warnings = &.{},
            };
        }
    };
    var mock: Mock = .{};
    const skills: provider.Skills = .{ .ctx = &mock, .vtable = &.{
        .provider = Mock.providerName,
        .uploadSkill = Mock.upload,
    } };
    var result = try uploadSkill(std.testing.io, std.testing.allocator, .{
        .api = .{ .skills = skills },
        .files = &.{
            .{ .path = "main.zig", .data = .{ .bytes = "code" } },
            .{ .path = "README.md", .data = .{ .text = "docs" } },
        },
    });
    defer result.deinit();
    try std.testing.expect(mock.saw_bytes);
    try std.testing.expect(mock.saw_text);
    try std.testing.expectEqualStrings("skill-1", result.provider_reference.object.get("mock").?.string);
}

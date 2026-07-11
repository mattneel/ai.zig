//! Provider V4 registry specification.

const errors = @import("errors.zig");
const language = @import("language_model.zig");
const embedding = @import("embedding_model.zig");
const image = @import("image_model.zig");
const transcription = @import("transcription_model.zig");
const speech = @import("speech_model.zig");
const reranking = @import("reranking_model.zig");
const files_module = @import("files.zig");
const skills_module = @import("skills.zig");
const std = @import("std");

/// Mirrors provider-v4.ts as a Zig fat-pointer registry. Upstream notably has
/// no `videoModel` lookup despite defining VideoModelV4; that quirk is kept.
pub const Provider = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Mirrors provider-v4.ts registry operations.
    pub const VTable = struct {
        languageModel: *const fn (
            ctx: *anyopaque,
            model_id: []const u8,
            diag: ?*errors.Diagnostics,
        ) errors.Error!language.LanguageModel,
        embeddingModel: *const fn (
            ctx: *anyopaque,
            model_id: []const u8,
            diag: ?*errors.Diagnostics,
        ) errors.Error!embedding.EmbeddingModel,
        imageModel: *const fn (
            ctx: *anyopaque,
            model_id: []const u8,
            diag: ?*errors.Diagnostics,
        ) errors.Error!image.ImageModel,
        transcriptionModel: ?*const fn (
            ctx: *anyopaque,
            model_id: []const u8,
            diag: ?*errors.Diagnostics,
        ) errors.Error!transcription.TranscriptionModel = null,
        speechModel: ?*const fn (
            ctx: *anyopaque,
            model_id: []const u8,
            diag: ?*errors.Diagnostics,
        ) errors.Error!speech.SpeechModel = null,
        rerankingModel: ?*const fn (
            ctx: *anyopaque,
            model_id: []const u8,
            diag: ?*errors.Diagnostics,
        ) errors.Error!reranking.RerankingModel = null,
        files: ?*const fn (
            ctx: *anyopaque,
            diag: ?*errors.Diagnostics,
        ) errors.Error!files_module.Files = null,
        skills: ?*const fn (
            ctx: *anyopaque,
            diag: ?*errors.Diagnostics,
        ) errors.Error!skills_module.Skills = null,
    };

    pub fn languageModel(
        self: Provider,
        model_id: []const u8,
        diag: ?*errors.Diagnostics,
    ) errors.Error!language.LanguageModel {
        return self.vtable.languageModel(self.ctx, model_id, diag);
    }

    pub fn embeddingModel(
        self: Provider,
        model_id: []const u8,
        diag: ?*errors.Diagnostics,
    ) errors.Error!embedding.EmbeddingModel {
        return self.vtable.embeddingModel(self.ctx, model_id, diag);
    }

    pub fn imageModel(
        self: Provider,
        model_id: []const u8,
        diag: ?*errors.Diagnostics,
    ) errors.Error!image.ImageModel {
        return self.vtable.imageModel(self.ctx, model_id, diag);
    }

    pub fn transcriptionModel(
        self: Provider,
        model_id: []const u8,
        diag: ?*errors.Diagnostics,
    ) errors.Error!transcription.TranscriptionModel {
        const function = self.vtable.transcriptionModel orelse
            return noSuchModel(diag, model_id, .transcription_model);
        return function(self.ctx, model_id, diag);
    }

    pub fn speechModel(
        self: Provider,
        model_id: []const u8,
        diag: ?*errors.Diagnostics,
    ) errors.Error!speech.SpeechModel {
        const function = self.vtable.speechModel orelse
            return noSuchModel(diag, model_id, .speech_model);
        return function(self.ctx, model_id, diag);
    }

    pub fn rerankingModel(
        self: Provider,
        model_id: []const u8,
        diag: ?*errors.Diagnostics,
    ) errors.Error!reranking.RerankingModel {
        const function = self.vtable.rerankingModel orelse
            return noSuchModel(diag, model_id, .reranking_model);
        return function(self.ctx, model_id, diag);
    }

    pub fn files(self: Provider, diag: ?*errors.Diagnostics) errors.Error!files_module.Files {
        const function = self.vtable.files orelse return unsupported(diag, "files");
        return function(self.ctx, diag);
    }

    pub fn skills(self: Provider, diag: ?*errors.Diagnostics) errors.Error!skills_module.Skills {
        const function = self.vtable.skills orelse return unsupported(diag, "skills");
        return function(self.ctx, diag);
    }
};

fn noSuchModel(
    diag: ?*errors.Diagnostics,
    model_id: []const u8,
    model_type: errors.ModelType,
) errors.Error {
    const allocator = if (diag) |value| value.allocator else return error.NoSuchModelError;
    errors.Diagnostics.set(diag, allocator, .{ .no_such_model = .{
        .message = "provider does not expose this model type",
        .model_id = model_id,
        .model_type = model_type,
    } });
    return error.NoSuchModelError;
}

fn unsupported(diag: ?*errors.Diagnostics, functionality: []const u8) errors.Error {
    const allocator = if (diag) |value| value.allocator else return error.UnsupportedFunctionalityError;
    errors.Diagnostics.set(diag, allocator, .{ .unsupported_functionality = .{
        .message = "provider does not expose this capability",
        .functionality = functionality,
    } });
    return error.UnsupportedFunctionalityError;
}

test "Provider optional model lookups fill NoSuchModel diagnostics" {
    const Mock = struct {
        fn languageModel(
            _: *anyopaque,
            _: []const u8,
            _: ?*errors.Diagnostics,
        ) errors.Error!language.LanguageModel {
            return error.NoSuchModelError;
        }

        fn embeddingModel(
            _: *anyopaque,
            _: []const u8,
            _: ?*errors.Diagnostics,
        ) errors.Error!embedding.EmbeddingModel {
            return error.NoSuchModelError;
        }

        fn imageModel(
            _: *anyopaque,
            _: []const u8,
            _: ?*errors.Diagnostics,
        ) errors.Error!image.ImageModel {
            return error.NoSuchModelError;
        }
    };

    var marker: u8 = 0;
    const value: Provider = .{
        .ctx = &marker,
        .vtable = &.{
            .languageModel = Mock.languageModel,
            .embeddingModel = Mock.embeddingModel,
            .imageModel = Mock.imageModel,
        },
    };
    var diagnostics = errors.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();

    try std.testing.expectError(
        error.NoSuchModelError,
        value.transcriptionModel("missing", &diagnostics),
    );
    try std.testing.expect(diagnostics.available);
    try std.testing.expectEqualStrings("missing", diagnostics.payload.no_such_model.model_id);
    try std.testing.expectEqual(errors.ModelType.transcription_model, diagnostics.payload.no_such_model.model_type);
}

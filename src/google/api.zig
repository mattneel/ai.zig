const provider_utils = @import("provider_utils");

const ErrorShape = struct {
    @"error": struct {
        code: ?i64 = null,
        message: []const u8,
        status: ?[]const u8 = null,
    },
};

const Callbacks = struct {
    fn message(value: ErrorShape) []const u8 {
        return value.@"error".message;
    }
};

pub fn failedResponseHandler() provider_utils.ErrorResponseHandler {
    return provider_utils.jsonErrorResponseHandler(ErrorShape, Callbacks.message);
}

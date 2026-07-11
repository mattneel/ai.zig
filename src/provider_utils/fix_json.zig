const std = @import("std");

const Allocator = std.mem.Allocator;

const State = enum {
    root,
    finish,
    inside_string,
    inside_string_escape,
    inside_string_unicode_escape,
    inside_literal,
    inside_number,
    inside_object_start,
    inside_object_key,
    inside_object_after_key,
    inside_object_before_value,
    inside_object_after_value,
    inside_object_after_comma,
    inside_array_start,
    inside_array_after_value,
    inside_array_after_comma,
};

const Scanner = struct {
    allocator: Allocator,
    input: []const u8,
    stack: std.ArrayList(State) = .empty,
    last_valid_index: ?usize = null,
    literal_start: ?usize = null,
    unicode_escape_digits: u3 = 0,

    fn deinit(self: *Scanner) void {
        self.stack.deinit(self.allocator);
    }

    fn push(self: *Scanner, state: State) Allocator.Error!void {
        try self.stack.append(self.allocator, state);
    }

    fn pop(self: *Scanner) void {
        std.debug.assert(self.stack.items.len != 0);
        self.stack.items.len -= 1;
    }

    fn top(self: *const Scanner) State {
        return self.stack.items[self.stack.items.len - 1];
    }

    fn swapAndPush(self: *Scanner, swap_state: State, state: State) Allocator.Error!void {
        self.pop();
        try self.push(swap_state);
        try self.push(state);
    }

    fn processValueStart(self: *Scanner, char: u8, index: usize, swap_state: State) Allocator.Error!void {
        switch (char) {
            '"' => {
                self.last_valid_index = index;
                try self.swapAndPush(swap_state, .inside_string);
            },
            'f', 't', 'n' => {
                self.last_valid_index = index;
                self.literal_start = index;
                try self.swapAndPush(swap_state, .inside_literal);
            },
            '-' => try self.swapAndPush(swap_state, .inside_number),
            '0'...'9' => {
                self.last_valid_index = index;
                try self.swapAndPush(swap_state, .inside_number);
            },
            '{' => {
                self.last_valid_index = index;
                try self.swapAndPush(swap_state, .inside_object_start);
            },
            '[' => {
                self.last_valid_index = index;
                try self.swapAndPush(swap_state, .inside_array_start);
            },
            else => {},
        }
    }

    fn processAfterObjectValue(self: *Scanner, char: u8, index: usize) Allocator.Error!void {
        switch (char) {
            ',' => {
                self.pop();
                try self.push(.inside_object_after_comma);
            },
            '}' => {
                self.last_valid_index = index;
                self.pop();
            },
            else => {},
        }
    }

    fn processAfterArrayValue(self: *Scanner, char: u8, index: usize) Allocator.Error!void {
        switch (char) {
            ',' => {
                self.pop();
                try self.push(.inside_array_after_comma);
            },
            ']' => {
                self.last_valid_index = index;
                self.pop();
            },
            else => {},
        }
    }

    fn scan(self: *Scanner) Allocator.Error!void {
        try self.push(.root);

        for (self.input, 0..) |char, index| {
            switch (self.top()) {
                .root => try self.processValueStart(char, index, .finish),
                .inside_object_start => switch (char) {
                    '"' => {
                        self.pop();
                        try self.push(.inside_object_key);
                    },
                    '}' => {
                        self.last_valid_index = index;
                        self.pop();
                    },
                    else => {},
                },
                .inside_object_after_comma => if (char == '"') {
                    self.pop();
                    try self.push(.inside_object_key);
                },
                .inside_object_key => if (char == '"') {
                    self.pop();
                    try self.push(.inside_object_after_key);
                },
                .inside_object_after_key => if (char == ':') {
                    self.pop();
                    try self.push(.inside_object_before_value);
                },
                .inside_object_before_value => try self.processValueStart(
                    char,
                    index,
                    .inside_object_after_value,
                ),
                .inside_object_after_value => try self.processAfterObjectValue(char, index),
                .inside_string => switch (char) {
                    '"' => {
                        self.pop();
                        self.last_valid_index = index;
                    },
                    '\\' => try self.push(.inside_string_escape),
                    else => self.last_valid_index = index,
                },
                .inside_array_start => switch (char) {
                    ']' => {
                        self.last_valid_index = index;
                        self.pop();
                    },
                    else => {
                        self.last_valid_index = index;
                        try self.processValueStart(char, index, .inside_array_after_value);
                    },
                },
                .inside_array_after_value => switch (char) {
                    ',' => {
                        self.pop();
                        try self.push(.inside_array_after_comma);
                    },
                    ']' => {
                        self.last_valid_index = index;
                        self.pop();
                    },
                    else => self.last_valid_index = index,
                },
                .inside_array_after_comma => try self.processValueStart(
                    char,
                    index,
                    .inside_array_after_value,
                ),
                .inside_string_escape => {
                    self.pop();
                    if (char == 'u') {
                        self.unicode_escape_digits = 0;
                        try self.push(.inside_string_unicode_escape);
                    } else {
                        self.last_valid_index = index;
                    }
                },
                .inside_string_unicode_escape => if (std.ascii.isHex(char)) {
                    self.unicode_escape_digits += 1;
                    if (self.unicode_escape_digits == 4) {
                        self.pop();
                        self.last_valid_index = index;
                    }
                },
                .inside_number => switch (char) {
                    '0'...'9' => self.last_valid_index = index,
                    'e', 'E', '-', '.' => {},
                    ',' => {
                        self.pop();
                        if (self.top() == .inside_array_after_value) {
                            try self.processAfterArrayValue(char, index);
                        }
                        if (self.top() == .inside_object_after_value) {
                            try self.processAfterObjectValue(char, index);
                        }
                    },
                    '}' => {
                        self.pop();
                        if (self.top() == .inside_object_after_value) {
                            try self.processAfterObjectValue(char, index);
                        }
                    },
                    ']' => {
                        self.pop();
                        if (self.top() == .inside_array_after_value) {
                            try self.processAfterArrayValue(char, index);
                        }
                    },
                    else => self.pop(),
                },
                .inside_literal => {
                    const partial = self.input[self.literal_start.? .. index + 1];
                    if (!std.mem.startsWith(u8, "false", partial) and
                        !std.mem.startsWith(u8, "true", partial) and
                        !std.mem.startsWith(u8, "null", partial))
                    {
                        self.pop();
                        if (self.top() == .inside_object_after_value) {
                            try self.processAfterObjectValue(char, index);
                        } else if (self.top() == .inside_array_after_value) {
                            try self.processAfterArrayValue(char, index);
                        }
                    } else {
                        self.last_valid_index = index;
                    }
                },
                .finish => {},
            }
        }
    }

    fn finish(self: *Scanner) Allocator.Error![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        if (self.last_valid_index) |index| {
            output.writer.writeAll(self.input[0 .. index + 1]) catch return error.OutOfMemory;
        }

        var index = self.stack.items.len;
        while (index != 0) {
            index -= 1;
            switch (self.stack.items[index]) {
                .inside_string => output.writer.writeByte('"') catch return error.OutOfMemory,
                .inside_object_key,
                .inside_object_after_key,
                .inside_object_after_comma,
                .inside_object_start,
                .inside_object_before_value,
                .inside_object_after_value,
                => output.writer.writeByte('}') catch return error.OutOfMemory,
                .inside_array_start,
                .inside_array_after_comma,
                .inside_array_after_value,
                => output.writer.writeByte(']') catch return error.OutOfMemory,
                .inside_literal => {
                    const partial = self.input[self.literal_start.?..];
                    if (std.mem.startsWith(u8, "true", partial)) {
                        output.writer.writeAll("true"[partial.len..]) catch return error.OutOfMemory;
                    } else if (std.mem.startsWith(u8, "false", partial)) {
                        output.writer.writeAll("false"[partial.len..]) catch return error.OutOfMemory;
                    } else if (std.mem.startsWith(u8, "null", partial)) {
                        output.writer.writeAll("null"[partial.len..]) catch return error.OutOfMemory;
                    }
                },
                else => {},
            }
        }
        return output.toOwnedSlice();
    }
};

/// Repairs a prefix of valid JSON in one linear scan.
pub fn fixJson(allocator: Allocator, input: []const u8) Allocator.Error![]u8 {
    var scanner: Scanner = .{ .allocator = allocator, .input = input };
    defer scanner.deinit();
    try scanner.scan();
    return scanner.finish();
}

test "fixJson complete upstream corpus (60 cases)" {
    const complex_input = "{\n" ++
        "  \"a\": [\n" ++
        "    {\n" ++
        "      \"a1\": \"v1\",\n" ++
        "      \"a2\": \"v2\",\n" ++
        "      \"a3\": \"v3\"\n" ++
        "    }\n" ++
        "  ],\n" ++
        "  \"b\": [\n" ++
        "    {\n" ++
        "      \"b1\": \"n";
    const complex_expected = "{\n" ++
        "  \"a\": [\n" ++
        "    {\n" ++
        "      \"a1\": \"v1\",\n" ++
        "      \"a2\": \"v2\",\n" ++
        "      \"a3\": \"v3\"\n" ++
        "    }\n" ++
        "  ],\n" ++
        "  \"b\": [\n" ++
        "    {\n" ++
        "      \"b1\": \"n\"}]}";
    const incomplete_escape = "\"value with " ++ "\\";

    const Case = struct { input: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .input = "", .expected = "" },
        .{ .input = "nul", .expected = "null" },
        .{ .input = "t", .expected = "true" },
        .{ .input = "fals", .expected = "false" },
        .{ .input = "12.", .expected = "12" },
        .{ .input = "12.2", .expected = "12.2" },
        .{ .input = "-12", .expected = "-12" },
        .{ .input = "-", .expected = "" },
        .{ .input = "2.5e", .expected = "2.5" },
        .{ .input = "2.5e-", .expected = "2.5" },
        .{ .input = "2.5e3", .expected = "2.5e3" },
        .{ .input = "-2.5e3", .expected = "-2.5e3" },
        .{ .input = "2.5E", .expected = "2.5" },
        .{ .input = "2.5E-", .expected = "2.5" },
        .{ .input = "2.5E3", .expected = "2.5E3" },
        .{ .input = "-2.5E3", .expected = "-2.5E3" },
        .{ .input = "12.e", .expected = "12" },
        .{ .input = "12.34e", .expected = "12.34" },
        .{ .input = "5e", .expected = "5" },
        .{ .input = "\"abc", .expected = "\"abc\"" },
        .{ .input = "\"value with \\\"quoted\\\" text and \\\\ escape", .expected = "\"value with \\\"quoted\\\" text and \\\\ escape\"" },
        .{ .input = incomplete_escape, .expected = "\"value with \"" },
        .{ .input = "\"\\u", .expected = "\"\"" },
        .{ .input = "\"\\u12", .expected = "\"\"" },
        .{ .input = "\"text \\u00", .expected = "\"text \"" },
        .{ .input = "{\"a\":\"\\u12", .expected = "{\"a\":\"\"}" },
        .{ .input = "\"value with unicode <\"", .expected = "\"value with unicode <\"" },
        .{ .input = "[", .expected = "[]" },
        .{ .input = "[[1], [2", .expected = "[[1], [2]]" },
        .{ .input = "[[\"1\"], [\"2", .expected = "[[\"1\"], [\"2\"]]" },
        .{ .input = "[[false], [nu", .expected = "[[false], [null]]" },
        .{ .input = "[[[]], [[]", .expected = "[[[]], [[]]]" },
        .{ .input = "[[{}], [{", .expected = "[[{}], [{}]]" },
        .{ .input = "[1, ", .expected = "[1]" },
        .{ .input = "[[], 123", .expected = "[[], 123]" },
        .{ .input = "{\"key\":", .expected = "{}" },
        .{ .input = "{\"a\": {\"b\": 1}, \"c\": {\"d\": 2", .expected = "{\"a\": {\"b\": 1}, \"c\": {\"d\": 2}}" },
        .{ .input = "{\"a\": {\"b\": \"1\"}, \"c\": {\"d\": 2", .expected = "{\"a\": {\"b\": \"1\"}, \"c\": {\"d\": 2}}" },
        .{ .input = "{\"a\": {\"b\": false}, \"c\": {\"d\": 2", .expected = "{\"a\": {\"b\": false}, \"c\": {\"d\": 2}}" },
        .{ .input = "{\"a\": {\"b\": []}, \"c\": {\"d\": 2", .expected = "{\"a\": {\"b\": []}, \"c\": {\"d\": 2}}" },
        .{ .input = "{\"a\": {\"b\": {}}, \"c\": {\"d\": 2", .expected = "{\"a\": {\"b\": {}}, \"c\": {\"d\": 2}}" },
        .{ .input = "{\"ke", .expected = "{}" },
        .{ .input = "{\"k1\": 1, \"k2", .expected = "{\"k1\": 1}" },
        .{ .input = "{\"k1\": 1, \"k2\":", .expected = "{\"k1\": 1}" },
        .{ .input = "{\"key\": \"value\"  ", .expected = "{\"key\": \"value\"}" },
        .{ .input = "{\"a\": {\"b\": {}", .expected = "{\"a\": {\"b\": {}}}" },
        .{ .input = "[1, [2, 3, [", .expected = "[1, [2, 3, []]]" },
        .{ .input = "[false, [true, [", .expected = "[false, [true, []]]" },
        .{ .input = "{\"key\": {\"subKey\":", .expected = "{\"key\": {}}" },
        .{ .input = "{\"key\": 123, \"key2\": {\"subKey\":", .expected = "{\"key\": 123, \"key2\": {}}" },
        .{ .input = "{\"key\": null, \"key2\": {\"subKey\":", .expected = "{\"key\": null, \"key2\": {}}" },
        .{ .input = "{\"key\": [1, 2, {", .expected = "{\"key\": [1, 2, {}]}" },
        .{ .input = "[1, 2, {\"key\": \"value\",", .expected = "[1, 2, {\"key\": \"value\"}]" },
        .{ .input = "{\"a\": {\"b\": [\"c\", {\"d\": \"e\",", .expected = "{\"a\": {\"b\": [\"c\", {\"d\": \"e\"}]}}" },
        .{ .input = "{\"a\": {\"b\": {\"c\": {\"d\":", .expected = "{\"a\": {\"b\": {\"c\": {}}}}" },
        .{ .input = "{\"a\": 1, \"b\": [", .expected = "{\"a\": 1, \"b\": []}" },
        .{ .input = "{\"a\": 1, \"b\": {", .expected = "{\"a\": 1, \"b\": {}}" },
        .{ .input = "{\"a\": 1, \"b\": \"", .expected = "{\"a\": 1, \"b\": \"\"}" },
        .{ .input = complex_input, .expected = complex_expected },
        .{ .input = "{\"type\":\"div\",\"children\":[{\"type\":\"Card\",\"props\":{}", .expected = "{\"type\":\"div\",\"children\":[{\"type\":\"Card\",\"props\":{}}]}" },
    };
    try std.testing.expectEqual(60, cases.len);

    for (cases, 0..) |case, index| {
        const actual = try fixJson(std.testing.allocator, case.input);
        defer std.testing.allocator.free(actual);
        std.testing.expectEqualStrings(case.expected, actual) catch |err| {
            std.debug.print("fixJson upstream case {d} failed\n", .{index + 1});
            return err;
        };
    }

    for (cases[22..26]) |case| {
        const repaired = try fixJson(std.testing.allocator, case.input);
        defer std.testing.allocator.free(repaired);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, repaired, .{});
        parsed.deinit();
    }
}

#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "..");
const highlightPath = path.join(
    repositoryRoot,
    "docs",
    "book",
    "theme",
    "highlight.js",
);
const bookSourceDirectory = path.join(repositoryRoot, "docs", "book", "src");

function loadHighlightJs() {
    const source = readFileSync(highlightPath, "utf8");
    const context = vm.createContext({ console });
    vm.runInContext(source, context, { filename: highlightPath });
    assert.ok(context.hljs, "theme/highlight.js did not define hljs");
    return context.hljs;
}

function markdownFiles(directory) {
    const files = [];
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
        const entryPath = path.join(directory, entry.name);
        if (entry.isDirectory()) {
            files.push(...markdownFiles(entryPath));
        } else if (entry.isFile() && entry.name.endsWith(".md")) {
            files.push(entryPath);
        }
    }
    return files.sort();
}

function zigBlocks(filePath) {
    const lines = readFileSync(filePath, "utf8").split(/\r?\n/);
    const blocks = [];

    for (let index = 0; index < lines.length; index += 1) {
        const opening = lines[index].match(/^ {0,3}(`{3,})zig(?:[\s,].*)?$/);
        if (!opening) continue;

        const fenceLength = opening[1].length;
        const code = [];
        const startLine = index + 1;
        let closed = false;

        for (index += 1; index < lines.length; index += 1) {
            const closing = lines[index].match(/^ {0,3}(`{3,})\s*$/);
            if (closing && closing[1].length >= fenceLength) {
                closed = true;
                break;
            }
            code.push(lines[index]);
        }

        assert.ok(
            closed,
            `${path.relative(repositoryRoot, filePath)}:${startLine}: unclosed Zig fence`,
        );
        blocks.push({ code: code.join("\n"), filePath, startLine });
    }

    return blocks;
}

function highlight(hljs, code) {
    const majorVersion = Number.parseInt(hljs.versionString, 10);
    if (majorVersion >= 11) {
        return hljs.highlight(code, { language: "zig", ignoreIllegals: false });
    }

    // mdBook 0.5.2 bundles highlight.js 10.1.1, whose equivalent API uses
    // positional arguments. Keep the modern branch above for future upgrades.
    return hljs.highlight("zig", code, false);
}

function extractCompilerTokens() {
    const zigEnvironment = execFileSync("zig", ["env"], {
        cwd: repositoryRoot,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
    });
    const stdDirectoryMatch = zigEnvironment.match(/\.std_dir\s*=\s*"([^"]+)"/);
    assert.ok(stdDirectoryMatch, "zig env did not report .std_dir");

    const stdDirectory = stdDirectoryMatch[1];
    const tokenSource = readFileSync(
        path.join(stdDirectory, "zig", "tokenizer.zig"),
        "utf8",
    );
    const builtinSource = readFileSync(
        path.join(stdDirectory, "zig", "BuiltinFn.zig"),
        "utf8",
    );

    const keywordMap = tokenSource.match(
        /pub const keywords\s*=\s*std\.StaticStringMap\(Tag\)\.initComptime\(\.\{([\s\S]*?)\n\s*\}\);/,
    );
    assert.ok(keywordMap, "could not locate std.zig.Token.keywords");
    const keywords = [
        ...keywordMap[1].matchAll(
            /\.\{\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*,\s*\.keyword_[A-Za-z0-9_]+\s*\}/g,
        ),
    ].map((match) => match[1]);

    const builtinListStart = builtinSource.indexOf("pub const list = list:");
    const builtinListEnd = builtinSource.indexOf("\n    });\n};", builtinListStart);
    assert.notEqual(builtinListStart, -1, "could not locate std.zig.BuiltinFn.list");
    assert.notEqual(builtinListEnd, -1, "could not find the end of std.zig.BuiltinFn.list");
    const builtinList = builtinSource.slice(builtinListStart, builtinListEnd);
    const builtins = [
        ...builtinList.matchAll(/^\s*"(@[A-Za-z_][A-Za-z0-9_]*)",\s*$/gm),
    ].map((match) => match[1]);

    assert.ok(keywords.length > 0, "stdlib keyword map was empty");
    assert.ok(builtins.length > 0, "stdlib builtin list was empty");
    assert.equal(new Set(keywords).size, keywords.length, "duplicate stdlib keywords");
    assert.equal(new Set(builtins).size, builtins.length, "duplicate stdlib builtins");

    return { builtins, keywords, stdDirectory };
}

function assertSuperset(grammarTokens, compilerTokens, label) {
    const grammarSet = new Set(grammarTokens);
    const missing = compilerTokens.filter((token) => !grammarSet.has(token));
    assert.deepEqual(
        missing,
        [],
        `Zig grammar is missing ${label}: ${missing.join(", ")}`,
    );
}

function countScopes(value) {
    const counts = new Map();
    for (const match of value.matchAll(/class="hljs-([^"\s]+)/g)) {
        counts.set(match[1], (counts.get(match[1]) ?? 0) + 1);
    }
    return counts;
}

const hljs = loadHighlightJs();
const requiredLanguages = [
    "zig",
    "sh",
    "bash",
    "shell",
    "python",
    "rust",
    "c",
    "json",
    "toml",
    "yaml",
    "javascript",
];
const missingLanguages = requiredLanguages.filter(
    (language) => !hljs.getLanguage(language),
);
assert.deepEqual(
    missingLanguages,
    [],
    `highlight.js is missing registered languages: ${missingLanguages.join(", ")}`,
);

const files = markdownFiles(bookSourceDirectory);
const blocks = files.flatMap(zigBlocks);
assert.ok(blocks.length > 0, "no Zig code fences found in the book");
for (const block of blocks) {
    let result;
    try {
        result = highlight(hljs, block.code);
    } catch (error) {
        const location = `${path.relative(repositoryRoot, block.filePath)}:${block.startLine}`;
        throw new Error(`${location}: Zig highlighting failed: ${error.message}`, {
            cause: error,
        });
    }
    assert.equal(
        result.illegal,
        false,
        `${path.relative(repositoryRoot, block.filePath)}:${block.startLine}: illegal Zig token`,
    );
}

const compilerTokens = extractCompilerTokens();
const zigGrammar = hljs.getLanguage("zig");
assert.ok(
    zigGrammar._aiZigTokenSets,
    "Zig grammar does not expose its compiler-derived token sets",
);
assertSuperset(
    zigGrammar._aiZigTokenSets.keyword,
    compilerTokens.keywords,
    "keywords",
);
assertSuperset(
    zigGrammar._aiZigTokenSets.built_in,
    compilerTokens.builtins,
    "builtins",
);

const canonicalSnippet = `
/// Canonical documentation comment.
pub fn canonical(value: u32) bool {
    const text = "zig";
    const marker = 'Z';
    const wide: f64 = @floatFromInt(value);
    // Canonical line comment.
    return @as(bool, wide > 1.0) and text.len > 0 and marker != 0;
}
`;
const canonicalResult = highlight(hljs, canonicalSnippet);
assert.equal(canonicalResult.illegal, false, "canonical Zig snippet was illegal");
const scopeCounts = countScopes(canonicalResult.value);
const minimumScopeHits = 2;
const requiredScopes = ["keyword", "type", "built_in", "string", "comment"];
for (const scope of requiredScopes) {
    assert.ok(
        (scopeCounts.get(scope) ?? 0) >= minimumScopeHits,
        `canonical snippet produced fewer than ${minimumScopeHits} hljs-${scope} spans`,
    );
}

const filesWithZig = new Set(blocks.map((block) => block.filePath)).size;
const scopeSummary = requiredScopes
    .map((scope) => `${scope}=${scopeCounts.get(scope) ?? 0}`)
    .join(", ");
console.log("book highlight check passed");
console.log(
    `  bundle: highlight.js ${hljs.versionString}; ${requiredLanguages.length} required names registered`,
);
console.log(`  fences: ${blocks.length} Zig blocks across ${filesWithZig} Markdown files`);
console.log(
    `  compiler: ${compilerTokens.keywords.length} keywords, ${compilerTokens.builtins.length} builtins; grammar is a superset`,
);
console.log(`  sanity: minimum ${minimumScopeHits} spans; ${scopeSummary}`);

const std = @import("std");
const DocumentStore = @import("DocumentStore.zig");
const Ast = std.zig.Ast;
const types = @import("lsp.zig");
const offsets = @import("offsets.zig");
const URI = @import("uri.zig");
const log = std.log.scoped(.zls_analysis);
const ast = @import("ast.zig");
const tracy = @import("tracy.zig");
const ComptimeInterpreter = @import("ComptimeInterpreter.zig");
const InternPool = ComptimeInterpreter.InternPool;
const references = @import("features/references.zig");

const Analyser = @This();

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
store: *DocumentStore,
ip: ?InternPool,
bound_type_params: std.AutoHashMapUnmanaged(Ast.full.FnProto.Param, TypeWithHandle) = .{},
using_trail: std.AutoHashMapUnmanaged(Ast.Node.Index, void) = .{},
resolved_nodes: std.HashMapUnmanaged(NodeWithUri, ?TypeWithHandle, NodeWithUri.Context, std.hash_map.default_max_load_percentage) = .{},

pub fn init(gpa: std.mem.Allocator, store: *DocumentStore) Analyser {
    return .{
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .store = store,
        .ip = null,
    };
}

pub fn deinit(self: *Analyser) void {
    self.bound_type_params.deinit(self.gpa);
    self.using_trail.deinit(self.gpa);
    self.resolved_nodes.deinit(self.gpa);
    if (self.ip) |*intern_pool| intern_pool.deinit(self.gpa);
    self.arena.deinit();
}

pub fn invalidate(self: *Analyser) void {
    self.bound_type_params.clearRetainingCapacity();
    self.using_trail.clearRetainingCapacity();
    self.resolved_nodes.clearRetainingCapacity();
    _ = self.arena.reset(.free_all);
}

/// Gets a declaration's doc comments. Caller owns returned memory.
pub fn getDocComments(allocator: std.mem.Allocator, tree: Ast, node: Ast.Node.Index, format: types.MarkupKind) !?[]const u8 {
    const base = tree.nodes.items(.main_token)[node];
    const base_kind = tree.nodes.items(.tag)[node];
    const tokens = tree.tokens.items(.tag);

    switch (base_kind) {
        // As far as I know, this does not actually happen yet, but it
        // may come in useful.
        .root => return try collectDocComments(allocator, tree, 0, format, true),
        .fn_proto,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_decl,
        .local_var_decl,
        .global_var_decl,
        .aligned_var_decl,
        .simple_var_decl,
        .container_field_init,
        .container_field,
        => {
            if (getDocCommentTokenIndex(tokens, base)) |doc_comment_index|
                return try collectDocComments(allocator, tree, doc_comment_index, format, false);
        },
        else => {},
    }
    return null;
}

/// Get the first doc comment of a declaration.
pub fn getDocCommentTokenIndex(tokens: []const std.zig.Token.Tag, base_token: Ast.TokenIndex) ?Ast.TokenIndex {
    var idx = base_token;
    if (idx == 0) return null;
    idx -|= 1;
    if (tokens[idx] == .keyword_threadlocal and idx > 0) idx -|= 1;
    if (tokens[idx] == .string_literal and idx > 1 and tokens[idx -| 1] == .keyword_extern) idx -|= 1;
    if (tokens[idx] == .keyword_extern and idx > 0) idx -|= 1;
    if (tokens[idx] == .keyword_export and idx > 0) idx -|= 1;
    if (tokens[idx] == .keyword_inline and idx > 0) idx -|= 1;
    if (tokens[idx] == .identifier and idx > 0) idx -|= 1;
    if (tokens[idx] == .keyword_pub and idx > 0) idx -|= 1;

    // Find first doc comment token
    if (!(tokens[idx] == .doc_comment))
        return null;
    return while (tokens[idx] == .doc_comment) {
        if (idx == 0) break 0;
        idx -|= 1;
    } else idx + 1;
}

pub fn collectDocComments(allocator: std.mem.Allocator, tree: Ast, doc_comments: Ast.TokenIndex, format: types.MarkupKind, container_doc: bool) ![]const u8 {
    var lines = std.ArrayList([]const u8).init(allocator);
    defer lines.deinit();
    const tokens = tree.tokens.items(.tag);

    var curr_line_tok = doc_comments;
    while (true) : (curr_line_tok += 1) {
        const comm = tokens[curr_line_tok];
        if ((container_doc and comm == .container_doc_comment) or (!container_doc and comm == .doc_comment)) {
            try lines.append(std.mem.trim(u8, tree.tokenSlice(curr_line_tok)[3..], &std.ascii.whitespace));
        } else break;
    }

    return try std.mem.join(allocator, if (format == .markdown) "  \n" else "\n", lines.items);
}

/// Gets a function's keyword, name, arguments and return value.
pub fn getFunctionSignature(tree: Ast, func: Ast.full.FnProto) []const u8 {
    const start = offsets.tokenToLoc(tree, func.ast.fn_token);

    const end = if (func.ast.return_type != 0)
        offsets.tokenToLoc(tree, ast.lastToken(tree, func.ast.return_type))
    else
        start;
    return tree.source[start.start..end.end];
}

fn formatSnippetPlaceholder(
    data: []const u8,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    var split_it = std.mem.split(u8, data, "}");
    while (split_it.next()) |segment| {
        try writer.writeAll(segment);
        if (split_it.index) |index|
            if (data[index - 1] == '}') {
                try writer.writeAll("\\}");
            };
    }
}

const SnippetPlaceholderFormatter = std.fmt.Formatter(formatSnippetPlaceholder);

fn fmtSnippetPlaceholder(bytes: []const u8) SnippetPlaceholderFormatter {
    return .{ .data = bytes };
}

/// Creates snippet insert text for a function. Caller owns returned memory.
pub fn getFunctionSnippet(allocator: std.mem.Allocator, tree: Ast, func: Ast.full.FnProto, skip_self_param: bool) ![]const u8 {
    const name_index = func.name_token.?;

    var buffer = std.ArrayListUnmanaged(u8){};
    try buffer.ensureTotalCapacity(allocator, 128);

    var buf_stream = buffer.writer(allocator);

    try buf_stream.writeAll(tree.tokenSlice(name_index));
    try buf_stream.writeByte('(');

    const token_tags = tree.tokens.items(.tag);

    var it = func.iterate(&tree);
    var i: usize = 0;
    while (ast.nextFnParam(&it)) |param| : (i += 1) {
        if (skip_self_param and i == 0) continue;
        if (i != @boolToInt(skip_self_param))
            try buf_stream.writeAll(", ${")
        else
            try buf_stream.writeAll("${");

        try buf_stream.print("{d}:", .{i + 1});

        if (param.comptime_noalias) |token_index| {
            if (token_tags[token_index] == .keyword_comptime)
                try buf_stream.writeAll("comptime ")
            else
                try buf_stream.writeAll("noalias ");
        }

        if (param.name_token) |name_token| {
            try buf_stream.print("{}", .{fmtSnippetPlaceholder(tree.tokenSlice(name_token))});
            try buf_stream.writeAll(": ");
        }

        if (param.anytype_ellipsis3) |token_index| {
            if (token_tags[token_index] == .keyword_anytype)
                try buf_stream.writeAll("anytype")
            else
                try buf_stream.writeAll("...");
        } else if (param.type_expr != 0) {
            var curr_token = tree.firstToken(param.type_expr);
            var end_token = ast.lastToken(tree, param.type_expr);
            while (curr_token <= end_token) : (curr_token += 1) {
                const tag = token_tags[curr_token];
                const is_comma = tag == .comma;

                if (curr_token == end_token and is_comma) continue;
                try buf_stream.print("{}", .{fmtSnippetPlaceholder(tree.tokenSlice(curr_token))});
                if (is_comma or tag == .keyword_const) try buf_stream.writeByte(' ');
            }
        } // else Incomplete and that's ok :)

        try buf_stream.writeByte('}');
    }
    try buf_stream.writeByte(')');

    return buffer.toOwnedSlice(allocator);
}

pub fn hasSelfParam(analyser: *Analyser, handle: *const DocumentStore.Handle, func: Ast.full.FnProto) !bool {
    // Non-decl prototypes cannot have a self parameter.
    if (func.name_token == null) return false;
    if (func.ast.params.len == 0) return false;

    const tree = handle.tree;
    var it = func.iterate(&tree);
    const param = ast.nextFnParam(&it).?;
    if (param.type_expr == 0) return false;

    const token_starts = tree.tokens.items(.start);
    const in_container = innermostContainer(handle, token_starts[func.ast.fn_token]);

    if (try analyser.resolveTypeOfNode(.{
        .node = param.type_expr,
        .handle = handle,
    })) |resolved_type| {
        if (std.meta.eql(in_container, resolved_type))
            return true;
    }

    if (ast.fullPtrType(tree, param.type_expr)) |ptr_type| {
        if (try analyser.resolveTypeOfNode(.{
            .node = ptr_type.ast.child_type,
            .handle = handle,
        })) |resolved_prefix_op| {
            if (std.meta.eql(in_container, resolved_prefix_op))
                return true;
        }
    }
    return false;
}

pub fn getVariableSignature(tree: Ast, var_decl: Ast.full.VarDecl) []const u8 {
    const start = offsets.tokenToIndex(tree, var_decl.ast.mut_token);
    const end = offsets.tokenToLoc(tree, ast.lastToken(tree, var_decl.ast.init_node)).end;
    return tree.source[start..end];
}

pub fn getContainerFieldSignature(tree: Ast, field: Ast.full.ContainerField) []const u8 {
    if (field.ast.value_expr == 0 and field.ast.type_expr == 0 and field.ast.align_expr == 0) {
        return ""; // TODO display the container's type
    }
    const start = offsets.tokenToIndex(tree, field.ast.main_token);
    const end_node = if (field.ast.value_expr != 0) field.ast.value_expr else field.ast.type_expr;
    const end = offsets.tokenToLoc(tree, ast.lastToken(tree, end_node)).end;
    return tree.source[start..end];
}

/// The node is the meta-type `type`
fn isMetaType(tree: Ast, node: Ast.Node.Index) bool {
    if (tree.nodes.items(.tag)[node] == .identifier) {
        return std.mem.eql(u8, tree.tokenSlice(tree.nodes.items(.main_token)[node]), "type");
    }
    return false;
}

pub fn isTypeFunction(tree: Ast, func: Ast.full.FnProto) bool {
    return isMetaType(tree, func.ast.return_type);
}

pub fn isGenericFunction(tree: Ast, func: Ast.full.FnProto) bool {
    var it = func.iterate(&tree);
    while (ast.nextFnParam(&it)) |param| {
        if (param.anytype_ellipsis3 != null or param.comptime_noalias != null) {
            return true;
        }
    }
    return false;
}

// STYLE

pub fn isCamelCase(name: []const u8) bool {
    return !std.ascii.isUpper(name[0]) and !isSnakeCase(name);
}

pub fn isPascalCase(name: []const u8) bool {
    return std.ascii.isUpper(name[0]) and !isSnakeCase(name);
}

pub fn isSnakeCase(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "_") != null;
}

// ANALYSIS ENGINE

pub fn getDeclNameToken(tree: Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const main_token = tree.nodes.items(.main_token)[node];

    return switch (tags[node]) {
        // regular declaration names. + 1 to mut token because name comes after 'const'/'var'
        .local_var_decl,
        .global_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => {
            const tok = tree.fullVarDecl(node).?.ast.mut_token + 1;
            return if (tok >= tree.tokens.len)
                null
            else
                tok;
        },
        // function declaration names
        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_decl,
        => blk: {
            var params: [1]Ast.Node.Index = undefined;
            break :blk tree.fullFnProto(&params, node).?.name_token;
        },

        // containers
        .container_field,
        .container_field_init,
        .container_field_align,
        => {
            const field = tree.fullContainerField(node).?.ast;
            return field.main_token;
        },

        .identifier => main_token,
        .error_value => {
            const tok = main_token + 2;
            return if (tok >= tree.tokens.len)
                null
            else
                tok;
        }, // 'error'.<main_token +2>

        .test_decl => datas[node].lhs,

        else => null,
    };
}

pub fn getDeclName(tree: Ast, node: Ast.Node.Index) ?[]const u8 {
    const name_token = getDeclNameToken(tree, node) orelse return null;
    const name = offsets.tokenToSlice(tree, name_token);

    if (tree.nodes.items(.tag)[node] == .test_decl and
        tree.tokens.items(.tag)[name_token] == .string_literal)
    {
        return name[1 .. name.len - 1];
    }

    return name;
}

fn resolveVarDeclAliasInternal(analyser: *Analyser, node_handle: NodeWithHandle) error{OutOfMemory}!?DeclWithHandle {
    const handle = node_handle.handle;
    const tree = handle.tree;
    const node_tags = tree.nodes.items(.tag);
    const main_tokens = tree.nodes.items(.main_token);
    const datas = tree.nodes.items(.data);

    if (node_tags[node_handle.node] == .identifier) {
        const token = main_tokens[node_handle.node];
        return try analyser.lookupSymbolGlobal(
            handle,
            tree.tokenSlice(token),
            tree.tokens.items(.start)[token],
        );
    }

    if (node_tags[node_handle.node] == .field_access) {
        const lhs = datas[node_handle.node].lhs;

        const container_node = if (ast.isBuiltinCall(tree, lhs)) block: {
            const name = tree.tokenSlice(main_tokens[lhs]);
            if (!std.mem.eql(u8, name, "@import") and !std.mem.eql(u8, name, "@cImport"))
                return null;

            const inner_node = (try analyser.resolveTypeOfNode(.{ .node = lhs, .handle = handle })) orelse return null;
            // assert root node
            std.debug.assert(inner_node.type.data.other == 0);
            break :block NodeWithHandle{ .node = inner_node.type.data.other, .handle = inner_node.handle };
        } else if (try analyser.resolveVarDeclAliasInternal(.{ .node = lhs, .handle = handle })) |decl_handle| block: {
            if (decl_handle.decl.* != .ast_node) return null;
            const resolved = (try analyser.resolveTypeOfNode(.{ .node = decl_handle.decl.ast_node, .handle = decl_handle.handle })) orelse return null;
            const resolved_node = switch (resolved.type.data) {
                .other => |n| n,
                else => return null,
            };
            if (!ast.isContainer(resolved.handle.tree, resolved_node)) return null;
            break :block NodeWithHandle{ .node = resolved_node, .handle = resolved.handle };
        } else return null;

        return try analyser.lookupSymbolContainer(container_node, tree.tokenSlice(datas[node_handle.node].rhs), false);
    }
    return null;
}

/// Resolves variable declarations consisting of chains of imports and field accesses of containers, ending with the same name as the variable decl's name
/// Examples:
///```zig
/// const decl = @import("decl-file.zig").decl;
/// const other = decl.middle.other;
///```
pub fn resolveVarDeclAlias(analyser: *Analyser, decl_handle: NodeWithHandle) !?DeclWithHandle {
    const decl = decl_handle.node;
    const handle = decl_handle.handle;
    const tree = handle.tree;
    const token_tags = tree.tokens.items(.tag);
    const node_tags = tree.nodes.items(.tag);

    if (handle.tree.fullVarDecl(decl)) |var_decl| {
        if (var_decl.ast.init_node == 0) return null;
        const base_exp = var_decl.ast.init_node;
        if (token_tags[var_decl.ast.mut_token] != .keyword_const) return null;

        if (node_tags[base_exp] == .field_access) {
            const name = tree.tokenSlice(tree.nodes.items(.data)[base_exp].rhs);
            if (!std.mem.eql(u8, tree.tokenSlice(var_decl.ast.mut_token + 1), name))
                return null;

            return try analyser.resolveVarDeclAliasInternal(.{ .node = base_exp, .handle = handle });
        }
    }

    return null;
}

fn findReturnStatementInternal(tree: Ast, fn_decl: Ast.full.FnProto, body: Ast.Node.Index, already_found: *bool) ?Ast.Node.Index {
    var result: ?Ast.Node.Index = null;

    const node_tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    var buffer: [2]Ast.Node.Index = undefined;
    const statements = ast.blockStatements(tree, body, &buffer) orelse return null;

    for (statements) |child_idx| {
        if (node_tags[child_idx] == .@"return") {
            if (datas[child_idx].lhs != 0) {
                const lhs = datas[child_idx].lhs;
                var buf: [1]Ast.Node.Index = undefined;
                if (tree.fullCall(&buf, lhs)) |call| {
                    const call_name = getDeclName(tree, call.ast.fn_expr);
                    if (call_name) |name| {
                        if (std.mem.eql(u8, name, tree.tokenSlice(fn_decl.name_token.?))) {
                            continue;
                        }
                    }
                }
            }

            if (already_found.*) return null;
            already_found.* = true;
            result = child_idx;
            continue;
        }

        result = findReturnStatementInternal(tree, fn_decl, child_idx, already_found);
    }

    return result;
}

fn findReturnStatement(tree: Ast, fn_decl: Ast.full.FnProto, body: Ast.Node.Index) ?Ast.Node.Index {
    var already_found = false;
    return findReturnStatementInternal(tree, fn_decl, body, &already_found);
}

fn resolveReturnType(analyser: *Analyser, fn_decl: Ast.full.FnProto, handle: *const DocumentStore.Handle, fn_body: ?Ast.Node.Index) !?TypeWithHandle {
    const tree = handle.tree;
    if (isTypeFunction(tree, fn_decl) and fn_body != null) {
        // If this is a type function and it only contains a single return statement that returns
        // a container declaration, we will return that declaration.
        const ret = findReturnStatement(tree, fn_decl, fn_body.?) orelse return null;
        const data = tree.nodes.items(.data)[ret];
        if (data.lhs != 0) {
            return try analyser.resolveTypeOfNodeInternal(.{ .node = data.lhs, .handle = handle });
        }

        return null;
    }

    if (fn_decl.ast.return_type == 0) return null;
    const return_type = fn_decl.ast.return_type;
    const ret = .{ .node = return_type, .handle = handle };
    const child_type = (try analyser.resolveTypeOfNodeInternal(ret)) orelse
        return null;

    const is_inferred_error = tree.tokens.items(.tag)[tree.firstToken(return_type) - 1] == .bang;
    if (is_inferred_error) {
        const child_type_node = switch (child_type.type.data) {
            .other => |n| n,
            else => return null,
        };
        return TypeWithHandle{
            .type = .{ .data = .{ .error_union = child_type_node }, .is_type_val = false },
            .handle = child_type.handle,
        };
    } else return child_type.instanceTypeVal();
}

/// Resolves the child type of an optional type
fn resolveUnwrapOptionalType(analyser: *Analyser, opt: TypeWithHandle) !?TypeWithHandle {
    const opt_node = switch (opt.type.data) {
        .other => |n| n,
        else => return null,
    };

    if (opt.handle.tree.nodes.items(.tag)[opt_node] == .optional_type) {
        return ((try analyser.resolveTypeOfNodeInternal(.{
            .node = opt.handle.tree.nodes.items(.data)[opt_node].lhs,
            .handle = opt.handle,
        })) orelse return null).instanceTypeVal();
    }

    return null;
}

fn resolveUnwrapErrorType(analyser: *Analyser, rhs: TypeWithHandle) !?TypeWithHandle {
    const rhs_node = switch (rhs.type.data) {
        .other => |n| n,
        .error_union => |n| return TypeWithHandle{
            .type = .{ .data = .{ .other = n }, .is_type_val = rhs.type.is_type_val },
            .handle = rhs.handle,
        },
        .primitive, .slice, .pointer, .array_index, .@"comptime", .either => return null,
    };

    if (rhs.handle.tree.nodes.items(.tag)[rhs_node] == .error_union) {
        return ((try analyser.resolveTypeOfNodeInternal(.{
            .node = rhs.handle.tree.nodes.items(.data)[rhs_node].rhs,
            .handle = rhs.handle,
        })) orelse return null).instanceTypeVal();
    }

    return null;
}

/// Resolves the child type of a deref type
fn resolveDerefType(analyser: *Analyser, deref: TypeWithHandle) !?TypeWithHandle {
    const deref_node = switch (deref.type.data) {
        .other => |n| n,
        .pointer => |n| return TypeWithHandle{
            .type = .{
                .is_type_val = false,
                .data = .{ .other = n },
            },
            .handle = deref.handle,
        },
        else => return null,
    };
    const tree = deref.handle.tree;
    const main_token = tree.nodes.items(.main_token)[deref_node];
    const token_tag = tree.tokens.items(.tag)[main_token];

    if (ast.fullPtrType(tree, deref_node)) |ptr_type| {
        switch (token_tag) {
            .asterisk => {
                return ((try analyser.resolveTypeOfNodeInternal(.{
                    .node = ptr_type.ast.child_type,
                    .handle = deref.handle,
                })) orelse return null).instanceTypeVal();
            },
            .l_bracket, .asterisk_asterisk => return null,
            else => unreachable,
        }
    }
    return null;
}

/// Resolves slicing and array access
fn resolveBracketAccessType(analyser: *Analyser, lhs: TypeWithHandle, rhs: enum { Single, Range }) !?TypeWithHandle {
    const lhs_node = switch (lhs.type.data) {
        .other => |n| n,
        else => return null,
    };

    const tree = lhs.handle.tree;
    const tags = tree.nodes.items(.tag);
    const tag = tags[lhs_node];
    const data = tree.nodes.items(.data)[lhs_node];

    if (tag == .array_type or tag == .array_type_sentinel) {
        if (rhs == .Single)
            return ((try analyser.resolveTypeOfNodeInternal(.{
                .node = data.rhs,
                .handle = lhs.handle,
            })) orelse return null).instanceTypeVal();
        return TypeWithHandle{
            .type = .{ .data = .{ .slice = data.rhs }, .is_type_val = false },
            .handle = lhs.handle,
        };
    } else if (ast.fullPtrType(tree, lhs_node)) |ptr_type| {
        if (ptr_type.size == .Slice) {
            if (rhs == .Single) {
                return ((try analyser.resolveTypeOfNodeInternal(.{
                    .node = ptr_type.ast.child_type,
                    .handle = lhs.handle,
                })) orelse return null).instanceTypeVal();
            }
            return lhs;
        }
    }

    return null;
}

/// Called to remove one level of pointerness before a field access
pub fn resolveFieldAccessLhsType(analyser: *Analyser, lhs: TypeWithHandle) !TypeWithHandle {
    // analyser.bound_type_params.clearRetainingCapacity();
    return (try analyser.resolveDerefType(lhs)) orelse lhs;
}

fn allDigits(str: []const u8) bool {
    for (str) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

pub fn isValueIdent(text: []const u8) bool {
    const PrimitiveTypes = std.ComptimeStringMap(void, .{
        .{"true"},
        .{"false"},
        .{"null"},
        .{"undefined"},
    });
    return PrimitiveTypes.has(text);
}

pub fn isTypeIdent(text: []const u8) bool {
    const PrimitiveTypes = std.ComptimeStringMap(void, .{
        .{"isize"},        .{"usize"},
        .{"c_short"},      .{"c_ushort"},
        .{"c_int"},        .{"c_uint"},
        .{"c_long"},       .{"c_ulong"},
        .{"c_longlong"},   .{"c_ulonglong"},
        .{"c_longdouble"}, .{"anyopaque"},
        .{"f16"},          .{"f32"},
        .{"f64"},          .{"f80"},
        .{"f128"},         .{"bool"},
        .{"void"},         .{"noreturn"},
        .{"type"},         .{"anyerror"},
        .{"comptime_int"}, .{"comptime_float"},
        .{"anyframe"},     .{"anytype"},
        .{"c_char"},
    });

    if (PrimitiveTypes.has(text)) return true;
    if (text.len == 1) return false;
    if (!(text[0] == 'u' or text[0] == 'i')) return false;
    if (!allDigits(text[1..])) return false;
    _ = std.fmt.parseUnsigned(u16, text[1..], 10) catch return false;
    return true;
}

/// Resolves the type of a node
fn resolveTypeOfNodeInternal(analyser: *Analyser, node_handle: NodeWithHandle) error{OutOfMemory}!?TypeWithHandle {
    const node_with_uri = NodeWithUri{
        .node = node_handle.node,
        .uri = node_handle.handle.uri,
    };
    const gop = try analyser.resolved_nodes.getOrPut(analyser.gpa, node_with_uri);
    if (gop.found_existing) return gop.value_ptr.*;

    // we insert null before resolving the type so that a recursive definition doesn't result in an infinite loop
    gop.value_ptr.* = null;

    const type_handle = try analyser.resolveTypeOfNodeUncached(node_handle);
    analyser.resolved_nodes.getPtr(node_with_uri).?.* = type_handle;

    return type_handle;

    // if (analyser.resolved_nodes.get(node_handle)) |type_handle| return type_handle;

    //// If we were asked to resolve this node before,
    //// it is self-referential and we cannot resolve it.
    //for (analyser.resolve_trail.items) |i| {
    //    if (std.meta.eql(i, node_handle))
    //        return null;
    //}
    //try analyser.resolve_trail.append(analyser.gpa, node_handle);
    //defer _ = analyser.resolve_trail.pop();

}

fn resolveTypeOfNodeUncached(analyser: *Analyser, node_handle: NodeWithHandle) error{OutOfMemory}!?TypeWithHandle {
    const node = node_handle.node;
    const handle = node_handle.handle;
    const tree = handle.tree;

    const main_tokens = tree.nodes.items(.main_token);
    const node_tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const token_tags = tree.tokens.items(.tag);
    const starts = tree.tokens.items(.start);

    switch (node_tags[node]) {
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => {
            const var_decl = tree.fullVarDecl(node).?;
            if (var_decl.ast.type_node != 0) {
                const decl_type = .{ .node = var_decl.ast.type_node, .handle = handle };
                if (try analyser.resolveTypeOfNodeInternal(decl_type)) |typ|
                    return typ.instanceTypeVal();
            }
            if (var_decl.ast.init_node == 0)
                return null;

            const value = .{ .node = var_decl.ast.init_node, .handle = handle };
            return try analyser.resolveTypeOfNodeInternal(value);
        },
        .identifier => {
            const name = offsets.nodeToSlice(tree, node);

            if (isTypeIdent(name)) {
                return TypeWithHandle{
                    .type = .{ .data = .{ .primitive = node }, .is_type_val = true },
                    .handle = handle,
                };
            }

            if (try analyser.lookupSymbolGlobal(
                handle,
                name,
                starts[main_tokens[node]],
            )) |child| {
                switch (child.decl.*) {
                    .ast_node => |n| {
                        if (n == node) return null;
                        if (child.handle.tree.fullVarDecl(n)) |var_decl| {
                            if (var_decl.ast.init_node == node)
                                return null;
                        }
                    },
                    else => {},
                }
                return try child.resolveType(analyser);
            }
            return null;
        },
        .call,
        .call_comma,
        .async_call,
        .async_call_comma,
        .call_one,
        .call_one_comma,
        .async_call_one,
        .async_call_one_comma,
        => {
            var params: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&params, node) orelse unreachable;

            const callee = .{ .node = call.ast.fn_expr, .handle = handle };
            const decl = (try analyser.resolveTypeOfNodeInternal(callee)) orelse
                return null;

            if (decl.type.is_type_val) return null;
            const decl_node = switch (decl.type.data) {
                .other => |n| n,
                else => return null,
            };
            var buf: [1]Ast.Node.Index = undefined;
            const func_maybe = decl.handle.tree.fullFnProto(&buf, decl_node);

            if (func_maybe) |fn_decl| {
                var expected_params = fn_decl.ast.params.len;
                // If we call as method, the first parameter should be skipped
                // TODO: Back-parse to extract the self argument?
                var it = fn_decl.iterate(&decl.handle.tree);
                if (token_tags[call.ast.lparen - 2] == .period) {
                    if (try analyser.hasSelfParam(decl.handle, fn_decl)) {
                        _ = ast.nextFnParam(&it);
                        expected_params -= 1;
                    }
                }

                // Bind type params to the arguments passed in the call.
                const param_len = std.math.min(call.ast.params.len, expected_params);
                var i: usize = 0;
                while (ast.nextFnParam(&it)) |decl_param| : (i += 1) {
                    if (i >= param_len) break;
                    if (!isMetaType(decl.handle.tree, decl_param.type_expr))
                        continue;

                    const argument = .{ .node = call.ast.params[i], .handle = handle };
                    const argument_type = (try analyser.resolveTypeOfNodeInternal(
                        argument,
                    )) orelse
                        continue;
                    if (!argument_type.type.is_type_val) continue;

                    try analyser.bound_type_params.put(analyser.gpa, decl_param, argument_type);
                }

                const has_body = decl.handle.tree.nodes.items(.tag)[decl_node] == .fn_decl;
                const body = decl.handle.tree.nodes.items(.data)[decl_node].rhs;
                if (try analyser.resolveReturnType(fn_decl, decl.handle, if (has_body) body else null)) |ret| {
                    return ret;
                } else if (analyser.store.config.dangerous_comptime_experiments_do_not_enable) {
                    // TODO: Better case-by-case; we just use the ComptimeInterpreter when all else fails,
                    // probably better to use it more liberally
                    // TODO: Handle non-isolate args; e.g. `const T = u8; TypeFunc(T);`
                    // var interpreter = ComptimeInterpreter{ .tree = tree, .allocator = arena.allocator() };

                    // var top_decl = try (try interpreter.interpret(0, null, .{})).getValue();
                    // var top_scope = interpreter.typeToTypeInfo(top_decl.@"type".info_idx).@"struct".scope;

                    // var fn_decl_scope = top_scope.getParentScopeFromNode(node);

                    log.info("Invoking interpreter!", .{});

                    const interpreter = analyser.store.ensureInterpreterExists(handle.uri, &analyser.ip.?) catch |err| {
                        log.err("Failed to interpret file: {s}", .{@errorName(err)});
                        if (@errorReturnTrace()) |trace| {
                            std.debug.dumpStackTrace(trace.*);
                        }
                        return null;
                    };

                    const root_namespace = @intToEnum(ComptimeInterpreter.Namespace.Index, 0);

                    // TODO: Start from current/nearest-current scope
                    const result = interpreter.interpret(node, root_namespace, .{}) catch |err| {
                        log.err("Failed to interpret node: {s}", .{@errorName(err)});
                        if (@errorReturnTrace()) |trace| {
                            std.debug.dumpStackTrace(trace.*);
                        }
                        return null;
                    };
                    const value = result.getValue() catch |err| {
                        log.err("interpreter return no result: {s}", .{@errorName(err)});
                        if (@errorReturnTrace()) |trace| {
                            std.debug.dumpStackTrace(trace.*);
                        }
                        return null;
                    };
                    const is_type_val = interpreter.ip.indexToKey(value.index).typeOf() == .type_type;

                    return TypeWithHandle{
                        .type = .{
                            .data = .{ .@"comptime" = .{
                                .interpreter = interpreter,
                                .value = value,
                            } },
                            .is_type_val = is_type_val,
                        },
                        .handle = node_handle.handle,
                    };
                }
            }
            return null;
        },
        .@"comptime",
        .@"nosuspend",
        .grouped_expression,
        .container_field,
        .container_field_init,
        .container_field_align,
        .struct_init,
        .struct_init_comma,
        .struct_init_one,
        .struct_init_one_comma,
        .slice,
        .slice_sentinel,
        .slice_open,
        .deref,
        .unwrap_optional,
        .array_access,
        .@"orelse",
        .@"catch",
        .@"try",
        .address_of,
        => {
            const base = .{ .node = datas[node].lhs, .handle = handle };
            const base_type = (try analyser.resolveTypeOfNodeInternal(base)) orelse
                return null;
            return switch (node_tags[node]) {
                .@"comptime",
                .@"nosuspend",
                .grouped_expression,
                => base_type,
                .container_field,
                .container_field_init,
                .container_field_align,
                .struct_init,
                .struct_init_comma,
                .struct_init_one,
                .struct_init_one_comma,
                => base_type.instanceTypeVal(),
                .slice,
                .slice_sentinel,
                .slice_open,
                => try analyser.resolveBracketAccessType(base_type, .Range),
                .deref => try analyser.resolveDerefType(base_type),
                .unwrap_optional => try analyser.resolveUnwrapOptionalType(base_type),
                .array_access => try analyser.resolveBracketAccessType(base_type, .Single),
                .@"orelse" => try analyser.resolveUnwrapOptionalType(base_type),
                .@"catch" => try analyser.resolveUnwrapErrorType(base_type),
                .@"try" => try analyser.resolveUnwrapErrorType(base_type),
                .address_of => {
                    const lhs_node = switch (base_type.type.data) {
                        .other => |n| n,
                        else => return null,
                    };
                    return TypeWithHandle{
                        .type = .{ .data = .{ .pointer = lhs_node }, .is_type_val = base_type.type.is_type_val },
                        .handle = base_type.handle,
                    };
                },
                else => unreachable,
            };
        },
        .field_access => {
            if (datas[node].rhs == 0) return null;

            const lhs = (try analyser.resolveTypeOfNodeInternal(.{
                .node = datas[node].lhs,
                .handle = handle,
            })) orelse return null;

            // If we are accessing a pointer type, remove one pointerness level :)
            const left_type = (try analyser.resolveDerefType(lhs)) orelse lhs;

            const left_type_node = switch (left_type.type.data) {
                .other => |n| n,
                else => return null,
            };

            if (try analyser.lookupSymbolContainer(
                .{ .node = left_type_node, .handle = left_type.handle },
                tree.tokenSlice(datas[node].rhs),
                !left_type.type.is_type_val,
            )) |child| {
                return try child.resolveType(analyser);
            } else return null;
        },
        .array_type,
        .array_type_sentinel,
        .optional_type,
        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type,
        .ptr_type_bit_range,
        .error_union,
        .error_set_decl,
        .container_decl,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => return TypeWithHandle.typeVal(node_handle),
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            var buffer: [2]Ast.Node.Index = undefined;
            const params = ast.builtinCallParams(tree, node, &buffer).?;

            const call_name = tree.tokenSlice(main_tokens[node]);
            if (std.mem.eql(u8, call_name, "@This")) {
                if (params.len != 0) return null;
                return innermostContainer(handle, starts[tree.firstToken(node)]);
            }

            const cast_map = std.ComptimeStringMap(void, .{
                .{"@as"},
                .{"@bitCast"},
                .{"@fieldParentPtr"},
                .{"@floatCast"},
                .{"@floatToInt"},
                .{"@intCast"},
                .{"@intToEnum"},
                .{"@intToFloat"},
                .{"@intToPtr"},
                .{"@truncate"},
                .{"@ptrCast"},
            });
            if (cast_map.has(call_name)) {
                if (params.len < 1) return null;
                return ((try analyser.resolveTypeOfNodeInternal(.{
                    .node = params[0],
                    .handle = handle,
                })) orelse return null).instanceTypeVal();
            }

            // Almost the same as the above, return a type value though.
            // TODO Do peer type resolution, we just keep the first for now.
            if (std.mem.eql(u8, call_name, "@TypeOf")) {
                if (params.len < 1) return null;
                var resolved_type = (try analyser.resolveTypeOfNodeInternal(.{
                    .node = params[0],
                    .handle = handle,
                })) orelse return null;

                if (resolved_type.type.is_type_val) return null;
                resolved_type.type.is_type_val = true;
                return resolved_type;
            }

            if (std.mem.eql(u8, call_name, "@typeInfo")) {
                const zig_lib_path = try URI.fromPath(analyser.arena.allocator(), analyser.store.config.zig_lib_path orelse return null);

                const builtin_uri = URI.pathRelative(analyser.arena.allocator(), zig_lib_path, "/std/builtin.zig") catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    else => return null,
                };

                const new_handle = analyser.store.getOrLoadHandle(builtin_uri) orelse return null;
                const root_scope_decls = new_handle.document_scope.scopes.items(.decls)[0];
                const decl_index = root_scope_decls.get("Type") orelse return null;
                const decl = new_handle.document_scope.decls.items[@enumToInt(decl_index)];
                if (decl != .ast_node) return null;

                const var_decl = new_handle.tree.fullVarDecl(decl.ast_node) orelse return null;

                return TypeWithHandle{
                    .type = .{
                        .data = .{ .other = var_decl.ast.init_node },
                        .is_type_val = false,
                    },
                    .handle = new_handle,
                };
            }

            if (std.mem.eql(u8, call_name, "@import")) {
                if (params.len == 0) return null;
                const import_param = params[0];
                if (node_tags[import_param] != .string_literal) return null;

                const import_str = tree.tokenSlice(main_tokens[import_param]);
                const import_uri = (try analyser.store.uriFromImportStr(analyser.arena.allocator(), handle.*, import_str[1 .. import_str.len - 1])) orelse return null;

                const new_handle = analyser.store.getOrLoadHandle(import_uri) orelse return null;

                // reference to node '0' which is root
                return TypeWithHandle.typeVal(.{ .node = 0, .handle = new_handle });
            } else if (std.mem.eql(u8, call_name, "@cImport")) {
                const cimport_uri = (try analyser.store.resolveCImport(handle.*, node)) orelse return null;

                const new_handle = analyser.store.getOrLoadHandle(cimport_uri) orelse return null;

                // reference to node '0' which is root
                return TypeWithHandle.typeVal(.{ .node = 0, .handle = new_handle });
            }
        },
        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_decl,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            // This is a function type
            if (tree.fullFnProto(&buf, node).?.name_token == null) {
                return TypeWithHandle.typeVal(node_handle);
            }

            return TypeWithHandle{
                .type = .{ .data = .{ .other = node }, .is_type_val = false },
                .handle = handle,
            };
        },
        .multiline_string_literal,
        .string_literal,
        => return TypeWithHandle{
            .type = .{ .data = .{ .other = node }, .is_type_val = false },
            .handle = handle,
        },
        .@"if", .if_simple => {
            const if_node = ast.fullIf(tree, node).?;

            var either = std.ArrayListUnmanaged(Type.EitherEntry){};
            if (try analyser.resolveTypeOfNodeInternal(.{ .handle = handle, .node = if_node.ast.then_expr })) |t|
                try either.append(analyser.arena.allocator(), .{ .type_with_handle = t, .descriptor = tree.getNodeSource(if_node.ast.cond_expr) });
            if (try analyser.resolveTypeOfNodeInternal(.{ .handle = handle, .node = if_node.ast.else_expr })) |t|
                try either.append(analyser.arena.allocator(), .{ .type_with_handle = t, .descriptor = try std.fmt.allocPrint(analyser.arena.allocator(), "!({s})", .{tree.getNodeSource(if_node.ast.cond_expr)}) });

            return TypeWithHandle{
                .type = .{ .data = .{ .either = try either.toOwnedSlice(analyser.arena.allocator()) }, .is_type_val = false },
                .handle = handle,
            };
        },
        .@"switch",
        .switch_comma,
        => {
            const extra = tree.extraData(datas[node].rhs, Ast.Node.SubRange);
            const cases = tree.extra_data[extra.start..extra.end];

            var either = std.ArrayListUnmanaged(Type.EitherEntry){};

            for (cases) |case| {
                const switch_case = tree.fullSwitchCase(case).?;
                var descriptor = std.ArrayListUnmanaged(u8){};

                for (switch_case.ast.values, 0..) |values, index| {
                    try descriptor.appendSlice(analyser.arena.allocator(), tree.getNodeSource(values));
                    if (index != switch_case.ast.values.len - 1) try descriptor.appendSlice(analyser.arena.allocator(), ", ");
                }

                if (try analyser.resolveTypeOfNodeInternal(.{ .handle = handle, .node = switch_case.ast.target_expr })) |t|
                    try either.append(analyser.arena.allocator(), .{
                        .type_with_handle = t,
                        .descriptor = try descriptor.toOwnedSlice(analyser.arena.allocator()),
                    });
            }

            return TypeWithHandle{
                .type = .{ .data = .{ .either = try either.toOwnedSlice(analyser.arena.allocator()) }, .is_type_val = false },
                .handle = handle,
            };
        },
        else => {},
    }
    return null;
}

// TODO Reorganize this file, perhaps split into a couple as well
// TODO Make this better, nested levels of type vals
pub const Type = struct {
    pub const EitherEntry = struct {
        type_with_handle: TypeWithHandle,
        descriptor: []const u8,
    };

    data: union(enum) {
        pointer: Ast.Node.Index,
        slice: Ast.Node.Index,
        error_union: Ast.Node.Index,
        other: Ast.Node.Index,
        primitive: Ast.Node.Index,
        either: []const EitherEntry,
        array_index,
        @"comptime": struct {
            interpreter: *ComptimeInterpreter,
            value: ComptimeInterpreter.Value,
        },
    },
    /// If true, the type `type`, the attached data is the value of the type value.
    is_type_val: bool,
};

pub const TypeWithHandle = struct {
    type: Type,
    handle: *const DocumentStore.Handle,

    const Context = struct {
        // Note that we don't hash/equate descriptors to remove
        // duplicates

        fn hashType(hasher: *std.hash.Wyhash, ty: Type) void {
            hasher.update(&.{ @boolToInt(ty.is_type_val), @enumToInt(ty.data) });

            switch (ty.data) {
                .pointer,
                .slice,
                .error_union,
                .other,
                .primitive,
                => |idx| hasher.update(&std.mem.toBytes(idx)),
                .either => |entries| {
                    for (entries) |e| {
                        hasher.update(e.descriptor);
                        hasher.update(e.type_with_handle.handle.uri);
                        hashType(hasher, e.type_with_handle.type);
                    }
                },
                .array_index => {},
                .@"comptime" => {
                    // TODO
                },
            }
        }

        pub fn hash(self: @This(), item: TypeWithHandle) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);
            hashType(&hasher, item.type);
            hasher.update(item.handle.uri);
            return hasher.final();
        }

        pub fn eql(self: @This(), a: TypeWithHandle, b: TypeWithHandle) bool {
            _ = self;

            if (!std.mem.eql(u8, a.handle.uri, b.handle.uri)) return false;
            if (a.type.is_type_val != b.type.is_type_val) return false;
            if (@enumToInt(a.type.data) != @enumToInt(b.type.data)) return false;

            switch (a.type.data) {
                inline .pointer,
                .slice,
                .error_union,
                .other,
                .primitive,
                => |a_idx, name| {
                    if (a_idx != @field(b.type.data, @tagName(name))) return false;
                },
                .either => |a_entries| {
                    const b_entries = b.type.data.either;

                    if (a_entries.len != b_entries.len) return false;
                    for (a_entries, b_entries) |ae, be| {
                        if (!std.mem.eql(u8, ae.descriptor, be.descriptor)) return false;
                        if (!eql(.{}, ae.type_with_handle, be.type_with_handle)) return false;
                    }
                },
                .array_index => {},
                .@"comptime" => {
                    // TODO
                },
            }

            return true;
        }
    };

    pub fn typeVal(node_handle: NodeWithHandle) TypeWithHandle {
        return .{
            .type = .{
                .data = .{ .other = node_handle.node },
                .is_type_val = true,
            },
            .handle = node_handle.handle,
        };
    }

    pub const Deduplicator = std.HashMapUnmanaged(TypeWithHandle, void, TypeWithHandle.Context, std.hash_map.default_max_load_percentage);

    /// Resolves possible types of a type (single for all except array_index and either)
    /// Drops duplicates
    pub fn getAllTypesWithHandles(ty: TypeWithHandle, arena: std.mem.Allocator) ![]const TypeWithHandle {
        var all_types = std.ArrayListUnmanaged(TypeWithHandle){};
        try ty.getAllTypesWithHandlesArrayList(arena, &all_types);
        return try all_types.toOwnedSlice(arena);
    }

    pub fn getAllTypesWithHandlesArrayList(ty: TypeWithHandle, arena: std.mem.Allocator, all_types: *std.ArrayListUnmanaged(TypeWithHandle)) !void {
        switch (ty.type.data) {
            .either => |e| for (e) |i| try i.type_with_handle.getAllTypesWithHandlesArrayList(arena, all_types),
            else => try all_types.append(arena, ty),
        }
    }

    fn instanceTypeVal(self: TypeWithHandle) ?TypeWithHandle {
        if (!self.type.is_type_val) return null;
        return TypeWithHandle{
            .type = .{ .data = self.type.data, .is_type_val = false },
            .handle = self.handle,
        };
    }

    fn isRoot(self: TypeWithHandle) bool {
        switch (self.type.data) {
            // root is always index 0
            .other => |n| return n == 0,
            else => return false,
        }
    }

    fn isContainerKind(self: TypeWithHandle, container_kind_tok: std.zig.Token.Tag) bool {
        const tree = self.handle.tree;
        const main_tokens = tree.nodes.items(.main_token);
        const tags = tree.tokens.items(.tag);
        switch (self.type.data) {
            .other => |n| return tags[main_tokens[n]] == container_kind_tok,
            else => return false,
        }
    }

    pub fn isStructType(self: TypeWithHandle) bool {
        return self.isContainerKind(.keyword_struct) or self.isRoot();
    }

    pub fn isNamespace(self: TypeWithHandle) bool {
        if (!self.isStructType()) return false;
        const tree = self.handle.tree;
        const node = self.type.data.other;
        const tags = tree.nodes.items(.tag);
        var buf: [2]Ast.Node.Index = undefined;
        const full = tree.fullContainerDecl(&buf, node) orelse return true;
        for (full.ast.members) |member| {
            if (tags[member].isContainerField()) return false;
        }
        return true;
    }

    pub fn isEnumType(self: TypeWithHandle) bool {
        return self.isContainerKind(.keyword_enum);
    }

    pub fn isUnionType(self: TypeWithHandle) bool {
        return self.isContainerKind(.keyword_union);
    }

    pub fn isOpaqueType(self: TypeWithHandle) bool {
        return self.isContainerKind(.keyword_opaque);
    }

    pub fn isTypeFunc(self: TypeWithHandle) bool {
        var buf: [1]Ast.Node.Index = undefined;
        const tree = self.handle.tree;
        return switch (self.type.data) {
            .other => |n| if (tree.fullFnProto(&buf, n)) |fn_proto| blk: {
                break :blk isTypeFunction(tree, fn_proto);
            } else false,
            else => false,
        };
    }

    pub fn isGenericFunc(self: TypeWithHandle) bool {
        var buf: [1]Ast.Node.Index = undefined;
        const tree = self.handle.tree;
        return switch (self.type.data) {
            .other => |n| if (tree.fullFnProto(&buf, n)) |fn_proto| blk: {
                break :blk isGenericFunction(tree, fn_proto);
            } else false,
            else => false,
        };
    }

    pub fn isFunc(self: TypeWithHandle) bool {
        const tree = self.handle.tree;
        const tags = tree.nodes.items(.tag);
        return switch (self.type.data) {
            .other => |n| switch (tags[n]) {
                .fn_proto,
                .fn_proto_multi,
                .fn_proto_one,
                .fn_proto_simple,
                .fn_decl,
                => true,
                else => false,
            },
            else => false,
        };
    }
};

pub fn resolveTypeOfNode(analyser: *Analyser, node_handle: NodeWithHandle) error{OutOfMemory}!?TypeWithHandle {
    analyser.bound_type_params.clearRetainingCapacity();
    return analyser.resolveTypeOfNodeInternal(node_handle);
}

/// Collects all `@import`'s we can find into a slice of import paths (without quotes).
pub fn collectImports(allocator: std.mem.Allocator, tree: Ast) error{OutOfMemory}!std.ArrayListUnmanaged([]const u8) {
    var imports = std.ArrayListUnmanaged([]const u8){};
    errdefer imports.deinit(allocator);

    const tags = tree.tokens.items(.tag);

    var i: usize = 0;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != .builtin)
            continue;
        const text = tree.tokenSlice(@intCast(u32, i));

        if (std.mem.eql(u8, text, "@import")) {
            if (i + 3 >= tags.len)
                break;
            if (tags[i + 1] != .l_paren)
                continue;
            if (tags[i + 2] != .string_literal)
                continue;
            if (tags[i + 3] != .r_paren)
                continue;

            const str = tree.tokenSlice(@intCast(u32, i + 2));
            try imports.append(allocator, str[1 .. str.len - 1]);
        }
    }

    return imports;
}

/// Collects all `@cImport` nodes
/// Caller owns returned memory.
pub fn collectCImportNodes(allocator: std.mem.Allocator, tree: Ast) error{OutOfMemory}![]Ast.Node.Index {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var import_nodes = std.ArrayListUnmanaged(Ast.Node.Index){};
    errdefer import_nodes.deinit(allocator);

    const node_tags = tree.nodes.items(.tag);
    const main_tokens = tree.nodes.items(.main_token);

    var i: usize = 0;
    while (i < node_tags.len) : (i += 1) {
        const node = @intCast(Ast.Node.Index, i);
        if (!ast.isBuiltinCall(tree, node)) continue;

        if (!std.mem.eql(u8, Ast.tokenSlice(tree, main_tokens[node]), "@cImport")) continue;

        try import_nodes.append(allocator, node);
    }

    return import_nodes.toOwnedSlice(allocator);
}

pub const NodeWithUri = struct {
    node: Ast.Node.Index,
    uri: []const u8,

    const Context = struct {
        pub fn hash(self: @This(), item: NodeWithUri) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hasher, item.node);
            hasher.update(item.uri);
            return hasher.final();
        }

        pub fn eql(self: @This(), a: NodeWithUri, b: NodeWithUri) bool {
            _ = self;
            if (a.node != b.node) return false;
            return std.mem.eql(u8, a.uri, b.uri);
        }
    };
};

pub const NodeWithHandle = struct {
    node: Ast.Node.Index,
    handle: *const DocumentStore.Handle,
};

pub const FieldAccessReturn = struct {
    original: TypeWithHandle,
    unwrapped: ?TypeWithHandle = null,
};

pub fn getFieldAccessType(analyser: *Analyser, handle: *const DocumentStore.Handle, source_index: usize, tokenizer: *std.zig.Tokenizer) !?FieldAccessReturn {
    analyser.bound_type_params.clearRetainingCapacity();

    var current_type: ?TypeWithHandle = null;

    while (true) {
        const tok = tokenizer.next();
        switch (tok.tag) {
            .eof => return FieldAccessReturn{
                .original = current_type orelse return null,
                .unwrapped = try analyser.resolveDerefType(current_type orelse return null),
            },
            .identifier => {
                const ct_handle = if (current_type) |c| c.handle else handle;
                if (try analyser.lookupSymbolGlobal(
                    ct_handle,
                    tokenizer.buffer[tok.loc.start..tok.loc.end],
                    source_index,
                )) |child| {
                    current_type = (try child.resolveType(analyser)) orelse return null;
                } else return null;
            },
            .period => {
                const after_period = tokenizer.next();
                switch (after_period.tag) {
                    .eof => {
                        // function labels cannot be dot accessed
                        if (current_type) |ct| {
                            if (ct.isFunc()) return null;
                            return FieldAccessReturn{
                                .original = ct,
                                .unwrapped = try analyser.resolveDerefType(ct),
                            };
                        } else {
                            return null;
                        }
                    },
                    .identifier => {
                        if (after_period.loc.end == tokenizer.buffer.len) {
                            if (current_type) |ct| {
                                return FieldAccessReturn{
                                    .original = ct,
                                    .unwrapped = try analyser.resolveDerefType(ct),
                                };
                            } else {
                                return null;
                            }
                        }

                        const deref_type = if (current_type) |ty|
                            if (try analyser.resolveDerefType(ty)) |deref_ty| deref_ty else ty
                        else
                            return null;

                        const current_type_nodes = try deref_type.getAllTypesWithHandles(analyser.arena.allocator());

                        // TODO: Return all options instead of first valid one
                        // (this would require a huge rewrite and im lazy)
                        for (current_type_nodes) |ty| {
                            const current_type_node = switch (ty.type.data) {
                                .other => |n| n,
                                else => continue,
                            };

                            if (try analyser.lookupSymbolContainer(
                                .{ .node = current_type_node, .handle = ty.handle },
                                tokenizer.buffer[after_period.loc.start..after_period.loc.end],
                                !current_type.?.type.is_type_val,
                            )) |child| {
                                current_type.? = (try child.resolveType(analyser)) orelse continue;
                                break;
                            } else continue;
                        } else {
                            return null;
                        }
                    },
                    .question_mark => {
                        current_type = (try analyser.resolveUnwrapOptionalType(current_type orelse return null)) orelse return null;
                    },
                    else => {
                        log.debug("Unrecognized token {} after period.", .{after_period.tag});
                        return null;
                    },
                }
            },
            .period_asterisk => {
                current_type = (try analyser.resolveDerefType(current_type orelse return null)) orelse return null;
            },
            .l_paren => {
                if (current_type == null) {
                    return null;
                }
                const current_type_node = switch (current_type.?.type.data) {
                    .other => |n| n,
                    else => return null,
                };

                // Can't call a function type, we need a function type instance.
                if (current_type.?.type.is_type_val) return null;
                const cur_tree = current_type.?.handle.tree;
                var buf: [1]Ast.Node.Index = undefined;
                if (cur_tree.fullFnProto(&buf, current_type_node)) |func| {
                    // Check if the function has a body and if so, pass it
                    // so the type can be resolved if it's a generic function returning
                    // an anonymous struct
                    const has_body = cur_tree.nodes.items(.tag)[current_type_node] == .fn_decl;
                    const body = cur_tree.nodes.items(.data)[current_type_node].rhs;

                    // TODO Actually bind params here when calling functions instead of just skipping args.
                    if (try analyser.resolveReturnType(func, current_type.?.handle, if (has_body) body else null)) |ret| {
                        current_type = ret;
                        // Skip to the right paren
                        var paren_count: usize = 1;
                        var next = tokenizer.next();
                        while (next.tag != .eof) : (next = tokenizer.next()) {
                            if (next.tag == .r_paren) {
                                paren_count -= 1;
                                if (paren_count == 0) break;
                            } else if (next.tag == .l_paren) {
                                paren_count += 1;
                            }
                        } else return null;
                    } else return null;
                } else return null;
            },
            .l_bracket => {
                var brack_count: usize = 1;
                var next = tokenizer.next();
                var is_range = false;
                while (next.tag != .eof) : (next = tokenizer.next()) {
                    if (next.tag == .r_bracket) {
                        brack_count -= 1;
                        if (brack_count == 0) break;
                    } else if (next.tag == .l_bracket) {
                        brack_count += 1;
                    } else if (next.tag == .ellipsis2 and brack_count == 1) {
                        is_range = true;
                    }
                } else return null;

                current_type = (try analyser.resolveBracketAccessType(current_type orelse return null, if (is_range) .Range else .Single)) orelse return null;
            },
            .builtin => {
                const curr_handle = if (current_type == null) handle else current_type.?.handle;
                if (std.mem.eql(u8, tokenizer.buffer[tok.loc.start..tok.loc.end], "@import")) {
                    if (tokenizer.next().tag != .l_paren) return null;
                    var import_str_tok = tokenizer.next(); // should be the .string_literal
                    if (import_str_tok.tag != .string_literal) return null;
                    if (import_str_tok.loc.end - import_str_tok.loc.start < 2) return null;
                    var import_str = offsets.locToSlice(tokenizer.buffer, .{
                        .start = import_str_tok.loc.start + 1,
                        .end = import_str_tok.loc.end - 1,
                    });
                    const uri = try analyser.store.uriFromImportStr(analyser.arena.allocator(), curr_handle.*, import_str) orelse return null;
                    const node_handle = analyser.store.getOrLoadHandle(uri) orelse return null;
                    current_type = TypeWithHandle.typeVal(NodeWithHandle{ .handle = node_handle, .node = 0 });
                    _ = tokenizer.next(); // eat the .r_paren
                } else {
                    log.debug("Unhandled builtin: {s}", .{offsets.locToSlice(tokenizer.buffer, tok.loc)});
                    return null;
                }
            },
            else => {
                log.debug("Unimplemented token: {}", .{tok.tag});
                return null;
            },
        }
    }

    std.debug.print("current_type: {?}\n", .{current_type});
    if (current_type) |ct| {
        return FieldAccessReturn{
            .original = ct,
            .unwrapped = try analyser.resolveDerefType(ct),
        };
    } else {
        return null;
    }
}

pub fn isNodePublic(tree: Ast, node: Ast.Node.Index) bool {
    var buf: [1]Ast.Node.Index = undefined;
    return switch (tree.nodes.items(.tag)[node]) {
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => tree.fullVarDecl(node).?.visib_token != null,
        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_decl,
        => tree.fullFnProto(&buf, node).?.visib_token != null,
        else => true,
    };
}

pub fn nodeToString(tree: Ast, node: Ast.Node.Index) ?[]const u8 {
    const data = tree.nodes.items(.data);
    const main_token = tree.nodes.items(.main_token)[node];
    var buf: [1]Ast.Node.Index = undefined;
    return switch (tree.nodes.items(.tag)[node]) {
        .container_field,
        .container_field_init,
        .container_field_align,
        => {
            const field = tree.fullContainerField(node).?.ast;
            return if (field.tuple_like) null else tree.tokenSlice(field.main_token);
        },
        .error_value => tree.tokenSlice(data[node].rhs),
        .identifier => tree.tokenSlice(main_token),
        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_decl,
        => if (tree.fullFnProto(&buf, node).?.name_token) |name| tree.tokenSlice(name) else null,
        .field_access => tree.tokenSlice(data[node].rhs),
        .call,
        .call_comma,
        .async_call,
        .async_call_comma,
        => tree.tokenSlice(tree.callFull(node).ast.lparen - 1),
        .call_one,
        .call_one_comma,
        .async_call_one,
        .async_call_one_comma,
        => tree.tokenSlice(tree.callOne(&buf, node).ast.lparen - 1),
        .test_decl => if (data[node].lhs != 0) tree.tokenSlice(data[node].lhs) else null,
        else => |tag| {
            log.debug("INVALID: {}", .{tag});
            return null;
        },
    };
}

pub const PositionContext = union(enum) {
    builtin: offsets.Loc,
    comment,
    import_string_literal: offsets.Loc,
    cinclude_string_literal: offsets.Loc,
    embedfile_string_literal: offsets.Loc,
    string_literal: offsets.Loc,
    field_access: offsets.Loc,
    var_access: offsets.Loc,
    global_error_set,
    enum_literal,
    pre_label,
    label: bool,
    other,
    empty,

    pub fn loc(self: PositionContext) ?offsets.Loc {
        return switch (self) {
            .builtin => |r| r,
            .comment => null,
            .import_string_literal => |r| r,
            .cinclude_string_literal => |r| r,
            .embedfile_string_literal => |r| r,
            .string_literal => |r| r,
            .field_access => |r| r,
            .var_access => |r| r,
            .enum_literal => null,
            .pre_label => null,
            .label => null,
            .other => null,
            .empty => null,
            .global_error_set => null,
        };
    }
};

const StackState = struct {
    ctx: PositionContext,
    stack_id: enum { Paren, Bracket, Global },
};

fn peek(allocator: std.mem.Allocator, arr: *std.ArrayListUnmanaged(StackState)) !*StackState {
    if (arr.items.len == 0) {
        try arr.append(allocator, .{ .ctx = .empty, .stack_id = .Global });
    }
    return &arr.items[arr.items.len - 1];
}

fn tokenLocAppend(prev: offsets.Loc, token: std.zig.Token) offsets.Loc {
    return .{
        .start = prev.start,
        .end = token.loc.end,
    };
}

pub fn isSymbolChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_';
}

/// Given a byte index in a document (typically cursor offset), classify what kind of entity is at that index.
///
/// Classification is based on the lexical structure -- we fetch the line containing index, tokenize it,
/// and look at the sequence of tokens just before the cursor. Due to the nice way zig is designed (only line
/// comments, etc) lexing just a single line is always correct.
pub fn getPositionContext(
    allocator: std.mem.Allocator,
    text: []const u8,
    doc_index: usize,
    /// Should we look to the end of the current context? Yes for goto def, no for completions
    lookahead: bool,
) !PositionContext {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var new_index = doc_index;
    if (lookahead and new_index < text.len and isSymbolChar(text[new_index])) {
        new_index += 1;
    } else if (lookahead and new_index + 1 < text.len and text[new_index] == '@') {
        new_index += 2;
    }

    const line_loc = if (!lookahead) offsets.lineLocAtIndex(text, new_index) else offsets.lineLocUntilIndex(text, new_index);
    const line = offsets.locToSlice(text, line_loc);
    const prev_char = if (new_index > 0) text[new_index - 1] else 0;

    const is_comment = std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), "//");
    if (is_comment) return .comment;

    var stack = try std.ArrayListUnmanaged(StackState).initCapacity(allocator, 8);
    defer stack.deinit(allocator);

    {
        var held_line = try allocator.dupeZ(u8, text[0..line_loc.end]);
        defer allocator.free(held_line);

        var tokenizer: std.zig.Tokenizer = .{
            .buffer = held_line,
            .index = line_loc.start,
            .pending_invalid_token = null,
        };

        while (true) {
            var tok = tokenizer.next();
            // Early exits.
            if (tok.loc.start > new_index) break;
            if (tok.loc.start == new_index) {
                // Tie-breaking, the cursor is exactly between two tokens, and
                // `tok` is the latter of the two.
                if (tok.tag != .identifier) break;
            }
            switch (tok.tag) {
                .invalid => {
                    // Single '@' do not return a builtin token so we check this on our own.
                    if (prev_char == '@') {
                        return PositionContext{
                            .builtin = .{
                                .start = line_loc.end - 1,
                                .end = line_loc.end,
                            },
                        };
                    }
                    const s = held_line[tok.loc.start..tok.loc.end];
                    const q = std.mem.indexOf(u8, s, "\"") orelse return .other;
                    if (s[q -| 1] == '@') {
                        tok.tag = .identifier;
                    } else {
                        tok.tag = .string_literal;
                    }
                },
                .doc_comment, .container_doc_comment => return .comment,
                .eof => break,
                else => {},
            }

            // State changes
            var curr_ctx = try peek(allocator, &stack);
            switch (tok.tag) {
                .string_literal, .multiline_string_literal_line => string_lit_block: {
                    if (curr_ctx.stack_id == .Paren and stack.items.len >= 2) {
                        const perhaps_builtin = stack.items[stack.items.len - 2];

                        switch (perhaps_builtin.ctx) {
                            .builtin => |loc| {
                                const builtin_name = tokenizer.buffer[loc.start..loc.end];
                                if (std.mem.eql(u8, builtin_name, "@import")) {
                                    curr_ctx.ctx = .{ .import_string_literal = tok.loc };
                                    break :string_lit_block;
                                } else if (std.mem.eql(u8, builtin_name, "@cInclude")) {
                                    curr_ctx.ctx = .{ .cinclude_string_literal = tok.loc };
                                    break :string_lit_block;
                                } else if (std.mem.eql(u8, builtin_name, "@embedFile")) {
                                    curr_ctx.ctx = .{ .embedfile_string_literal = tok.loc };
                                    break :string_lit_block;
                                }
                            },
                            else => {},
                        }
                    }
                    curr_ctx.ctx = .{ .string_literal = tok.loc };
                },
                .identifier => switch (curr_ctx.ctx) {
                    .empty, .pre_label => curr_ctx.ctx = .{ .var_access = tok.loc },
                    .label => |filled| if (!filled) {
                        curr_ctx.ctx = .{ .label = true };
                    } else {
                        curr_ctx.ctx = .{ .var_access = tok.loc };
                    },
                    else => {},
                },
                .builtin => switch (curr_ctx.ctx) {
                    .empty, .pre_label => curr_ctx.ctx = .{ .builtin = tok.loc },
                    else => {},
                },
                .period, .period_asterisk => switch (curr_ctx.ctx) {
                    .empty, .pre_label => curr_ctx.ctx = .enum_literal,
                    .enum_literal => curr_ctx.ctx = .empty,
                    .field_access => {},
                    .other => {},
                    .global_error_set => {},
                    .label => {},
                    else => curr_ctx.ctx = .{
                        .field_access = tokenLocAppend(curr_ctx.ctx.loc().?, tok),
                    },
                },
                .keyword_break, .keyword_continue => curr_ctx.ctx = .pre_label,
                .colon => if (curr_ctx.ctx == .pre_label) {
                    curr_ctx.ctx = .{ .label = false };
                } else {
                    curr_ctx.ctx = .empty;
                },
                .question_mark => switch (curr_ctx.ctx) {
                    .field_access => {},
                    else => curr_ctx.ctx = .empty,
                },
                .l_paren => try stack.append(allocator, .{ .ctx = .empty, .stack_id = .Paren }),
                .l_bracket => try stack.append(allocator, .{ .ctx = .empty, .stack_id = .Bracket }),
                .r_paren => {
                    _ = stack.pop();
                    if (curr_ctx.stack_id != .Paren) {
                        (try peek(allocator, &stack)).ctx = .empty;
                    }
                },
                .r_bracket => {
                    _ = stack.pop();
                    if (curr_ctx.stack_id != .Bracket) {
                        (try peek(allocator, &stack)).ctx = .empty;
                    }
                },
                .keyword_error => curr_ctx.ctx = .global_error_set,
                else => curr_ctx.ctx = .empty,
            }

            switch (curr_ctx.ctx) {
                .field_access => |r| curr_ctx.ctx = .{
                    .field_access = tokenLocAppend(r, tok),
                },
                else => {},
            }
        }
    }

    if (stack.popOrNull()) |state| {
        switch (state.ctx) {
            .empty => {},
            .label => |filled| {
                // We need to check this because the state could be a filled
                // label if only a space follows it
                if (!filled or prev_char != ' ') {
                    return state.ctx;
                }
            },
            else => return state.ctx,
        }
    }

    if (line.len == 0) return .empty;

    var held_line = try allocator.dupeZ(u8, offsets.locToSlice(text, line_loc));
    defer allocator.free(held_line);

    switch (line[0]) {
        'a'...'z', 'A'...'Z', '_', '@' => {},
        else => return .empty,
    }
    var tokenizer = std.zig.Tokenizer.init(held_line);
    const tok = tokenizer.next();

    return if (tok.tag == .identifier) PositionContext{ .var_access = tok.loc } else .empty;
}

pub const Declaration = union(enum) {
    /// Index of the ast node
    ast_node: Ast.Node.Index,
    /// Function parameter
    param_payload: struct {
        param: Ast.full.FnProto.Param,
        param_idx: u16,
        func: Ast.Node.Index,
    },
    pointer_payload: struct {
        name: Ast.TokenIndex,
        condition: Ast.Node.Index,
    },
    array_payload: struct {
        identifier: Ast.TokenIndex,
        array_expr: Ast.Node.Index,
    },
    array_index: Ast.TokenIndex,
    switch_payload: struct {
        node: Ast.TokenIndex,
        switch_expr: Ast.Node.Index,
        items: []const Ast.Node.Index,
    },
    label_decl: struct {
        label: Ast.TokenIndex,
        block: Ast.Node.Index,
    },
    /// always an identifier
    error_token: Ast.Node.Index,

    pub const Index = enum(u32) { _ };

    pub fn eql(a: Declaration, b: Declaration) bool {
        return std.meta.eql(a, b);
    }
};

pub const DeclWithHandle = struct {
    decl: *Declaration,
    handle: *const DocumentStore.Handle,

    pub fn eql(a: DeclWithHandle, b: DeclWithHandle) bool {
        return a.decl.eql(b.decl.*) and std.mem.eql(u8, a.handle.uri, b.handle.uri);
    }

    pub fn nameToken(self: DeclWithHandle) Ast.TokenIndex {
        const tree = self.handle.tree;
        return switch (self.decl.*) {
            .ast_node => |n| getDeclNameToken(tree, n).?,
            .param_payload => |pp| pp.param.name_token.?,
            .pointer_payload => |pp| pp.name,
            .array_payload => |ap| ap.identifier,
            .array_index => |ai| ai,
            .switch_payload => |sp| sp.node,
            .label_decl => |ld| ld.label,
            .error_token => |et| et,
        };
    }

    fn isPublic(self: DeclWithHandle) bool {
        return switch (self.decl.*) {
            .ast_node => |node| isNodePublic(self.handle.tree, node),
            else => true,
        };
    }

    pub fn resolveType(self: DeclWithHandle, analyser: *Analyser) !?TypeWithHandle {
        const tree = self.handle.tree;
        const node_tags = tree.nodes.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);
        return switch (self.decl.*) {
            .ast_node => |node| try analyser.resolveTypeOfNodeInternal(
                .{ .node = node, .handle = self.handle },
            ),
            .param_payload => |pay| {
                // handle anytype
                if (pay.param.type_expr == 0) {
                    var func_decl = Declaration{ .ast_node = pay.func };

                    var func_buf: [1]Ast.Node.Index = undefined;
                    const func = tree.fullFnProto(&func_buf, pay.func).?;

                    var func_params_len: usize = 0;

                    var it = func.iterate(&tree);
                    while (ast.nextFnParam(&it)) |_| {
                        func_params_len += 1;
                    }

                    var refs = try references.callsiteReferences(analyser.arena.allocator(), analyser, .{
                        .decl = &func_decl,
                        .handle = self.handle,
                    }, false, false, false);

                    // TODO: Set `workspace` to true; current problems
                    // - we gather dependencies, not dependents
                    // - stack overflow due to cyclically anytype resolution(?)

                    var possible = std.ArrayListUnmanaged(Type.EitherEntry){};
                    var deduplicator = TypeWithHandle.Deduplicator{};
                    defer deduplicator.deinit(analyser.gpa);

                    for (refs.items) |ref| {
                        var handle = analyser.store.getOrLoadHandle(ref.uri).?;

                        var call_buf: [1]Ast.Node.Index = undefined;
                        var call = handle.tree.fullCall(&call_buf, ref.call_node).?;

                        const real_param_idx = if (func_params_len != 0 and pay.param_idx != 0 and call.ast.params.len == func_params_len - 1)
                            pay.param_idx - 1
                        else
                            pay.param_idx;

                        if (real_param_idx >= call.ast.params.len) continue;

                        if (try analyser.resolveTypeOfNode(.{
                            // TODO?: this is a """heuristic based approach"""
                            // perhaps it would be better to use proper self detection
                            // maybe it'd be a perf issue and this is fine?
                            // you figure it out future contributor <3
                            .node = call.ast.params[real_param_idx],
                            .handle = handle,
                        })) |ty| {
                            var gop = try deduplicator.getOrPut(analyser.gpa, ty);
                            if (gop.found_existing) continue;

                            var loc = offsets.tokenToPosition(handle.tree, main_tokens[call.ast.params[real_param_idx]], .@"utf-8");
                            try possible.append(analyser.arena.allocator(), .{ // TODO: Dedup
                                .type_with_handle = ty,
                                .descriptor = try std.fmt.allocPrint(analyser.arena.allocator(), "{s}:{d}:{d}", .{ handle.uri, loc.line + 1, loc.character + 1 }),
                            });
                        }
                    }

                    return TypeWithHandle{
                        .type = .{ .data = .{ .either = try possible.toOwnedSlice(analyser.arena.allocator()) }, .is_type_val = false },
                        .handle = self.handle,
                    };
                }

                const param_decl = pay.param;
                if (isMetaType(self.handle.tree, param_decl.type_expr)) {
                    var bound_param_it = analyser.bound_type_params.iterator();
                    while (bound_param_it.next()) |entry| {
                        if (std.meta.eql(entry.key_ptr.*, param_decl)) return entry.value_ptr.*;
                    }
                    return null;
                } else if (node_tags[param_decl.type_expr] == .identifier) {
                    if (param_decl.name_token) |name_tok| {
                        if (std.mem.eql(u8, tree.tokenSlice(main_tokens[param_decl.type_expr]), tree.tokenSlice(name_tok)))
                            return null;
                    }
                }
                return ((try analyser.resolveTypeOfNodeInternal(
                    .{ .node = param_decl.type_expr, .handle = self.handle },
                )) orelse return null).instanceTypeVal();
            },
            .pointer_payload => |pay| try analyser.resolveUnwrapOptionalType(
                (try analyser.resolveTypeOfNodeInternal(.{
                    .node = pay.condition,
                    .handle = self.handle,
                })) orelse return null,
            ),
            .array_payload => |pay| try analyser.resolveBracketAccessType(
                (try analyser.resolveTypeOfNodeInternal(.{
                    .node = pay.array_expr,
                    .handle = self.handle,
                })) orelse return null,
                .Single,
            ),
            .array_index => TypeWithHandle{
                .type = .{ .data = .array_index, .is_type_val = false },
                .handle = self.handle,
            },
            .label_decl => return null,
            .switch_payload => |pay| {
                if (pay.items.len == 0) return null;
                // TODO Peer type resolution, we just use the first item for now.
                const switch_expr_type = (try analyser.resolveTypeOfNodeInternal(.{
                    .node = pay.switch_expr,
                    .handle = self.handle,
                })) orelse return null;
                if (!switch_expr_type.isUnionType())
                    return null;

                if (node_tags[pay.items[0]] != .enum_literal) return null;

                const scope_index = findContainerScopeIndex(.{ .node = switch_expr_type.type.data.other, .handle = switch_expr_type.handle }) orelse return null;
                const scope_decls = switch_expr_type.handle.document_scope.scopes.items(.decls);

                const name = tree.tokenSlice(main_tokens[pay.items[0]]);
                const decl_index = scope_decls[scope_index].get(name) orelse return null;
                const decl = switch_expr_type.handle.document_scope.decls.items[@enumToInt(decl_index)];

                switch (decl) {
                    .ast_node => |node| {
                        if (switch_expr_type.handle.tree.fullContainerField(node)) |container_field| {
                            if (container_field.ast.type_expr != 0) {
                                return ((try analyser.resolveTypeOfNodeInternal(
                                    .{ .node = container_field.ast.type_expr, .handle = switch_expr_type.handle },
                                )) orelse return null).instanceTypeVal();
                            }
                        }
                    },
                    else => {},
                }
                return null;
            },
            .error_token => return null,
        };
    }
};

fn findContainerScopeIndex(container_handle: NodeWithHandle) ?usize {
    const container = container_handle.node;
    const handle = container_handle.handle;

    if (!ast.isContainer(handle.tree, container)) return null;

    return for (handle.document_scope.scopes.items(.data), 0..) |data, scope_index| {
        switch (data) {
            .container => |node| if (node == container) {
                break scope_index;
            },
            else => {},
        }
    } else null;
}

fn iterateSymbolsContainerInternal(
    analyser: *Analyser,
    container_handle: NodeWithHandle,
    orig_handle: *const DocumentStore.Handle,
    comptime callback: anytype,
    context: anytype,
    instance_access: bool,
) error{OutOfMemory}!void {
    const container = container_handle.node;
    const handle = container_handle.handle;

    const tree = handle.tree;
    const node_tags = tree.nodes.items(.tag);
    const token_tags = tree.tokens.items(.tag);
    const main_token = tree.nodes.items(.main_token)[container];

    const is_enum = token_tags[main_token] == .keyword_enum;

    const scope_decls = handle.document_scope.scopes.items(.decls);
    const scope_uses = handle.document_scope.scopes.items(.uses);
    const container_scope_index = findContainerScopeIndex(container_handle) orelse return;

    for (scope_decls[container_scope_index].values()) |decl_index| {
        const decl = &handle.document_scope.decls.items[@enumToInt(decl_index)];
        switch (decl.*) {
            .ast_node => |node| {
                if (node_tags[node].isContainerField()) {
                    if (!instance_access and !is_enum) continue;
                    if (instance_access and is_enum) continue;
                } else if (node_tags[node] == .global_var_decl or
                    node_tags[node] == .local_var_decl or
                    node_tags[node] == .simple_var_decl or
                    node_tags[node] == .aligned_var_decl)
                {
                    if (instance_access) continue;
                }
            },
            .label_decl => continue,
            else => {},
        }

        const decl_with_handle = DeclWithHandle{ .decl = decl, .handle = handle };
        if (handle != orig_handle and !decl_with_handle.isPublic()) continue;
        try callback(context, decl_with_handle);
    }

    for (scope_uses[container_scope_index]) |use| {
        const use_token = tree.nodes.items(.main_token)[use];
        const is_pub = use_token > 0 and token_tags[use_token - 1] == .keyword_pub;
        if (handle != orig_handle and !is_pub) continue;

        const gop = try analyser.using_trail.getOrPut(analyser.gpa, use);
        if (gop.found_existing) continue;

        const lhs = tree.nodes.items(.data)[use].lhs;
        const use_expr = (try analyser.resolveTypeOfNode(.{
            .node = lhs,
            .handle = handle,
        })) orelse continue;

        const use_expr_node = switch (use_expr.type.data) {
            .other => |n| n,
            else => continue,
        };
        try analyser.iterateSymbolsContainerInternal(
            .{ .node = use_expr_node, .handle = use_expr.handle },
            orig_handle,
            callback,
            context,
            false,
        );
    }
}

pub const EnclosingScopeIterator = struct {
    scope_locs: []offsets.Loc,
    scope_children: []const std.ArrayListUnmanaged(Scope.Index),
    current_scope: Scope.Index,
    source_index: usize,

    pub fn next(self: *EnclosingScopeIterator) ?Scope.Index {
        if (self.current_scope == .none) return null;

        const child_scopes = self.scope_children[@enumToInt(self.current_scope)];
        defer self.current_scope = for (child_scopes.items) |child_scope| {
            const child_loc = self.scope_locs[@enumToInt(child_scope)];
            if (child_loc.start <= self.source_index and self.source_index <= child_loc.end) {
                break child_scope;
            }
        } else .none;

        return self.current_scope;
    }
};

fn iterateEnclosingScopes(document_scope: DocumentScope, source_index: usize) EnclosingScopeIterator {
    return .{
        .scope_locs = document_scope.scopes.items(.loc),
        .scope_children = document_scope.scopes.items(.child_scopes),
        .current_scope = @intToEnum(Scope.Index, 0),
        .source_index = source_index,
    };
}

pub fn iterateSymbolsContainer(
    analyser: *Analyser,
    container_handle: NodeWithHandle,
    orig_handle: *const DocumentStore.Handle,
    comptime callback: anytype,
    context: anytype,
    instance_access: bool,
) error{OutOfMemory}!void {
    analyser.using_trail.clearRetainingCapacity();
    return try analyser.iterateSymbolsContainerInternal(container_handle, orig_handle, callback, context, instance_access);
}

pub fn iterateLabels(handle: *const DocumentStore.Handle, source_index: usize, comptime callback: anytype, context: anytype) error{OutOfMemory}!void {
    const scope_decls = handle.document_scope.scopes.items(.decls);

    var scope_iterator = iterateEnclosingScopes(handle.document_scope, source_index);
    while (scope_iterator.next()) |scope_index| {
        for (scope_decls[@enumToInt(scope_index)].values()) |decl_index| {
            const decl = &handle.document_scope.decls.items[@enumToInt(decl_index)];
            if (decl.* != .label_decl) continue;
            try callback(context, DeclWithHandle{ .decl = decl, .handle = handle });
        }
    }
}

fn iterateSymbolsGlobalInternal(
    analyser: *Analyser,
    handle: *const DocumentStore.Handle,
    source_index: usize,
    comptime callback: anytype,
    context: anytype,
) error{OutOfMemory}!void {
    const scope_decls = handle.document_scope.scopes.items(.decls);
    const scope_uses = handle.document_scope.scopes.items(.uses);

    var scope_iterator = iterateEnclosingScopes(handle.document_scope, source_index);
    while (scope_iterator.next()) |scope_index| {
        for (scope_decls[@enumToInt(scope_index)].values()) |decl_index| {
            const decl = &handle.document_scope.decls.items[@enumToInt(decl_index)];
            if (decl.* == .ast_node and handle.tree.nodes.items(.tag)[decl.ast_node].isContainerField()) continue;
            if (decl.* == .label_decl) continue;
            try callback(context, DeclWithHandle{ .decl = decl, .handle = handle });
        }

        for (scope_uses[@enumToInt(scope_index)]) |use| {
            const gop = try analyser.using_trail.getOrPut(analyser.gpa, use);
            if (gop.found_existing) continue;

            const use_expr = (try analyser.resolveTypeOfNodeInternal(
                .{ .node = handle.tree.nodes.items(.data)[use].lhs, .handle = handle },
            )) orelse continue;
            const use_expr_node = switch (use_expr.type.data) {
                .other => |n| n,
                else => continue,
            };
            try analyser.iterateSymbolsContainerInternal(
                .{ .node = use_expr_node, .handle = use_expr.handle },
                handle,
                callback,
                context,
                false,
            );
        }
    }
}

pub fn iterateSymbolsGlobal(
    analyser: *Analyser,
    handle: *const DocumentStore.Handle,
    source_index: usize,
    comptime callback: anytype,
    context: anytype,
) error{OutOfMemory}!void {
    analyser.using_trail.clearRetainingCapacity();
    return try analyser.iterateSymbolsGlobalInternal(handle, source_index, callback, context);
}

pub fn innermostBlockScopeIndex(handle: DocumentStore.Handle, source_index: usize) Scope.Index {
    var scope_iterator = iterateEnclosingScopes(handle.document_scope, source_index);
    var scope_index: Scope.Index = .none;
    while (scope_iterator.next()) |inner_scope| {
        scope_index = inner_scope;
    }
    return scope_index;
}

pub fn innermostBlockScope(handle: DocumentStore.Handle, source_index: usize) Ast.Node.Index {
    const scope_datas = handle.document_scope.scopes.items(.data);
    const scope_parents = handle.document_scope.scopes.items(.parent);

    var scope_index = innermostBlockScopeIndex(handle, source_index);
    while (true) {
        defer scope_index = scope_parents[@enumToInt(scope_index)];
        switch (scope_datas[@enumToInt(scope_index)]) {
            .container, .function, .block => return scope_datas[@enumToInt(scope_index)].toNodeIndex().?,
            else => {},
        }
    }
}

pub fn innermostContainer(handle: *const DocumentStore.Handle, source_index: usize) TypeWithHandle {
    const scope_datas = handle.document_scope.scopes.items(.data);

    var current = scope_datas[0].container;
    if (handle.document_scope.scopes.len == 1) return TypeWithHandle.typeVal(.{ .node = current, .handle = handle });

    var scope_iterator = iterateEnclosingScopes(handle.document_scope, source_index);
    while (scope_iterator.next()) |scope_index| {
        switch (scope_datas[@enumToInt(scope_index)]) {
            .container => |node| current = node,
            else => {},
        }
    }
    return TypeWithHandle.typeVal(.{ .node = current, .handle = handle });
}

fn resolveUse(analyser: *Analyser, uses: []const Ast.Node.Index, symbol: []const u8, handle: *const DocumentStore.Handle) error{OutOfMemory}!?DeclWithHandle {
    analyser.using_trail.clearRetainingCapacity();
    for (uses) |index| {
        const gop = try analyser.using_trail.getOrPut(analyser.gpa, index);
        if (gop.found_existing) continue;

        if (handle.tree.nodes.items(.data).len <= index) continue;

        const expr = .{ .node = handle.tree.nodes.items(.data)[index].lhs, .handle = handle };
        const expr_type_node = (try analyser.resolveTypeOfNode(expr)) orelse
            continue;

        const expr_type = .{
            .node = switch (expr_type_node.type.data) {
                .other => |n| n,
                else => continue,
            },
            .handle = expr_type_node.handle,
        };

        if (try analyser.lookupSymbolContainer(expr_type, symbol, false)) |candidate| {
            if (candidate.handle == handle or candidate.isPublic()) {
                return candidate;
            }
        }
    }
    return null;
}

pub fn lookupLabel(
    handle: *const DocumentStore.Handle,
    symbol: []const u8,
    source_index: usize,
) error{OutOfMemory}!?DeclWithHandle {
    const scope_decls = handle.document_scope.scopes.items(.decls);

    var scope_iterator = iterateEnclosingScopes(handle.document_scope, source_index);
    while (scope_iterator.next()) |scope_index| {
        const decl_index = scope_decls[@enumToInt(scope_index)].get(symbol) orelse continue;
        const decl = &handle.document_scope.decls.items[@enumToInt(decl_index)];

        if (decl.* != .label_decl) continue;

        return DeclWithHandle{ .decl = decl, .handle = handle };
    }
    return null;
}

pub fn lookupSymbolGlobal(analyser: *Analyser, handle: *const DocumentStore.Handle, symbol: []const u8, source_index: usize) error{OutOfMemory}!?DeclWithHandle {
    const scope_parents = handle.document_scope.scopes.items(.parent);
    const scope_decls = handle.document_scope.scopes.items(.decls);
    const scope_uses = handle.document_scope.scopes.items(.uses);

    var current_scope = innermostBlockScopeIndex(handle.*, source_index);

    while (current_scope != .none) {
        const scope_index = @enumToInt(current_scope);
        defer current_scope = scope_parents[scope_index];
        if (scope_decls[scope_index].get(symbol)) |decl_index| {
            const candidate = &handle.document_scope.decls.items[@enumToInt(decl_index)];
            switch (candidate.*) {
                .ast_node => |node| {
                    if (handle.tree.nodes.items(.tag)[node].isContainerField()) continue;
                },
                .label_decl => continue,
                else => {},
            }
            return DeclWithHandle{ .decl = candidate, .handle = handle };
        }
        if (try analyser.resolveUse(scope_uses[scope_index], symbol, handle)) |result| return result;
    }

    return null;
}

pub fn lookupSymbolContainer(
    analyser: *Analyser,
    container_handle: NodeWithHandle,
    symbol: []const u8,
    /// If true, we are looking up the symbol like we are accessing through a field access
    /// of an instance of the type, otherwise as a field access of the type value itself.
    instance_access: bool,
) error{OutOfMemory}!?DeclWithHandle {
    const container = container_handle.node;
    const handle = container_handle.handle;
    const tree = handle.tree;
    const node_tags = tree.nodes.items(.tag);
    const token_tags = tree.tokens.items(.tag);
    const main_token = tree.nodes.items(.main_token)[container];

    const is_enum = token_tags[main_token] == .keyword_enum;
    const scope_decls = handle.document_scope.scopes.items(.decls);
    const scope_uses = handle.document_scope.scopes.items(.uses);

    if (findContainerScopeIndex(container_handle)) |container_scope_index| {
        if (scope_decls[container_scope_index].get(symbol)) |decl_index| {
            const decl = &handle.document_scope.decls.items[@enumToInt(decl_index)];
            switch (decl.*) {
                .ast_node => |node| {
                    if (node_tags[node].isContainerField()) {
                        if (!instance_access and !is_enum) return null;
                        if (instance_access and is_enum) return null;
                    }
                },
                .label_decl => unreachable,
                else => {},
            }
            return DeclWithHandle{ .decl = decl, .handle = handle };
        }

        if (try analyser.resolveUse(scope_uses[container_scope_index], symbol, handle)) |result| return result;
    }

    return null;
}

const CompletionContext = struct {
    pub fn hash(self: @This(), item: types.CompletionItem) u32 {
        _ = self;
        return @truncate(u32, std.hash.Wyhash.hash(0, item.label));
    }

    pub fn eql(self: @This(), a: types.CompletionItem, b: types.CompletionItem, b_index: usize) bool {
        _ = self;
        _ = b_index;
        return std.mem.eql(u8, a.label, b.label);
    }
};

pub const CompletionSet = std.ArrayHashMapUnmanaged(
    types.CompletionItem,
    void,
    CompletionContext,
    false,
);
comptime {
    std.debug.assert(@sizeOf(types.CompletionItem) == @sizeOf(CompletionSet.Data));
}

pub const DocumentScope = struct {
    scopes: std.MultiArrayList(Scope) = .{},
    decls: std.ArrayListUnmanaged(Declaration) = .{},
    error_completions: CompletionSet = .{},
    enum_completions: CompletionSet = .{},

    pub fn deinit(self: *DocumentScope, allocator: std.mem.Allocator) void {
        for (
            self.scopes.items(.decls),
            self.scopes.items(.child_scopes),
            self.scopes.items(.tests),
            self.scopes.items(.uses),
        ) |*decls, *child_scopes, tests, uses| {
            decls.deinit(allocator);
            child_scopes.deinit(allocator);
            allocator.free(tests);
            allocator.free(uses);
        }
        self.scopes.deinit(allocator);
        self.decls.deinit(allocator);

        for (self.error_completions.keys()) |item| {
            if (item.detail) |detail| allocator.free(detail);
            switch (item.documentation orelse continue) {
                .string => |str| allocator.free(str),
                .MarkupContent => |content| allocator.free(content.value),
            }
        }
        self.error_completions.deinit(allocator);
        for (self.enum_completions.keys()) |item| {
            if (item.detail) |detail| allocator.free(detail);
            switch (item.documentation orelse continue) {
                .string => |str| allocator.free(str),
                .MarkupContent => |content| allocator.free(content.value),
            }
        }
        self.enum_completions.deinit(allocator);
    }
};

pub const Scope = struct {
    pub const Data = union(enum) {
        container: Ast.Node.Index, // .tag is ContainerDecl or Root or ErrorSetDecl
        function: Ast.Node.Index, // .tag is FnProto
        block: Ast.Node.Index, // .tag is Block
        other,

        pub fn toNodeIndex(self: Data) ?Ast.Node.Index {
            return switch (self) {
                .container, .function, .block => |idx| idx,
                else => null,
            };
        }
    };

    pub const Index = enum(u32) {
        none = std.math.maxInt(u32),
        _,
    };

    loc: offsets.Loc,
    parent: Index,
    data: Data,
    decls: std.StringArrayHashMapUnmanaged(Declaration.Index) = .{},
    child_scopes: std.ArrayListUnmanaged(Scope.Index) = .{},
    tests: []const Ast.Node.Index = &.{},
    uses: []const Ast.Node.Index = &.{},
};

pub fn makeDocumentScope(allocator: std.mem.Allocator, tree: Ast) !DocumentScope {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var document_scope = DocumentScope{};
    errdefer document_scope.deinit(allocator);

    var current_scope: Scope.Index = .none;

    try makeInnerScope(.{
        .allocator = allocator,
        .doc_scope = &document_scope,
        .current_scope = &current_scope,
    }, tree, 0);

    return document_scope;
}

const ScopeContext = struct {
    allocator: std.mem.Allocator,
    doc_scope: *DocumentScope,
    current_scope: *Scope.Index,

    fn pushScope(context: ScopeContext, loc: offsets.Loc, data: Scope.Data) error{OutOfMemory}!Scope.Index {
        try context.doc_scope.scopes.append(context.allocator, .{
            .parent = context.current_scope.*,
            .loc = loc,
            .data = data,
        });
        const new_scope = @intToEnum(Scope.Index, context.doc_scope.scopes.len - 1);
        if (context.current_scope.* != .none) {
            try context.doc_scope.scopes.items(.child_scopes)[@enumToInt(context.current_scope.*)].append(context.allocator, new_scope);
        }
        context.current_scope.* = new_scope;
        return new_scope;
    }

    fn popScope(context: ScopeContext) void {
        const parent_scope = context.doc_scope.scopes.items(.parent)[@enumToInt(context.current_scope.*)];
        context.current_scope.* = parent_scope;
    }

    fn putDecl(context: ScopeContext, scope: Scope.Index, name: []const u8, decl: Declaration) error{OutOfMemory}!void {
        std.debug.assert(scope != .none);

        try context.doc_scope.decls.append(context.allocator, decl);
        errdefer _ = context.doc_scope.decls.pop();

        const decl_index = @intToEnum(Declaration.Index, context.doc_scope.decls.items.len - 1);

        try context.doc_scope.scopes.items(.decls)[@enumToInt(scope)].put(context.allocator, name, decl_index);
    }
};

fn makeInnerScope(context: ScopeContext, tree: Ast, node_idx: Ast.Node.Index) error{OutOfMemory}!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const allocator = context.allocator;
    const scopes = &context.doc_scope.scopes;
    const tags = tree.nodes.items(.tag);
    const token_tags = tree.tokens.items(.tag);

    const scope_index = try context.pushScope(
        offsets.nodeToLoc(tree, node_idx),
        .{ .container = node_idx },
    );
    defer context.popScope();

    var buf: [2]Ast.Node.Index = undefined;
    const container_decl = tree.fullContainerDecl(&buf, node_idx).?;

    var tests = std.ArrayListUnmanaged(Ast.Node.Index){};
    errdefer tests.deinit(allocator);
    var uses = std.ArrayListUnmanaged(Ast.Node.Index){};
    errdefer uses.deinit(allocator);

    for (container_decl.ast.members) |decl| {
        try makeScopeInternal(context, tree, decl);

        switch (tags[decl]) {
            .@"usingnamespace" => {
                try uses.append(allocator, decl);
                continue;
            },
            .test_decl => {
                try tests.append(allocator, decl);
                continue;
            },
            else => {},
        }

        const name = getDeclName(tree, decl) orelse continue;

        try context.putDecl(scope_index, name, .{ .ast_node = decl });

        if ((node_idx != 0 and token_tags[container_decl.ast.main_token] == .keyword_enum) or
            container_decl.ast.enum_token != null)
        {
            if (std.mem.eql(u8, name, "_")) return;

            const doc = try getDocComments(allocator, tree, decl, .markdown);
            errdefer if (doc) |d| allocator.free(d);
            var gop_res = try context.doc_scope.enum_completions.getOrPut(allocator, .{
                .label = name,
                .kind = .EnumMember,
                .insertText = name,
                .insertTextFormat = .PlainText,
                .documentation = if (doc) |d| .{ .MarkupContent = types.MarkupContent{ .kind = .markdown, .value = d } } else null,
            });
            if (gop_res.found_existing) {
                if (doc) |d| allocator.free(d);
            }
        }
    }

    scopes.items(.tests)[@enumToInt(scope_index)] = try tests.toOwnedSlice(allocator);
    scopes.items(.uses)[@enumToInt(scope_index)] = try uses.toOwnedSlice(allocator);
}

/// If `node_idx` is a block it's scope index will be returned
/// Otherwise, a new scope will be created that will enclose `node_idx`
fn makeBlockScopeInternal(context: ScopeContext, tree: Ast, node_idx: Ast.Node.Index) error{OutOfMemory}!?Scope.Index {
    if (node_idx == 0) return null;
    const tags = tree.nodes.items(.tag);

    // if node_idx is a block, the next scope will be a block so we store its index here
    const block_scope_index = context.doc_scope.scopes.len;
    try makeScopeInternal(context, tree, node_idx);

    switch (tags[node_idx]) {
        .block,
        .block_semicolon,
        .block_two,
        .block_two_semicolon,
        => {
            std.debug.assert(context.doc_scope.scopes.items(.data)[block_scope_index] == .block);
            return @intToEnum(Scope.Index, block_scope_index);
        },
        else => {
            const new_scope = try context.pushScope(
                offsets.nodeToLoc(tree, node_idx),
                .other,
            );
            context.popScope();
            return new_scope;
        },
    }
}

fn makeScopeInternal(context: ScopeContext, tree: Ast, node_idx: Ast.Node.Index) error{OutOfMemory}!void {
    if (node_idx == 0) return;

    const allocator = context.allocator;

    const tags = tree.nodes.items(.tag);
    const token_tags = tree.tokens.items(.tag);
    const data = tree.nodes.items(.data);
    const main_tokens = tree.nodes.items(.main_token);

    const node_tag = tags[node_idx];

    switch (node_tag) {
        .root => unreachable,
        .container_decl,
        .container_decl_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => try makeInnerScope(context, tree, node_idx),
        .error_set_decl => {
            const scope_index = try context.pushScope(
                offsets.nodeToLoc(tree, node_idx),
                .{ .container = node_idx },
            );
            defer context.popScope();

            // All identifiers in main_token..data.rhs are error fields.
            var tok_i = main_tokens[node_idx] + 2;
            while (tok_i < data[node_idx].rhs) : (tok_i += 1) {
                switch (token_tags[tok_i]) {
                    .doc_comment, .comma => {},
                    .identifier => {
                        const name = offsets.tokenToSlice(tree, tok_i);
                        try context.putDecl(scope_index, name, .{ .error_token = tok_i });
                        const gop = try context.doc_scope.error_completions.getOrPut(allocator, .{
                            .label = name,
                            .kind = .Constant,
                            //.detail =
                            .insertText = name,
                            .insertTextFormat = .PlainText,
                        });
                        if (!gop.found_existing) {
                            gop.key_ptr.detail = try std.fmt.allocPrint(allocator, "error.{s}", .{name});
                        }
                    },
                    else => {},
                }
            }
        },
        .fn_proto,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_decl,
        => |fn_tag| {
            var buf: [1]Ast.Node.Index = undefined;
            const func = tree.fullFnProto(&buf, node_idx).?;

            const scope_index = try context.pushScope(
                offsets.nodeToLoc(tree, node_idx),
                .{ .function = node_idx },
            );
            defer context.popScope();

            // NOTE: We count the param index ourselves
            // as param_i stops counting; TODO: change this

            var param_index: usize = 0;

            var it = func.iterate(&tree);
            while (ast.nextFnParam(&it)) |param| {
                // Add parameter decls
                if (param.name_token) |name_token| {
                    try context.putDecl(
                        scope_index,
                        tree.tokenSlice(name_token),
                        .{ .param_payload = .{ .param = param, .param_idx = @intCast(u16, param_index), .func = node_idx } },
                    );
                }
                // Visit parameter types to pick up any error sets and enum
                //   completions
                try makeScopeInternal(context, tree, param.type_expr);
                param_index += 1;
            }

            if (fn_tag == .fn_decl) blk: {
                if (data[node_idx].lhs == 0) break :blk;
                const return_type_node = data[data[node_idx].lhs].rhs;

                // Visit the return type
                try makeScopeInternal(context, tree, return_type_node);
            }

            // Visit the function body
            try makeScopeInternal(context, tree, data[node_idx].rhs);
        },
        .block,
        .block_semicolon,
        .block_two,
        .block_two_semicolon,
        => {
            const first_token = tree.firstToken(node_idx);
            const last_token = ast.lastToken(tree, node_idx);

            // the last token may not always be the closing brace because of broken ast
            // so we look at most 16 characters ahead to find the closing brace
            // TODO this should automatically be done by `ast.lastToken`
            var end_index = offsets.tokenToLoc(tree, last_token).start;
            const lookahead_buffer = tree.source[end_index..@min(tree.source.len, end_index + 16)];
            end_index += std.mem.indexOfScalar(u8, lookahead_buffer, '}') orelse 0;

            const scope_index = try context.pushScope(
                .{
                    .start = offsets.tokenToIndex(tree, main_tokens[node_idx]),
                    .end = end_index,
                },
                .{ .block = node_idx },
            );
            defer context.popScope();

            // if labeled block
            if (token_tags[first_token] == .identifier) {
                try context.putDecl(
                    scope_index,
                    tree.tokenSlice(first_token),
                    .{ .label_decl = .{ .label = first_token, .block = node_idx } },
                );
            }

            var buffer: [2]Ast.Node.Index = undefined;
            const statements = ast.blockStatements(tree, node_idx, &buffer).?;

            for (statements) |idx| {
                try makeScopeInternal(context, tree, idx);
                if (tree.fullVarDecl(idx)) |var_decl| {
                    const name = tree.tokenSlice(var_decl.ast.mut_token + 1);
                    try context.putDecl(scope_index, name, .{ .ast_node = idx });
                }
            }
        },
        .@"if",
        .if_simple,
        => {
            const if_node = ast.fullIf(tree, node_idx).?;

            const then_scope = (try makeBlockScopeInternal(context, tree, if_node.ast.then_expr)).?;

            if (if_node.payload_token) |payload| {
                const name_token = payload + @boolToInt(token_tags[payload] == .asterisk);
                std.debug.assert(token_tags[name_token] == .identifier);

                const name = tree.tokenSlice(name_token);
                try context.putDecl(
                    then_scope,
                    name,
                    .{ .pointer_payload = .{ .name = name_token, .condition = if_node.ast.cond_expr } },
                );
            }

            if (if_node.ast.else_expr != 0) {
                const else_scope = (try makeBlockScopeInternal(context, tree, if_node.ast.else_expr)).?;
                if (if_node.error_token) |err_token| {
                    const name = tree.tokenSlice(err_token);
                    try context.putDecl(else_scope, name, .{ .ast_node = if_node.ast.else_expr });
                }
            }
        },
        .@"catch" => {
            try makeScopeInternal(context, tree, data[node_idx].lhs);

            const expr_scope = (try makeBlockScopeInternal(context, tree, data[node_idx].rhs)).?;

            const catch_token = main_tokens[node_idx] + 2;
            if (token_tags.len > catch_token and
                token_tags[catch_token - 1] == .pipe and
                token_tags[catch_token] == .identifier)
            {
                const name = tree.tokenSlice(catch_token);
                try context.putDecl(expr_scope, name, .{ .ast_node = data[node_idx].rhs });
            }
        },
        .@"while",
        .while_simple,
        .while_cont,
        => {
            // label_token: inline_token while (cond_expr) |payload_token| : (cont_expr) then_expr else else_expr
            const while_node = ast.fullWhile(tree, node_idx).?;

            try makeScopeInternal(context, tree, while_node.ast.cond_expr);

            const cont_scope = try makeBlockScopeInternal(context, tree, while_node.ast.cont_expr);
            const then_scope = (try makeBlockScopeInternal(context, tree, while_node.ast.then_expr)).?;
            const else_scope = try makeBlockScopeInternal(context, tree, while_node.ast.else_expr);

            if (while_node.label_token) |label| {
                std.debug.assert(token_tags[label] == .identifier);

                const name = tree.tokenSlice(label);
                try context.putDecl(then_scope, name, .{ .label_decl = .{ .label = label, .block = while_node.ast.then_expr } });
                if (else_scope) |index| {
                    try context.putDecl(index, name, .{ .label_decl = .{ .label = label, .block = while_node.ast.else_expr } });
                }
            }

            if (while_node.payload_token) |payload| {
                const name_token = payload + @boolToInt(token_tags[payload] == .asterisk);
                std.debug.assert(token_tags[name_token] == .identifier);

                const name = tree.tokenSlice(name_token);
                const decl: Declaration = .{
                    .pointer_payload = .{
                        .name = name_token,
                        .condition = while_node.ast.cond_expr,
                    },
                };
                if (cont_scope) |index| {
                    try context.putDecl(index, name, decl);
                }
                try context.putDecl(then_scope, name, decl);
            }

            if (while_node.error_token) |err_token| {
                std.debug.assert(token_tags[err_token] == .identifier);
                const name = tree.tokenSlice(err_token);
                try context.putDecl(else_scope.?, name, .{ .ast_node = while_node.ast.else_expr });
            }
        },
        .@"for",
        .for_simple,
        => {
            // label_token: inline_token for (inputs) |capture_tokens| then_expr else else_expr
            const for_node = ast.fullFor(tree, node_idx).?;

            for (for_node.ast.inputs) |input_node| {
                try makeScopeInternal(context, tree, input_node);
            }

            const then_scope = (try makeBlockScopeInternal(context, tree, for_node.ast.then_expr)).?;
            const else_scope = try makeBlockScopeInternal(context, tree, for_node.ast.else_expr);

            var capture_token = for_node.payload_token;
            for (for_node.ast.inputs) |input| {
                if (capture_token + 1 >= tree.tokens.len) break;
                const capture_is_ref = token_tags[capture_token] == .asterisk;
                const name_token = capture_token + @boolToInt(capture_is_ref);
                capture_token = name_token + 2;

                try context.putDecl(
                    then_scope,
                    offsets.tokenToSlice(tree, name_token),
                    .{ .array_payload = .{ .identifier = name_token, .array_expr = input } },
                );
            }

            if (for_node.label_token) |label| {
                std.debug.assert(token_tags[label] == .identifier);

                const name = tree.tokenSlice(label);
                try context.putDecl(
                    then_scope,
                    name,
                    .{ .label_decl = .{ .label = label, .block = for_node.ast.then_expr } },
                );
                if (else_scope) |index| {
                    try context.putDecl(
                        index,
                        name,
                        .{ .label_decl = .{ .label = label, .block = for_node.ast.else_expr } },
                    );
                }
            }
        },
        .@"switch",
        .switch_comma,
        => {
            const cond = data[node_idx].lhs;
            const extra = tree.extraData(data[node_idx].rhs, Ast.Node.SubRange);
            const cases = tree.extra_data[extra.start..extra.end];

            for (cases) |case| {
                const switch_case: Ast.full.SwitchCase = tree.fullSwitchCase(case).?;

                if (switch_case.payload_token) |payload| {
                    const expr_index = (try makeBlockScopeInternal(context, tree, switch_case.ast.target_expr)).?;
                    // if payload is *name than get next token
                    const name_token = payload + @boolToInt(token_tags[payload] == .asterisk);
                    const name = tree.tokenSlice(name_token);

                    try context.putDecl(expr_index, name, .{
                        .switch_payload = .{ .node = name_token, .switch_expr = cond, .items = switch_case.ast.values },
                    });

                    try makeScopeInternal(context, tree, switch_case.ast.target_expr);
                } else {
                    try makeScopeInternal(context, tree, switch_case.ast.target_expr);
                }
            }
        },
        .@"errdefer" => {
            const expr_scope = (try makeBlockScopeInternal(context, tree, data[node_idx].rhs)).?;

            const payload_token = data[node_idx].lhs;
            if (payload_token != 0) {
                const name = tree.tokenSlice(payload_token);
                try context.putDecl(expr_scope, name, .{ .ast_node = data[node_idx].rhs });
            }
        },
        else => {
            try ast.iterateChildren(tree, node_idx, context, error{OutOfMemory}, makeScopeInternal);
        },
    }
}

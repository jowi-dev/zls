const std = @import("std");
const Ast = std.zig.Ast;
const log = std.log.scoped(.zls_completions);

const Server = @import("../Server.zig");
const Config = @import("../Config.zig");
const DocumentStore = @import("../DocumentStore.zig");
const types = @import("../lsp.zig");
const Analyser = @import("../analysis.zig");
const ast = @import("../ast.zig");
const offsets = @import("../offsets.zig");
const tracy = @import("../tracy.zig");
const URI = @import("../uri.zig");
const analyser = @import("../analyser/analyser.zig");

const data = @import("../data/data.zig");
const snipped_data = @import("../data/snippets.zig");

fn typeToCompletion(
    server: *Server,
    list: *std.ArrayListUnmanaged(types.CompletionItem),
    field_access: Analyser.FieldAccessReturn,
    orig_handle: *const DocumentStore.Handle,
    either_descriptor: ?[]const u8,
) error{OutOfMemory}!void {
    var allocator = server.arena.allocator();

    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const type_handle = field_access.original;
    switch (type_handle.type.data) {
        .slice => {
            if (!type_handle.type.is_type_val) {
                try list.append(allocator, .{
                    .label = "len",
                    .detail = "const len: usize",
                    .kind = .Field,
                    .insertText = "len",
                    .insertTextFormat = .PlainText,
                });
                try list.append(allocator, .{
                    .label = "ptr",
                    .kind = .Field,
                    .insertText = "ptr",
                    .insertTextFormat = .PlainText,
                });
            }
        },
        .error_union => {},
        .pointer => |n| {
            if (server.config.operator_completions) {
                try list.append(allocator, .{
                    .label = "*",
                    .kind = .Operator,
                    .insertText = "*",
                    .insertTextFormat = .PlainText,
                });
            }
            try nodeToCompletion(
                server,
                list,
                .{ .node = n, .handle = type_handle.handle },
                null,
                orig_handle,
                type_handle.type.is_type_val,
                null,
                either_descriptor,
            );
        },
        .other => |n| try nodeToCompletion(
            server,
            list,
            .{ .node = n, .handle = type_handle.handle },
            field_access.unwrapped,
            orig_handle,
            type_handle.type.is_type_val,
            null,
            either_descriptor,
        ),
        .primitive, .array_index => {},
        .@"comptime" => |co| try analyser.completions.dotCompletions(
            allocator,
            list,
            co.interpreter.ip,
            co.value.index,
            type_handle.type.is_type_val,
            co.value.node_idx,
        ),
        .either => |bruh| {
            for (bruh) |a|
                try typeToCompletion(server, list, .{ .original = a.type_with_handle }, orig_handle, a.descriptor);
        },
    }
}

fn nodeToCompletion(
    server: *Server,
    list: *std.ArrayListUnmanaged(types.CompletionItem),
    node_handle: Analyser.NodeWithHandle,
    unwrapped: ?Analyser.TypeWithHandle,
    orig_handle: *const DocumentStore.Handle,
    is_type_val: bool,
    parent_is_type_val: ?bool,
    either_descriptor: ?[]const u8,
) error{OutOfMemory}!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var allocator = server.arena.allocator();

    const node = node_handle.node;
    const handle = node_handle.handle;
    const tree = handle.tree;
    const node_tags = tree.nodes.items(.tag);
    const token_tags = tree.tokens.items(.tag);

    const doc_kind: types.MarkupKind = if (server.client_capabilities.completion_doc_supports_md)
        .markdown
    else
        .plaintext;

    const Documentation = @TypeOf(@as(types.CompletionItem, undefined).documentation);

    const doc: Documentation = if (try Analyser.getDocComments(
        allocator,
        handle.tree,
        node,
        doc_kind,
    )) |doc_comments| .{ .MarkupContent = types.MarkupContent{
        .kind = doc_kind,
        .value = if (either_descriptor) |ed|
            try std.fmt.allocPrint(allocator, "`Conditionally available: {s}`\n\n{s}", .{ ed, doc_comments })
        else
            doc_comments,
    } } else (if (either_descriptor) |ed|
        .{ .MarkupContent = types.MarkupContent{
            .kind = doc_kind,
            .value = try std.fmt.allocPrint(allocator, "`Conditionally available: {s}`", .{ed}),
        } }
    else
        null);

    if (ast.isContainer(handle.tree, node)) {
        const context = DeclToCompletionContext{
            .server = server,
            .completions = list,
            .orig_handle = orig_handle,
            .parent_is_type_val = is_type_val,
            .either_descriptor = either_descriptor,
        };
        try server.analyser.iterateSymbolsContainer(
            node_handle,
            orig_handle,
            declToCompletion,
            context,
            !is_type_val,
        );
    }

    if (is_type_val) return;

    switch (node_tags[node]) {
        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_decl,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            const func = tree.fullFnProto(&buf, node).?;
            if (func.name_token) |name_token| {
                const use_snippets = server.config.enable_snippets and server.client_capabilities.supports_snippets;
                const insert_text = if (use_snippets) blk: {
                    const skip_self_param = !(parent_is_type_val orelse true) and
                        try server.analyser.hasSelfParam(handle, func);
                    break :blk try Analyser.getFunctionSnippet(server.arena.allocator(), tree, func, skip_self_param);
                } else tree.tokenSlice(func.name_token.?);

                const is_type_function = Analyser.isTypeFunction(handle.tree, func);

                try list.append(allocator, .{
                    .label = handle.tree.tokenSlice(name_token),
                    .kind = if (is_type_function) .Struct else .Function,
                    .documentation = doc,
                    .detail = Analyser.getFunctionSignature(handle.tree, func),
                    .insertText = insert_text,
                    .insertTextFormat = if (use_snippets) .Snippet else .PlainText,
                });
            }
        },
        .global_var_decl,
        .local_var_decl,
        .aligned_var_decl,
        .simple_var_decl,
        => {
            const var_decl = tree.fullVarDecl(node).?;
            const is_const = token_tags[var_decl.ast.mut_token] == .keyword_const;

            if (try server.analyser.resolveVarDeclAlias(node_handle)) |result| {
                const context = DeclToCompletionContext{
                    .server = server,
                    .completions = list,
                    .orig_handle = orig_handle,
                    .either_descriptor = either_descriptor,
                };
                return try declToCompletion(context, result);
            }

            try list.append(allocator, .{
                .label = handle.tree.tokenSlice(var_decl.ast.mut_token + 1),
                .kind = if (is_const) .Constant else .Variable,
                .documentation = doc,
                .detail = Analyser.getVariableSignature(tree, var_decl),
                .insertText = tree.tokenSlice(var_decl.ast.mut_token + 1),
                .insertTextFormat = .PlainText,
            });
        },
        .container_field,
        .container_field_align,
        .container_field_init,
        => {
            const field = tree.fullContainerField(node).?;
            try list.append(allocator, .{
                .label = handle.tree.tokenSlice(field.ast.main_token),
                .kind = if (field.ast.tuple_like) .EnumMember else .Field,
                .documentation = doc,
                .detail = Analyser.getContainerFieldSignature(handle.tree, field),
                .insertText = tree.tokenSlice(field.ast.main_token),
                .insertTextFormat = .PlainText,
            });
        },
        .array_type,
        .array_type_sentinel,
        => {
            try list.append(allocator, .{
                .label = "len",
                .detail = "const len: usize",
                .kind = .Field,
                .insertText = "len",
                .insertTextFormat = .PlainText,
            });
        },
        .ptr_type,
        .ptr_type_aligned,
        .ptr_type_bit_range,
        .ptr_type_sentinel,
        => {
            const ptr_type = ast.fullPtrType(tree, node).?;

            switch (ptr_type.size) {
                .One, .C, .Many => if (server.config.operator_completions) {
                    try list.append(allocator, .{
                        .label = "*",
                        .kind = .Operator,
                        .insertText = "*",
                        .insertTextFormat = .PlainText,
                    });
                },
                .Slice => {
                    try list.append(allocator, .{
                        .label = "ptr",
                        .kind = .Field,
                        .insertText = "ptr",
                        .insertTextFormat = .PlainText,
                    });
                    try list.append(allocator, .{
                        .label = "len",
                        .detail = "const len: usize",
                        .kind = .Field,
                        .insertText = "len",
                        .insertTextFormat = .PlainText,
                    });
                    return;
                },
            }

            if (unwrapped) |actual_type| {
                try typeToCompletion(server, list, .{ .original = actual_type }, orig_handle, either_descriptor);
            }
            return;
        },
        .optional_type => {
            if (server.config.operator_completions) {
                try list.append(allocator, .{
                    .label = "?",
                    .kind = .Operator,
                    .insertText = "?",
                    .insertTextFormat = .PlainText,
                });
            }
            return;
        },
        .string_literal => {
            try list.append(allocator, .{
                .label = "len",
                .detail = "const len: usize",
                .kind = .Field,
                .insertText = "len",
                .insertTextFormat = .PlainText,
            });
        },
        else => if (Analyser.nodeToString(tree, node)) |string| {
            try list.append(allocator, .{
                .label = string,
                .kind = .Field,
                .documentation = doc,
                .detail = offsets.nodeToSlice(tree, node),
                .insertText = string,
                .insertTextFormat = .PlainText,
            });
        },
    }
}

const DeclToCompletionContext = struct {
    server: *Server,
    completions: *std.ArrayListUnmanaged(types.CompletionItem),
    orig_handle: *const DocumentStore.Handle,
    parent_is_type_val: ?bool = null,
    either_descriptor: ?[]const u8 = null,
};

fn declToCompletion(context: DeclToCompletionContext, decl_handle: Analyser.DeclWithHandle) error{OutOfMemory}!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var allocator = context.server.arena.allocator();

    const tree = decl_handle.handle.tree;
    const decl = decl_handle.decl.*;

    const is_cimport = std.mem.eql(u8, std.fs.path.basename(decl_handle.handle.uri), "cimport.zig");
    if (is_cimport) {
        const name = tree.tokenSlice(decl_handle.nameToken());
        if (std.mem.startsWith(u8, name, "_")) return;
        // TODO figuring out which declarations should be excluded could be made more complete and accurate
        // by translating an empty file to acquire all exclusions
        const exclusions = std.ComptimeStringMap(void, .{
            .{ "linux", {} },
            .{ "unix", {} },
            .{ "WIN32", {} },
            .{ "WINNT", {} },
            .{ "WIN64", {} },
        });
        if (exclusions.has(name)) return;
    }

    switch (decl_handle.decl.*) {
        .ast_node => |node| try nodeToCompletion(
            context.server,
            context.completions,
            .{ .node = node, .handle = decl_handle.handle },
            null,
            context.orig_handle,
            false,
            context.parent_is_type_val,
            context.either_descriptor,
        ),
        .param_payload => |pay| {
            const Documentation = @TypeOf(@as(types.CompletionItem, undefined).documentation);

            const param = pay.param;
            const doc_kind: types.MarkupKind = if (context.server.client_capabilities.completion_doc_supports_md) .markdown else .plaintext;
            const doc: Documentation = if (param.first_doc_comment) |doc_comments| .{ .MarkupContent = types.MarkupContent{
                .kind = doc_kind,
                .value = if (context.either_descriptor) |ed|
                    try std.fmt.allocPrint(allocator, "`Conditionally available: {s}`\n\n{s}", .{ ed, try Analyser.collectDocComments(allocator, tree, doc_comments, doc_kind, false) })
                else
                    try Analyser.collectDocComments(allocator, tree, doc_comments, doc_kind, false),
            } } else null;

            try context.completions.append(allocator, .{
                .label = tree.tokenSlice(param.name_token.?),
                .kind = .Constant,
                .documentation = doc,
                .detail = ast.paramSlice(tree, param),
                .insertText = tree.tokenSlice(param.name_token.?),
                .insertTextFormat = .PlainText,
            });
        },
        .pointer_payload,
        .array_payload,
        .array_index,
        .switch_payload,
        .label_decl,
        => {
            const name = tree.tokenSlice(decl_handle.nameToken());

            try context.completions.append(allocator, .{
                .label = name,
                .kind = if (decl == .label_decl) .Text else .Variable,
                .insertText = name,
                .insertTextFormat = .PlainText,
            });
        },
        .error_token => {
            const name = tree.tokenSlice(decl_handle.decl.error_token);

            try context.completions.append(allocator, .{
                .label = name,
                .kind = .Constant,
                .detail = try std.fmt.allocPrint(allocator, "error.{s}", .{name}),
                .insertText = name,
                .insertTextFormat = .PlainText,
            });
        },
    }
}

fn completeLabel(
    server: *Server,
    pos_index: usize,
    handle: *const DocumentStore.Handle,
) error{OutOfMemory}![]types.CompletionItem {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var completions = std.ArrayListUnmanaged(types.CompletionItem){};

    const context = DeclToCompletionContext{
        .server = server,
        .completions = &completions,
        .orig_handle = handle,
    };
    try Analyser.iterateLabels(handle, pos_index, declToCompletion, context);

    return completions.toOwnedSlice(server.arena.allocator());
}

fn populateSnippedCompletions(
    allocator: std.mem.Allocator,
    completions: *std.ArrayListUnmanaged(types.CompletionItem),
    snippets: []const snipped_data.Snipped,
    config: Config,
) error{OutOfMemory}!void {
    try completions.ensureUnusedCapacity(allocator, snippets.len);

    for (snippets) |snipped| {
        if (!config.enable_snippets and snipped.kind == .Snippet) continue;

        completions.appendAssumeCapacity(.{
            .label = snipped.label,
            .kind = snipped.kind,
            .detail = if (config.enable_snippets) snipped.text else null,
            .insertText = if (config.enable_snippets) snipped.text else null,
            .insertTextFormat = if (config.enable_snippets and snipped.text != null) .Snippet else .PlainText,
        });
    }
}

fn completeBuiltin(server: *Server) error{OutOfMemory}!?[]types.CompletionItem {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const allocator = server.arena.allocator();

    const builtin_completions = blk: {
        if (server.builtin_completions) |completions| {
            break :blk completions;
        } else {
            server.builtin_completions = try std.ArrayListUnmanaged(types.CompletionItem).initCapacity(server.allocator, data.builtins.len);
            for (data.builtins) |builtin| {
                const use_snippets = server.config.enable_snippets and server.client_capabilities.supports_snippets;
                const insert_text = if (use_snippets) builtin.snippet else builtin.name;
                server.builtin_completions.?.appendAssumeCapacity(.{
                    .label = builtin.name,
                    .kind = .Function,
                    .filterText = builtin.name[1..],
                    .detail = builtin.signature,
                    .insertText = if (server.config.include_at_in_builtins) insert_text else insert_text[1..],
                    .insertTextFormat = if (use_snippets) .Snippet else .PlainText,
                    .documentation = .{
                        .MarkupContent = .{
                            .kind = .markdown,
                            .value = builtin.documentation,
                        },
                    },
                });
            }
            break :blk server.builtin_completions.?;
        }
    };

    var completions = try builtin_completions.clone(allocator);

    if (server.client_capabilities.label_details_support) {
        for (completions.items) |*item| {
            try formatDetailedLabel(item, allocator);
        }
    }

    return completions.items;
}

fn completeGlobal(server: *Server, pos_index: usize, handle: *const DocumentStore.Handle) error{OutOfMemory}![]types.CompletionItem {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var completions = std.ArrayListUnmanaged(types.CompletionItem){};

    const context = DeclToCompletionContext{
        .server = server,
        .completions = &completions,
        .orig_handle = handle,
    };
    try server.analyser.iterateSymbolsGlobal(handle, pos_index, declToCompletion, context);
    try populateSnippedCompletions(server.arena.allocator(), &completions, &snipped_data.generic, server.config.*);

    if (server.client_capabilities.label_details_support) {
        for (completions.items) |*item| {
            try formatDetailedLabel(item, server.arena.allocator());
        }
    }

    return completions.toOwnedSlice(server.arena.allocator());
}

fn completeFieldAccess(server: *Server, handle: *const DocumentStore.Handle, source_index: usize, loc: offsets.Loc) error{OutOfMemory}!?[]types.CompletionItem {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const allocator = server.arena.allocator();

    var completions = std.ArrayListUnmanaged(types.CompletionItem){};

    var held_loc = try allocator.dupeZ(u8, offsets.locToSlice(handle.text, loc));
    var tokenizer = std.zig.Tokenizer.init(held_loc);

    const result = (try server.analyser.getFieldAccessType(handle, source_index, &tokenizer)) orelse return null;
    try typeToCompletion(server, &completions, result, handle, null);
    if (server.client_capabilities.label_details_support) {
        for (completions.items) |*item| {
            try formatDetailedLabel(item, allocator);
        }
    }

    return try completions.toOwnedSlice(allocator);
}

fn formatDetailedLabel(item: *types.CompletionItem, arena: std.mem.Allocator) error{OutOfMemory}!void {
    // NOTE: this is not ideal, we should build a detailed label like we do for label/detail
    // because this implementation is very loose, nothing is formatted properly so we need to clean
    // things a little bit, which is quite messy
    // but it works, it provide decent results

    std.debug.assert(item.kind != null);
    if (item.detail == null)
        return;

    const detail = item.detail.?[0..@min(1024, item.detail.?.len)];
    var detailLen: usize = detail.len;
    var it: []u8 = try arena.alloc(u8, detailLen);

    detailLen -= std.mem.replace(u8, detail, "    ", " ", it) * 3;
    it = it[0..detailLen];

    // HACK: for enums 'MyEnum.', item.detail shows everything, we don't want that
    const isValue = std.mem.startsWith(u8, item.label, it);

    const isVar = std.mem.startsWith(u8, it, "var ");
    const isConst = std.mem.startsWith(u8, it, "const ");

    // we don't want the entire content of things, see the NOTE above
    if (std.mem.indexOf(u8, it, "{")) |end| {
        it = it[0..end];
    }
    if (std.mem.indexOf(u8, it, "}")) |end| {
        it = it[0..end];
    }
    if (std.mem.indexOf(u8, it, ";")) |end| {
        it = it[0..end];
    }

    // log.info("## label: {s} it: {s} kind: {} isValue: {}", .{item.label, it, item.kind, isValue});

    if (std.mem.startsWith(u8, it, "fn ") or std.mem.startsWith(u8, it, "@")) {
        var s: usize = std.mem.indexOf(u8, it, "(") orelse return;
        var e: usize = std.mem.lastIndexOf(u8, it, ")") orelse return;
        if (e < s) {
            log.warn("something wrong when trying to build label detail for {s} kind: {}", .{ it, item.kind.? });
            return;
        }

        item.detail = item.label;
        item.labelDetails = .{ .detail = it[s .. e + 1], .description = it[e + 1 ..] };

        if (item.kind.? == .Constant) {
            if (std.mem.indexOf(u8, it, "= struct")) |_| {
                item.labelDetails.?.description = "struct";
            } else if (std.mem.indexOf(u8, it, "= union")) |_| {
                var us: usize = std.mem.indexOf(u8, it, "(") orelse return;
                var ue: usize = std.mem.lastIndexOf(u8, it, ")") orelse return;
                if (ue < us) {
                    log.warn("something wrong when trying to build label detail for a .Constant|union {s}", .{it});
                    return;
                }

                item.labelDetails.?.description = it[us - 5 .. ue + 1];
            }
        }
    } else if ((item.kind.? == .Variable or item.kind.? == .Constant) and (isVar or isConst)) {
        item.insertText = item.label;
        item.insertTextFormat = .PlainText;
        item.detail = item.label;

        const eqlPos = std.mem.indexOf(u8, it, "=");

        if (std.mem.indexOf(u8, it, ":")) |start| {
            if (eqlPos != null) {
                if (start > eqlPos.?) return;
            }
            var e: usize = eqlPos orelse it.len;
            item.labelDetails = .{
                .detail = "", // left
                .description = it[start + 1 .. e], // right
            };
        } else if (std.mem.indexOf(u8, it, "= .")) |start| {
            item.labelDetails = .{
                .detail = "", // left
                .description = it[start + 2 .. it.len], // right
            };
        } else if (eqlPos) |start| {
            item.labelDetails = .{
                .detail = "", // left
                .description = it[start + 2 .. it.len], // right
            };
        }
    } else if (item.kind.? == .Variable) {
        var s: usize = std.mem.indexOf(u8, it, ":") orelse return;
        var e: usize = std.mem.indexOf(u8, it, "=") orelse return;

        if (e < s) {
            log.warn("something wrong when trying to build label detail for a .Variable {s}", .{it});
            return;
        }
        // log.info("s: {} -> {}", .{s, e});
        item.insertText = item.label;
        item.insertTextFormat = .PlainText;
        item.detail = item.label;
        item.labelDetails = .{
            .detail = "", // left
            .description = it[s + 1 .. e], // right
        };
    } else if (std.mem.indexOf(u8, it, "@import") != null) {
        item.insertText = item.label;
        item.insertTextFormat = .PlainText;
        item.detail = item.label;
        item.labelDetails = .{
            .detail = "", // left
            .description = it, // right
        };
    } else if (item.kind.? == .Constant or item.kind.? == .Field) {
        var s: usize = std.mem.indexOf(u8, it, " ") orelse return;
        var e: usize = std.mem.indexOf(u8, it, "=") orelse it.len;
        if (e < s) {
            log.warn("something wrong when trying to build label detail for a .Variable {s}", .{it});
            return;
        }
        // log.info("s: {} -> {}", .{s, e});
        item.insertText = item.label;
        item.insertTextFormat = .PlainText;
        item.detail = item.label;
        item.labelDetails = .{
            .detail = "", // left
            .description = it[s + 1 .. e], // right
        };

        if (std.mem.indexOf(u8, it, "= union(")) |_| {
            var us: usize = std.mem.indexOf(u8, it, "(") orelse return;
            var ue: usize = std.mem.lastIndexOf(u8, it, ")") orelse return;
            if (ue < us) {
                log.warn("something wrong when trying to build label detail for a .Constant|union {s}", .{it});
                return;
            }
            item.labelDetails.?.description = it[us - 5 .. ue + 1];
        } else if (std.mem.indexOf(u8, it, "= enum(")) |_| {
            var es: usize = std.mem.indexOf(u8, it, "(") orelse return;
            var ee: usize = std.mem.lastIndexOf(u8, it, ")") orelse return;
            if (ee < es) {
                log.warn("something wrong when trying to build label detail for a .Constant|enum {s}", .{it});
                return;
            }
            item.labelDetails.?.description = it[es - 4 .. ee + 1];
        } else if (std.mem.indexOf(u8, it, "= struct")) |_| {
            item.labelDetails.?.description = "struct";
        } else if (std.mem.indexOf(u8, it, "= union")) |_| {
            item.labelDetails.?.description = "union";
        } else if (std.mem.indexOf(u8, it, "= enum")) |_| {
            item.labelDetails.?.description = "enum";
        }
    } else if (item.kind.? == .Field and isValue) {
        item.insertText = item.label;
        item.insertTextFormat = .PlainText;
        item.detail = item.label;
        item.labelDetails = .{
            .detail = "", // left
            .description = item.label, // right
        };
    } else {
        // TODO: if something is missing, it needs to be implemented here
    }

    // if (item.labelDetails != null)
    //     logger.info("labelDetails: {s}  ::  {s}", .{item.labelDetails.?.detail, item.labelDetails.?.description});
}

fn completeError(server: *Server, handle: *const DocumentStore.Handle) error{OutOfMemory}![]types.CompletionItem {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    return try server.document_store.errorCompletionItems(server.arena.allocator(), handle.*);
}

fn kindToSortScore(kind: types.CompletionItemKind) ?[]const u8 {
    return switch (kind) {
        .Module => "1_", // use for packages
        .Folder => "2_",
        .File => "3_",

        .Constant => "1_",

        .Variable => "2_",
        .Field => "3_",
        .Function => "4_",

        .Keyword, .Snippet, .EnumMember => "5_",

        .Class,
        .Interface,
        .Struct,
        .Enum,
        // Union?
        .TypeParameter,
        => "6_",

        else => {
            log.debug(@typeName(types.CompletionItemKind) ++ "{s} has no sort score specified!", .{@tagName(kind)});
            return null;
        },
    };
}

/// Given a root node decl or a .simple_var_decl (const MyStruct = struct {..}) node decl, adds it's `.container_field*`s to completions
pub fn addStructInitNodeFields(server: *Server, decl: Analyser.DeclWithHandle, completions: *std.ArrayListUnmanaged(types.CompletionItem)) error{OutOfMemory}!void {
    const node = switch (decl.decl.*) {
        .ast_node => |ast_node| ast_node,
        else => return,
    };
    const node_tags = decl.handle.tree.nodes.items(.tag);
    switch (node_tags[node]) {
        .simple_var_decl => {
            const node_data = decl.handle.tree.nodes.items(.data)[node];
            if (node_data.rhs != 0) {
                var buffer: [2]Ast.Node.Index = undefined;
                const container_decl = Ast.fullContainerDecl(decl.handle.tree, &buffer, node_data.rhs) orelse return;
                for (container_decl.ast.members) |member| {
                    const field = decl.handle.tree.fullContainerField(member) orelse continue;
                    try completions.append(server.arena.allocator(), .{
                        .label = decl.handle.tree.tokenSlice(field.ast.main_token),
                        .kind = if (field.ast.tuple_like) .EnumMember else .Field,
                        .detail = Analyser.getContainerFieldSignature(decl.handle.tree, field),
                        .insertText = decl.handle.tree.tokenSlice(field.ast.main_token),
                        .insertTextFormat = .PlainText,
                    });
                }
            }
        },
        .root => {
            for (decl.handle.tree.rootDecls()) |root_node| {
                const field = decl.handle.tree.fullContainerField(@intCast(u32, root_node)) orelse continue;
                try completions.append(server.arena.allocator(), .{
                    .label = decl.handle.tree.tokenSlice(field.ast.main_token),
                    .kind = if (field.ast.tuple_like) .EnumMember else .Field,
                    .detail = Analyser.getContainerFieldSignature(decl.handle.tree, field),
                    .insertText = decl.handle.tree.tokenSlice(field.ast.main_token),
                    .insertTextFormat = .PlainText,
                });
            }
        },
        else => {},
    }
}

fn completeDot(server: *Server, handle: *const DocumentStore.Handle, source_index: usize) error{OutOfMemory}![]types.CompletionItem {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const allocator = server.arena.allocator();

    struct_init: {
        const tree = handle.tree;
        const tokens_start = tree.tokens.items(.start);

        var upper_index = tokens_start.len - 1;
        const mid = upper_index / 2;
        const mid_tok_start = tokens_start[mid];
        if (mid_tok_start < source_index) {
            // std.log.debug("source_index is in upper half", .{});
            const quart_index = mid + (mid / 2);
            const quart_tok_start = tokens_start[quart_index];
            if (quart_tok_start < source_index) {
                // std.log.debug("source_index is in upper fourth", .{});
            } else {
                upper_index = quart_index;
                // std.log.debug("source_index is in upper third", .{});
            }
        } else {
            // std.log.debug("source_index is in lower half", .{});
            const quart_index = mid / 2;
            const quart_tok_start = tokens_start[quart_index];
            if (quart_tok_start < source_index) {
                // std.log.debug("source_index is in second quarth", .{});
                upper_index = mid;
            } else {
                // std.log.debug("source_index is in first quarth", .{});
                upper_index = quart_index;
            }
        }

        // iterate until we find current token loc (should be a .period)
        while (upper_index > 0) : (upper_index -= 1) {
            if (tokens_start[upper_index] > source_index) continue;
            upper_index -= 1;
            break;
        }

        const token_tags = tree.tokens.items(.tag);

        if (token_tags[upper_index] == .number_literal) break :struct_init; // `var s = MyStruct{.float_field = 1.`

        // look for .identifier followed by .l_brace, skipping matches at depth 0+
        var depth: i32 = 0; // Should end up being negative, ie even the first/single .l_brace would put it at -1; 0+ => nested
        while (upper_index > 0) {
            if (token_tags[upper_index] != .identifier) {
                switch (token_tags[upper_index]) {
                    .r_brace => depth += 1,
                    .l_brace => depth -= 1,
                    .period => if (depth < 0 and token_tags[upper_index + 1] == .l_brace) break :struct_init, // anon struct init `.{.`
                    .semicolon => break :struct_init, // generic exit; maybe also .keyword_(var/const)
                    else => {},
                }
            } else if (token_tags[upper_index + 1] == .l_brace and depth < 0) break;
            upper_index -= 1;
        }

        if (upper_index == 0) break :struct_init;

        var identifier_loc = offsets.tokenIndexToLoc(tree.source, tokens_start[upper_index]);

        // if this is done as a field access collect all the identifiers, eg `path.to.MyStruct`
        var identifier_original_start = identifier_loc.start;
        while ((token_tags[upper_index] == .period or token_tags[upper_index] == .identifier) and upper_index > 0) : (upper_index -= 1) {
            identifier_loc.start = tokens_start[upper_index];
        }

        // token_tags[upper_index + 1] should be .identifier, else => there are potentially more tokens, eg
        // the `@import("my_file.zig")` in  `var s = @import("my_file.zig").MyStruct{.`, which getSymbolFieldAccesses can(?) handle
        // but it could be some other combo of tokens.. potential TODO
        if (token_tags[upper_index + 1] != .identifier) break :struct_init;

        var completions = std.ArrayListUnmanaged(types.CompletionItem){};

        if (identifier_loc.start != identifier_original_start) { // path.to.MyStruct{.<cursor> => use field access resolution
            const possible_decls = (try server.getSymbolFieldAccesses(handle, identifier_loc.end, identifier_loc));
            if (possible_decls) |decls| {
                for (decls) |decl| {
                    switch (decl.decl.*) {
                        .ast_node => |node| {
                            if (try server.analyser.resolveVarDeclAlias(.{ .node = node, .handle = decl.handle })) |result| {
                                try addStructInitNodeFields(server, result, &completions);
                                continue;
                            }
                            try addStructInitNodeFields(server, decl, &completions);
                        },
                        else => continue,
                    }
                }
            }
        } else { // MyStruct{.<cursor> => use var resolution (supports only one level of indirection)
            const maybe_decl = try server.analyser.lookupSymbolGlobal(handle, tree.source[identifier_loc.start..identifier_loc.end], identifier_loc.end);
            if (maybe_decl) |local_decl| {
                const nodes_tags = handle.tree.nodes.items(.tag);
                const nodes_data = handle.tree.nodes.items(.data);
                switch (local_decl.decl.*) {
                    .ast_node => {},
                    else => break :struct_init,
                }
                const node_data = nodes_data[local_decl.decl.ast_node];
                if (node_data.rhs != 0) {
                    switch (nodes_tags[node_data.rhs]) {
                        // decl is `const Alias = @import("MyStruct.zig");`
                        .builtin_call_two => {
                            var buffer: [2]Ast.Node.Index = undefined;
                            const params = ast.builtinCallParams(tree, node_data.rhs, &buffer).?;

                            const main_tokens = tree.nodes.items(.main_token);
                            const call_name = tree.tokenSlice(main_tokens[node_data.rhs]);

                            if (std.mem.eql(u8, call_name, "@import")) {
                                if (params.len == 0) break :struct_init;
                                const import_param = params[0];
                                if (nodes_tags[import_param] != .string_literal) break :struct_init;

                                const import_str = tree.tokenSlice(main_tokens[import_param]);
                                const import_uri = (try server.document_store.uriFromImportStr(allocator, handle.*, import_str[1 .. import_str.len - 1])) orelse break :struct_init;

                                const node_handle = server.document_store.getOrLoadHandle(import_uri) orelse break :struct_init;
                                var decl = Analyser.Declaration{ .ast_node = 0 };
                                try addStructInitNodeFields(server, Analyser.DeclWithHandle{ .handle = node_handle, .decl = &decl }, &completions);
                            }
                        },
                        // decl is `const Alias = path.to.MyStruct` or `const Alias = @import("file.zig").MyStruct;`
                        .field_access => {
                            const node_loc = offsets.nodeToLoc(tree, node_data.rhs);
                            const possible_decls = (try server.getSymbolFieldAccesses(handle, node_loc.end, node_loc));
                            if (possible_decls) |decls| {
                                for (decls) |decl| {
                                    switch (decl.decl.*) {
                                        .ast_node => |node| {
                                            if (try server.analyser.resolveVarDeclAlias(.{ .node = node, .handle = decl.handle })) |result| {
                                                try addStructInitNodeFields(server, result, &completions);
                                                continue;
                                            }
                                            try addStructInitNodeFields(server, decl, &completions);
                                        },
                                        else => continue,
                                    }
                                }
                            }
                        },
                        // decl is `const AliasB = AliasA;` (alias of an alias)
                        //.identifier => {},
                        // decl is `const MyStruct = struct {..}` which is a .simple_var_decl (check is in addStructInitNodeFields)
                        else => try addStructInitNodeFields(server, local_decl, &completions),
                    }
                }
            }
        }

        if (completions.items.len != 0) return completions.toOwnedSlice(allocator);
    }

    var completions = try server.document_store.enumCompletionItems(allocator, handle.*);
    return completions;
}

fn completeFileSystemStringLiteral(
    arena: std.mem.Allocator,
    store: DocumentStore,
    handle: DocumentStore.Handle,
    pos_context: Analyser.PositionContext,
) ![]types.CompletionItem {
    var completions: Analyser.CompletionSet = .{};

    const loc = pos_context.loc().?;
    var completing = handle.tree.source[loc.start + 1 .. loc.end - 1];

    var separator_index = completing.len;
    while (separator_index > 0) : (separator_index -= 1) {
        if (std.fs.path.isSep(completing[separator_index - 1])) break;
    }
    completing = completing[0..separator_index];

    var search_paths: std.ArrayListUnmanaged([]const u8) = .{};
    if (std.fs.path.isAbsolute(completing) and pos_context != .import_string_literal) {
        try search_paths.append(arena, completing);
    } else if (pos_context == .cinclude_string_literal) {
        store.collectIncludeDirs(arena, handle, &search_paths) catch |err| {
            log.err("failed to resolve include paths: {}", .{err});
            return &.{};
        };
    } else {
        var document_path = try URI.parse(arena, handle.uri);
        try search_paths.append(arena, std.fs.path.dirname(document_path).?);
    }

    for (search_paths.items) |path| {
        if (!std.fs.path.isAbsolute(path)) continue;
        const dir_path = if (std.fs.path.isAbsolute(completing)) path else try std.fs.path.join(arena, &.{ path, completing });

        var iterable_dir = std.fs.openIterableDirAbsolute(dir_path, .{}) catch continue;
        defer iterable_dir.close();
        var it = iterable_dir.iterateAssumeFirstIteration();

        while (it.next() catch null) |entry| {
            const expected_extension = switch (pos_context) {
                .import_string_literal => ".zig",
                .cinclude_string_literal => ".h",
                .embedfile_string_literal => null,
                else => unreachable,
            };
            switch (entry.kind) {
                .file => if (expected_extension) |expected| {
                    const actual_extension = std.fs.path.extension(entry.name);
                    if (!std.mem.eql(u8, actual_extension, expected)) continue;
                },
                .directory => {},
                else => continue,
            }

            _ = try completions.getOrPut(arena, types.CompletionItem{
                .label = try arena.dupe(u8, entry.name),
                .detail = if (pos_context == .cinclude_string_literal) path else null,
                .insertText = if (entry.kind == .directory)
                    try std.fmt.allocPrint(arena, "{s}/", .{entry.name})
                else
                    null,
                .kind = if (entry.kind == .file) .File else .Folder,
            });
        }
    }

    if (completing.len == 0 and pos_context == .import_string_literal) {
        if (handle.associated_build_file) |uri| {
            const build_file = store.build_files.get(uri).?;
            try completions.ensureUnusedCapacity(arena, build_file.config.packages.len);

            for (build_file.config.packages) |pkg| {
                completions.putAssumeCapacity(.{
                    .label = pkg.name,
                    .kind = .Module,
                }, {});
            }
        }
    }

    return completions.keys();
}

pub fn completionAtIndex(server: *Server, source_index: usize, handle: *const DocumentStore.Handle) error{OutOfMemory}!?types.CompletionList {
    const at_line_start = offsets.lineSliceUntilIndex(handle.tree.source, source_index).len == 0;
    if (at_line_start) {
        var completions = std.ArrayListUnmanaged(types.CompletionItem){};
        try populateSnippedCompletions(server.arena.allocator(), &completions, &snipped_data.top_level_decl_data, server.config.*);

        return .{ .isIncomplete = false, .items = completions.items };
    }

    const pos_context = try Analyser.getPositionContext(server.arena.allocator(), handle.text, source_index, false);

    const maybe_completions = switch (pos_context) {
        .builtin => try completeBuiltin(server),
        .var_access, .empty => try completeGlobal(server, source_index, handle),
        .field_access => |loc| try completeFieldAccess(server, handle, source_index, loc),
        .global_error_set => try completeError(server, handle),
        .enum_literal => try completeDot(server, handle, source_index),
        .label => try completeLabel(server, source_index, handle),
        .import_string_literal,
        .cinclude_string_literal,
        .embedfile_string_literal,
        => blk: {
            if (!server.config.enable_import_embedfile_argument_completions) break :blk null;

            break :blk completeFileSystemStringLiteral(server.arena.allocator(), server.document_store, handle.*, pos_context) catch |err| {
                log.err("failed to get file system completions: {}", .{err});
                return null;
            };
        },
        else => null,
    };

    const completions = maybe_completions orelse return null;

    // The cursor is in the middle of a word or before a @, so we can replace
    // the remaining identifier with the completion instead of just inserting.
    // TODO Identify function call/struct init and replace the whole thing.
    const lookahead_context = try Analyser.getPositionContext(server.arena.allocator(), handle.text, source_index, true);
    if (server.client_capabilities.supports_apply_edits and
        pos_context != .import_string_literal and
        pos_context != .cinclude_string_literal and
        pos_context != .embedfile_string_literal and
        pos_context.loc() != null and
        lookahead_context.loc() != null and
        pos_context.loc().?.end != lookahead_context.loc().?.end)
    {
        var end = lookahead_context.loc().?.end;
        while (end < handle.text.len and (std.ascii.isAlphanumeric(handle.text[end]) or handle.text[end] == '"')) {
            end += 1;
        }

        const replaceLoc = offsets.Loc{ .start = lookahead_context.loc().?.start, .end = end };
        const replaceRange = offsets.locToRange(handle.text, replaceLoc, server.offset_encoding);

        for (completions) |*item| {
            item.textEdit = .{
                .TextEdit = .{
                    .newText = item.insertText orelse item.label,
                    .range = replaceRange,
                },
            };
        }
    }

    // truncate completions
    for (completions) |*item| {
        if (item.detail) |det| {
            if (det.len > server.config.max_detail_length) {
                item.detail = det[0..server.config.max_detail_length];
            }
        }
    }

    // TODO: config for sorting rule?
    for (completions) |*c| {
        const prefix = kindToSortScore(c.kind.?) orelse continue;

        c.sortText = try std.fmt.allocPrint(server.arena.allocator(), "{s}{s}", .{ prefix, c.label });
    }

    return .{ .isIncomplete = false, .items = completions };
}

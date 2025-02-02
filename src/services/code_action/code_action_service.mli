(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

val kind_is_supported : Lsp.CodeActionKind.t list option -> bool

type text_edits = {
  title: string;
  edits: Lsp.TextEdit.t list;
  from: string;
}

val layout_options : Options.t -> Js_layout_generator.opts

val text_edits_of_import :
  options:Options.t ->
  reader:State_reader.t ->
  src_dir:string option ->
  ast:(Loc.t, Loc.t) Flow_ast.Program.t ->
  Export_index.kind ->
  string ->
  Export_index.source ->
  text_edits option

type ast_transform =
  cx:Context.t ->
  file_sig:File_sig.t ->
  ast:(Loc.t, Loc.t) Flow_ast.Program.t ->
  typed_ast:(ALoc.t, ALoc.t * Type.t) Flow_ast.Program.t ->
  Loc.t ->
  (Loc.t, Loc.t) Flow_ast.Program.t option

type ast_transform_of_error = {
  title: string;
  diagnostic_title: string;
  transform: ast_transform;
  target_loc: Loc.t;
}

val untyped_ast_transform :
  ((Loc.t, Loc.t) Flow_ast.Program.t -> Loc.t -> (Loc.t, Loc.t) Flow_ast.Program.t) -> ast_transform

val ast_transforms_of_error : ?loc:Loc.t -> Loc.t Error_message.t' -> ast_transform_of_error list

val code_actions_at_loc :
  options:Options.t ->
  lsp_init_params:Lsp.Initialize.params ->
  env:ServerEnv.env ->
  reader:Parsing_heaps.Reader.reader ->
  cx:Context.t ->
  file_sig:File_sig.t ->
  tolerable_errors:File_sig.tolerable_error list ->
  file_contents:string ->
  ast:(Loc.t, Loc.t) Flow_ast.Program.t ->
  typed_ast:(ALoc.t, ALoc.t * Type.t) Flow_ast.Program.t ->
  scope_info:Scope_api.With_Loc.info ->
  parse_errors:(Loc.t * Parse_error.t) Base.List.t ->
  diagnostics:Lsp.PublishDiagnostics.diagnostic list ->
  only:Lsp.CodeActionKind.t list option ->
  uri:Lsp.DocumentUri.t ->
  loc:Loc.t ->
  (Lsp.CodeAction.command_or_action list, string) result

val autofix_imports :
  options:Options.t ->
  env:ServerEnv.env ->
  reader:Parsing_heaps.Reader.reader ->
  cx:Context.t ->
  ast:(Loc.t, Loc.t) Flow_ast.Program.t ->
  uri:Lsp.DocumentUri.t ->
  Lsp.TextEdit.t list

val autofix_exports :
  options:Options.t ->
  env:ServerEnv.env ->
  profiling:Profiling_js.running ->
  file_key:File_key.t ->
  file_content:string ->
  (Replacement_printer.patch * string list, string) result

val autofix_missing_local_annot :
  options:Options.t ->
  env:ServerEnv.env ->
  profiling:Profiling_js.running ->
  file_key:File_key.t ->
  file_content:string ->
  (Replacement_printer.patch, string) result

val insert_type :
  options:Options.t ->
  env:ServerEnv.env ->
  profiling:Profiling_js.running ->
  file_key:File_key.t ->
  file_content:string ->
  target:Loc.t ->
  omit_targ_defaults:bool ->
  location_is_strict:bool ->
  ambiguity_strategy:Autofix_options.ambiguity_strategy ->
  (Replacement_printer.patch, string) result

val organize_imports :
  options:Options.t -> ast:(Loc.t, Loc.t) Flow_ast.Program.t -> Lsp.TextEdit.t list

module For_tests : sig
  val path_of_modulename :
    node_resolver_dirnames:string list ->
    reader:State_reader.t ->
    string option ->
    File_key.t ->
    string option ->
    string option
end

(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** Sort and dedup by loc.

    This will have to be revisited if we ever need to report multiple ref kinds for
    a single location. *)
let sort_and_dedup refs =
  Base.List.dedup_and_sort ~compare:(fun (_, loc1) (_, loc2) -> Loc.compare loc1 loc2) refs

let local_variable_refs scope_info loc =
  match VariableFindRefs.local_find_refs scope_info [loc] with
  | None -> (None, loc)
  | Some (var_refs, local_def_loc) -> (Some var_refs, local_def_loc)

let find_local_refs ~reader ~options ~file_key ~parse_artifacts ~typecheck_artifacts ~line ~col =
  let open Base.Result.Let_syntax in
  let loc = Loc.cursor (Some file_key) line col in
  let ast_info =
    match parse_artifacts with
    | Types_js_types.Parse_artifacts { ast; file_sig; docblock; _ } -> (ast, file_sig, docblock)
  in
  (* Start by running local variable find references *)
  let (Types_js_types.Parse_artifacts { ast; _ }) = parse_artifacts in
  let scope_info =
    Scope_builder.program ~enable_enums:(Options.enums options) ~with_types:true ast
  in
  let (var_refs, loc) = local_variable_refs scope_info loc in
  let%bind refs =
    match var_refs with
    | Some _ -> Ok var_refs
    | None -> PropertyFindRefs.find_local_refs ~reader file_key ast_info typecheck_artifacts loc
  in
  let refs = Base.Option.map ~f:(fun refs -> sort_and_dedup refs) refs in
  Ok refs

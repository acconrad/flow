(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** stops walking the tree *)
exception Found

(** This type is distinct from the one raised by the searcher because
  it would never make sense for the searcher to raise LocNotFound *)
type ('M, 'T) result =
  | OwnDef of 'M
  | Request of ('M, 'T) Get_def_request.t
  | Empty of string
  | LocNotFound

(** Determines if the given expression is a [require()] call, or a member expression
  containing one, like [require('foo').bar]. *)
let rec is_require ~is_legit_require expr =
  let open Flow_ast.Expression in
  match expr with
  | (_, Member { Member._object; _ }) -> is_require ~is_legit_require _object
  | ( _,
      Call
        {
          Call.callee = (_, Identifier (_, { Flow_ast.Identifier.name = "require"; _ }));
          arguments = (_, { ArgList.arguments = Expression (source_annot, _) :: _; _ });
          _;
        }
    )
    when is_legit_require source_annot ->
    true
  | _ -> false

let annot_of_jsx_name =
  let open Flow_ast.JSX in
  function
  | Identifier (annot, _)
  | NamespacedName (_, NamespacedName.{ name = (annot, _); _ })
  | MemberExpression (_, MemberExpression.{ property = (annot, _); _ }) ->
    annot

class ['M, 'T] searcher
  ~(is_legit_require : 'T -> bool) ~(covers_target : 'M -> bool) ~(loc_of_annot : 'T -> 'M) =
  let annot_covers_target annot = covers_target (loc_of_annot annot) in
  object (this)
    inherit ['M, 'T, 'M, 'T] Flow_polymorphic_ast_mapper.mapper as super

    val mutable in_require_declarator = false

    val mutable found_loc_ = LocNotFound

    method found_loc = found_loc_

    method with_in_require_declarator value f =
      let was_in_require_declarator = in_require_declarator in
      in_require_declarator <- value;
      let result = f () in
      in_require_declarator <- was_in_require_declarator;
      result

    method on_loc_annot (x : 'M) = x

    method on_type_annot (x : 'T) = x

    method own_def : 'a. 'M -> 'a =
      fun x ->
        found_loc_ <- OwnDef x;
        raise Found

    method found_empty : 'a. string -> 'a =
      fun x ->
        found_loc_ <- Empty x;
        raise Found

    method request : 'a. ('M, 'T) Get_def_request.t -> 'a =
      fun x ->
        found_loc_ <- Request x;
        raise Found

    method! variable_declarator
        ~kind ((_, { Flow_ast.Statement.VariableDeclaration.Declarator.id; init }) as x) =
      (* If a variable declarator's initializer contains `require()`, then we want to jump
         through it into the imported module. To do this, we set the `in_require_declarator`
         flag, which we use when we visit the id, in lieu of parent pointers. *)
      let (id_annot, _) = id in
      let has_require =
        match init with
        | Some init when is_require ~is_legit_require init && annot_covers_target id_annot -> true
        | _ -> false
      in
      this#with_in_require_declarator has_require (fun () -> super#variable_declarator ~kind x)

    method! import_source source_annot lit =
      if annot_covers_target source_annot then this#request (Get_def_request.Type source_annot);
      super#import_source source_annot lit

    method! import_named_specifier ~import_kind decl =
      let open Flow_ast.Statement.ImportDeclaration in
      let { local; remote = (remote_annot, _); kind } = decl in
      ( if
        annot_covers_target remote_annot
        || Base.Option.exists local ~f:(fun (local_annot, _) -> annot_covers_target local_annot)
      then
        match (kind, import_kind) with
        | (Some ImportTypeof, _)
        | (_, ImportTypeof) ->
          this#request (Get_def_request.Typeof remote_annot)
        | _ -> this#request (Get_def_request.Type remote_annot)
      );
      decl

    method! import_default_specifier ~import_kind decl =
      let open Flow_ast.Statement.ImportDeclaration in
      let (annot, _) = decl in
      ( if annot_covers_target annot then
        match import_kind with
        | ImportTypeof -> this#request (Get_def_request.Typeof annot)
        | _ -> this#request (Get_def_request.Type annot)
      );
      decl

    method! import_namespace_specifier ~import_kind loc id =
      let open Flow_ast.Statement.ImportDeclaration in
      let (annot, _) = id in
      ( if covers_target loc then
        match import_kind with
        | ImportTypeof -> this#request (Get_def_request.Typeof annot)
        | _ -> this#request (Get_def_request.Type annot)
      );
      id

    method! export_source source_annot lit =
      if annot_covers_target source_annot then this#request (Get_def_request.Type source_annot);
      super#export_source source_annot lit

    method! member expr =
      let open Flow_ast.Expression.Member in
      let { _object; property; comments = _ } = expr in
      begin
        match property with
        | PropertyIdentifier (annot, { Flow_ast.Identifier.name; _ }) when annot_covers_target annot
          ->
          let (obj_annot, _) = _object in
          let force_instance = Flow_ast_utils.is_super_member_access expr in
          let result =
            Get_def_request.(Member { prop_name = name; object_type = obj_annot; force_instance })
          in
          this#request result
        | _ -> ()
      end;
      super#member expr

    method! t_identifier ((loc, { Flow_ast.Identifier.name; _ }) as id) =
      if annot_covers_target loc then this#request (Get_def_request.Identifier { name; loc });
      super#t_identifier id

    method! jsx_opening_element elt =
      let open Flow_ast.JSX in
      let (_, Opening.{ name = component_name; attributes; _ }) = elt in
      List.iter
        (function
          | Opening.Attribute
              ( _,
                {
                  Attribute.name =
                    Attribute.Identifier (annot, { Identifier.name = attribute_name; comments = _ });
                  _;
                }
              )
            when annot_covers_target annot ->
            let loc = loc_of_annot annot in
            this#request
              (Get_def_request.JsxAttribute
                 { component_t = annot_of_jsx_name component_name; name = attribute_name; loc }
              )
          | _ -> ())
        attributes;
      super#jsx_opening_element elt

    method! jsx_element_name_identifier
        ((annot, { Flow_ast.JSX.Identifier.name; comments = _ }) as id) =
      if annot_covers_target annot then
        this#request (Get_def_request.Identifier { name; loc = annot });
      super#jsx_element_name_identifier id

    method! pattern ?kind ((pat_annot, p) as pat) =
      let open Flow_ast.Pattern in
      ( if not in_require_declarator then
        match p with
        | Object { Object.properties; _ } ->
          List.iter
            Object.(
              function
              | Property (_, { Property.key; _ }) -> begin
                match key with
                | Property.Literal
                    (loc, { Flow_ast.Literal.value = Flow_ast.Literal.String name; _ })
                  when covers_target loc ->
                  this#request
                    Get_def_request.(
                      Member { prop_name = name; object_type = pat_annot; force_instance = false }
                    )
                | Property.Identifier (id_annot, { Flow_ast.Identifier.name; _ })
                  when annot_covers_target id_annot ->
                  this#request
                    Get_def_request.(
                      Member { prop_name = name; object_type = pat_annot; force_instance = false }
                    )
                | _ -> ()
              end
              | _ -> ()
            )
            properties
        | _ -> ()
      );
      super#pattern ?kind pat

    method! pattern_identifier ?kind (annot, name) =
      if kind != None && annot_covers_target annot then
        if in_require_declarator then
          this#request (Get_def_request.Type annot)
        else
          this#own_def (loc_of_annot annot);
      super#pattern_identifier ?kind (annot, name)

    method! expression (annot, expr) =
      let open Flow_ast in
      let open Expression in
      if annot_covers_target annot then
        match expr with
        | Literal Literal.{ value = String _; _ } -> this#found_empty "string"
        | Literal Literal.{ value = Number _; _ } -> this#found_empty "number"
        | Literal Literal.{ value = BigInt _; _ } -> this#found_empty "bigint"
        | Literal Literal.{ value = Boolean _; _ } -> this#found_empty "boolean"
        | Literal Literal.{ value = Null; _ } -> this#found_empty "null"
        | Literal Literal.{ value = RegExp _; _ } -> this#found_empty "regexp"
        | Call
            {
              Call.callee = (_, Identifier (_, { Identifier.name = "require"; _ }));
              arguments =
                ( _,
                  {
                    ArgList.arguments =
                      [Expression (source_annot, Literal Literal.{ value = String _; _ })];
                    comments = _;
                  }
                );
              _;
            }
          when is_legit_require source_annot ->
          this#request (Get_def_request.Type annot)
        | _ -> super#expression (annot, expr)
      else
        (* it is tempting to not recurse here, but comments are not included in
           `annot`, so we have to dig into each child to visit their `comments`
           fields. *)
        super#expression (annot, expr)

    method! type_ (annot, t) =
      if annot_covers_target annot then
        let open! Flow_ast.Type in
        match t with
        | Any _
        | Mixed _
        | Empty _
        | Void _
        | Null _
        | Symbol _
        | Number _
        | BigInt _
        | String _
        | Boolean _
        | Exists _
        | Unknown _
        | Never _
        | Undefined _ ->
          this#found_empty "type literal"
        | Nullable _
        | Array _
        | Conditional _
        | Infer _
        | Typeof _
        | Keyof _
        | ReadOnly _
        | Function _
        | Component _
        | Object _
        | Interface _
        | Generic _
        | IndexedAccess _
        | OptionalIndexedAccess _
        | Union _
        | Intersection _
        | Tuple _
        | StringLiteral _
        | NumberLiteral _
        | BigIntLiteral _
        | BooleanLiteral _ ->
          super#type_ (annot, t)
      else
        (* it is tempting to not recurse here, but comments are not included in
           `annot`, so we have to dig into each child to visit their `comments`
           fields. *)
        super#type_ (annot, t)

    method! module_ref_literal mref =
      let { Flow_ast.Literal.require_out; _ } = mref in
      if annot_covers_target require_out then
        this#request (Get_def_request.Type require_out)
      else
        super#module_ref_literal mref

    (* object keys would normally hit this#t_identifier; this circumvents that. *)
    method! object_key_identifier id =
      let (annot, _) = id in
      if annot_covers_target annot then this#own_def (loc_of_annot annot);
      id

    (* for object properties using the shorthand {variableName} syntax,
     * process the value before the key so that the explicit-non-find in this#object_key_identifier
     * doesn't make us miss the variable *)
    method! object_property prop =
      let open Flow_ast.Expression.Object.Property in
      (match prop with
      | (_, Init { shorthand = true; value; _ }) -> ignore (this#expression value)
      | _ -> ());
      super#object_property prop

    method! new_ expr =
      let { Flow_ast.Expression.New.callee = (_, callee); _ } = expr in
      begin
        match callee with
        | Flow_ast.Expression.Identifier (annot, _) when annot_covers_target annot ->
          this#request
            Get_def_request.(
              Member
                {
                  prop_name = "constructor";
                  object_type = annot;
                  (* In `new Foo()`, the type of Foo is ThisClassT(InstanceT).
                     We use force_instance to force the normalizer to inspect
                     the InstanceT instead of the static properties of the class *)
                  force_instance = true;
                }
            )
        | _ -> ()
      end;
      super#new_ expr

    method! comment c =
      let (loc, _) = c in
      if covers_target loc then this#found_empty "comment";
      c

    method! t_comment c =
      let (annot, _) = c in
      if annot_covers_target annot then this#found_empty "comment";
      c

    method! template_literal_element e =
      let (loc, _) = e in
      if covers_target loc then this#found_empty "template";
      e

    method! jsx_attribute_value_literal lit =
      let (annot, _) = lit in
      if annot_covers_target annot then this#found_empty "jsx attribute literal";
      lit

    method! jsx_child child =
      let (loc, c) = child in
      match c with
      | Flow_ast.JSX.Text _ when covers_target loc -> this#found_empty "jsx text"
      | _ -> super#jsx_child child
  end

let process_location ~loc_of_annot ~ast ~is_legit_require ~covers_target =
  let searcher = new searcher ~loc_of_annot ~is_legit_require ~covers_target in
  (try ignore (searcher#program ast) with
  | Found -> ());
  searcher#found_loc

let process_location_in_ast ~ast ~is_legit_require loc =
  let loc_of_annot loc = loc in
  let covers_target test_loc = Reason.in_range loc test_loc in
  process_location ~loc_of_annot ~is_legit_require ~ast ~covers_target

let process_location_in_typed_ast ~typed_ast ~is_legit_require loc =
  let loc_of_annot (loc, _) = loc in
  let covers_target test_loc = Reason.in_range loc (ALoc.to_loc_exn test_loc) in
  process_location ~loc_of_annot ~is_legit_require ~ast:typed_ast ~covers_target

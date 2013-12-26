(*pp camlp4o -I `ocamlfind query piqi.syntax` pa_labelscope.cmo pa_openin.cmo *)
(*
   Copyright 2009, 2010, 2011, 2012, 2013 Anton Lavrik

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*)


(*
 * This module generates default values for OCaml types generated by
 * Piqic_ocaml_types
 *
 * The generated default_* functions return minimal serializable values of Piqi
 * types
 *
 * CAVEAT: the logic is very primitive and it doesn't guarantee that default
 * variant values are finite
 *)

module C = Piqic_common
open C
open Iolist


let gen_type context typename =
  let import, parent_piqi, typedef = resolve_typename_ext context typename in
  let parent_mod = C.gen_parent_mod import in
  parent_mod ^^ ios "default_" ^^ ios (C.typedef_mlname typedef) ^^ ios "()"


let gen_int piqi_type wire_type =
  let wire_type =
    match wire_type with
      | Some x -> x
      | None ->
          C.get_default_wire_type piqi_type
  in
  let f =
    match wire_type with
      | `varint -> Piqirun.int64_to_varint
      | `zigzag_varint -> Piqirun.int64_to_zigzag_varint
      | `fixed32 -> Piqirun.int64_to_fixed32
      | `fixed64 -> Piqirun.int64_to_fixed64
      | `signed_varint -> Piqirun.int64_to_signed_varint
      | `signed_fixed32 -> Piqirun.int64_to_signed_fixed32
      | `signed_fixed64 -> Piqirun.int64_to_signed_fixed64
      | `block ->
          assert false
  in
  let buf = f (-1) 0L in
  Piqirun.to_string buf


let gen_builtin_type context piqi_type ocaml_type wire_type =
  match piqi_type with
    | `any ->
        if context.is_self_spec
        then ios "default_any ()"
        else ios "Piqi_piqi.default_any ()"
    | `string | `binary ->
        ios "\"\""
    | `bool ->
        ios "false"
    | `float ->
        ios "0.0"
    | `int ->
        match ocaml_type with
          | None | Some "int" -> ios "0"
          | Some "int32" -> ios "0l"
          | Some "int64" -> ios "0L"
          | _ ->
              (* XXX: this is the most generic way to handle it; accounting for
               * potential future extensions *)
              let typename = C.gen_builtin_type_name piqi_type ?ocaml_type in
              let wire_typename = C.gen_wire_type_name piqi_type wire_type in
              let default = gen_int piqi_type wire_type in
              let default_expr = iod " " [
                ios "(Piqirun.parse_default"; ioq (String.escaped default); ios ")";
              ]
              in
              iol [
                ios "Piqirun.";
                ios typename;
                ios "_of_";
                ios wire_typename;
                default_expr;
              ]


(* copy-pasted Piqic_erlang_out.gen_alias_type -- not sure how to avoid this *)
let rec gen_alias_type ?wire_type context a =
  let open A in
  match a.typename with
    | None ->  (* this is a built-in type, so piqi_type must be defined *)
        let piqi_type = some_of a.piqi_type in
        gen_builtin_type context piqi_type a.ocaml_type wire_type
    | Some typename ->
        let parent_piqi, typedef = resolve_typename context typename in
        match typedef with
          | `alias a when wire_type <> None ->
              (* need special handing in case when higher-level alias overrides
               * protobuf_wire_type *)
              let context = C.switch_context context parent_piqi in
              gen_alias_type context a ?wire_type
          | _ ->
              gen_type context typename


let gen_field_cons context rname f =
  let open Field in
  let fname = C.mlname_of_field context f in
  let ffname = (* fully-qualified field name *)
    iol [ios rname; ios "."; ios fname]
  in 
  let value =
    match f.mode, f.default with
      | `required, _ -> gen_type context (some_of f.typename)
      | `optional, _ when f.typename = None -> ios "false" (* flag *)
      | `optional, Some piqi_any when not f.ocaml_optional ->
          let pb = some_of piqi_any.Any#protobuf in
          let default_str = String.escaped pb in
          let typename = some_of f.typename in
          iod " " [
            Piqic_ocaml_in.gen_type context typename;
              ios "(Piqirun.parse_default"; ioq default_str; ios ")";
          ]
      | `optional, _ -> ios "None"
      | `repeated, _ ->
          if f.ocaml_array
          then ios "[||]"
          else ios "[]"
  in
  (* field construction code *)
  iod " " [ ffname; ios "="; value; ios ";" ]


let gen_record context r =
  (* fully-qualified capitalized record name *)
  let rname = String.capitalize (some_of r.R#ocaml_name) in
  (* order fields by are by their integer codes *)
  let fields = List.sort (fun a b -> compare a.F#code b.F#code) r.R#field in
  let fconsl = (* field constructor list *)
    if fields <> []
    then List.map (gen_field_cons context rname) fields
    else [ios rname; ios "."; ios "_dummy = ()"]
  in (* fake_<record-name> function delcaration *)
  iod " " [
    ios "default_" ^^ ios (some_of r.R#ocaml_name); ios "() =";
    ios "{"; iol fconsl; ios "}";
  ]


let gen_enum e =
  let open Enum in
  (* there must be at least one option *)
  let const = List.hd e.option in
  iod " " [
    ios "default_" ^^ ios (some_of e.ocaml_name); ios "() =";
      C.gen_pvar_name (some_of const.O#ocaml_name)
  ]


let gen_option context varname o =
  let open Option in
  let name = C.mlname_of_option context o in
  match o.typename with
    | None ->  (* this is a flag, i.e. option without a type *)
        C.gen_pvar_name name
    | Some typename ->
        let import, parent_piqi, typedef = resolve_typename_ext context typename in
        match o.ocaml_name, typedef with
          | None, `variant _ | None, `enum _ ->
              iod " " [
                ios "("; gen_type context typename; ios ":>"; ios varname; ios ")"
              ]
          | _ ->
              iod " " [
                C.gen_pvar_name name;
                ios "("; gen_type context typename; ios ")";
              ]


let gen_variant context v =
  let open Variant in
  let name = some_of v.ocaml_name in
  (* there must be at least one option *)
  let opt = gen_option context name (List.hd v.option) in
  iod " " [
    ios "default_" ^^ ios name; ios "() ="; opt;
  ]


let gen_alias context a =
  let open Alias in
  (* TODO: handle a new ocaml_default property the same way we do in
   * piqic-erlang *)
  iod " " [
    ios "default_" ^^ ios (some_of a.ocaml_name); ios "() =";
    C.gen_convert_value a.typename a.ocaml_type "_of_" (gen_alias_type context a);
  ]


let gen_list l =
  let open L in
  iod " " [
    ios "default_" ^^ ios (some_of l.ocaml_name); ios "() = ";
    if l.ocaml_array
    then ios "[||]"
    else ios "[]";
  ]


let gen_typedef context typedef =
  match typedef with
    | `record t -> gen_record context t
    | `variant t -> gen_variant context t
    | `enum t -> gen_enum t
    | `list t -> gen_list t
    | `alias t -> gen_alias context t


let gen_typedefs context typedefs =
  if typedefs = []
  then iol []
  else 
    let defs = List.map (gen_typedef context) typedefs in
    iol [
      ios "let rec "; iod " and " defs;
      eol;
    ]


let gen_piqi context =
  gen_typedefs context context.piqi.P#typedef


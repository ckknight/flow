module Ast = Spider_monkey_ast
module Anno = Type_annotation
module Flow = Flow_js
module Utils = Utils_js

open Reason_js
open Type
open Destructuring

type binding = string * Type.t * Loc.t
type param =
  | Simple of Type.t * binding
  | Complex of Type.t * binding list
  | Rest of Type.t * binding
type t = {
  list: param list;
  defaults: Ast.Expression.t Default.t SMap.t;
}

let empty = {
  list = [];
  defaults = SMap.empty
}

let add cx type_params_map params pattern default =
  Ast.Pattern.(match pattern with
  | loc, Identifier (_, { Ast.Identifier.name; typeAnnotation; optional }) ->
    let reason = mk_reason (Utils.spf "parameter `%s`" name) loc in
    let t = Anno.mk_type_annotation cx type_params_map reason typeAnnotation
    in (match default with
    | None ->
      let t =
        if optional
        then OptionalT t
        else t
      in
      Hashtbl.replace (Context.type_table cx) loc t;
      let binding = name, t, loc in
      let list = Simple (t, binding) :: params.list in
      { params with list }
    | Some expr ->
      (* TODO: assert (not optional) *)
      let binding = name, t, loc in
      { list = Simple (OptionalT t, binding) :: params.list;
        defaults = SMap.add name (Default.Expr expr) params.defaults })
  | loc, _ ->
    let reason = mk_reason "destructuring" loc in
    let t = type_of_pattern pattern
      |> Anno.mk_type_annotation cx type_params_map reason in
    let default = Option.map default Default.expr in
    let bindings = ref [] in
    let defaults = ref params.defaults in
    pattern |> destructuring cx t None default (fun _ loc name default t ->
      Hashtbl.replace (Context.type_table cx) loc t;
      bindings := (name, t, loc) :: !bindings;
      Option.iter default ~f:(fun default ->
        defaults := SMap.add name default !defaults
      )
    );
    let t = match default with
      | Some _ -> OptionalT t
      | None -> t (* TODO: assert (not optional) *)
    in
    { list = Complex (t, !bindings) :: params.list;
      defaults = !defaults })

let add_rest cx type_params_map params =
  function loc, { Ast.Identifier.name; typeAnnotation; _ } ->
    let reason = mk_reason (Utils.spf "rest parameter `%s`" name) loc in
    let t = Anno.mk_type_annotation cx type_params_map reason typeAnnotation
    in { params with
      list = Rest (Anno.mk_rest cx t, (name, t, loc)) :: params.list
    }

let mk cx type_params_map {Ast.Function.params; defaults; rest; _} =
  let defaults =
    if defaults = [] && params <> []
    then List.map (fun _ -> None) params
    else defaults
  in
  let params = List.fold_left2 (add cx type_params_map) empty params defaults in
  match rest with
  | Some ident -> add_rest cx type_params_map params ident
  | None -> params


let names params =
  params.list |> List.rev |> List.map (function
    | Simple (_, (name, _, _))
    | Rest (_, (name, _, _)) -> name
  | Complex _ -> "_")

let tlist params =
  params.list |> List.rev |> List.map (function
    | Simple (t, _)
    | Complex (t, _)
    | Rest (t, _) -> t)

let iter f params =
  params.list |> List.rev |> List.iter (function
    | Simple (_, b)
    | Rest (_, b) -> f b
    | Complex (_, bs) -> List.iter f bs)

let with_default name f params =
  match SMap.get name params.defaults with
  | Some t -> f t
  | None -> ()

let subst_binding cx map (name, t, loc) = (name, Flow.subst cx map t, loc)

let subst cx map params =
  let list = params.list |> List.map (function
    | Simple (t, b) ->
      Simple (Flow.subst cx map t, subst_binding cx map b)
    | Complex (t, bs) ->
      Complex (Flow.subst cx map t, List.map (subst_binding cx map) bs)
    | Rest (t, b) ->
      Rest (Flow.subst cx map t, subst_binding cx map b)) in
  { params with list }

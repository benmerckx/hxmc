(* Inventory of the library values a set of typed trees (.cmt) uses.
   Every identifier, constructor, record label and functor application whose
   declaration lies outside the compiled sources is counted, keyed by its
   declaring library file and its path inside that file. Output: TSV lines
   kind<TAB>library-file<TAB>name<TAB>count<TAB>example-site.
   Build: ocamlfind ocamlc -package compiler-libs.common -linkpkg inventory.ml *)
open Typedtree

let counts : (string * string * string, int ref * string) Hashtbl.t = Hashtbl.create 4096
let roots = ref []

(* A declaration is the project's when its file exists under the source root
   (libraries are built elsewhere; their paths are relative to their own roots). *)
let local_cache = Hashtbl.create 64
let local file =
  file = "" || file = "_none_" ||
  match Hashtbl.find_opt local_cache file with
  | Some b -> b
  | None -> let b = List.exists (fun r -> Sys.file_exists (Filename.concat r file)) !roots in Hashtbl.replace local_cache file b; b

let site (l : Location.t) =
  let p = l.loc_start in Printf.sprintf "%s:%d" p.pos_fname p.pos_lnum

let bump kind lib name where =
  let k = (kind, lib, name) in
  match Hashtbl.find_opt counts k with
  | Some (r, _) -> incr r
  | None -> Hashtbl.replace counts k (ref 1, where)

(* The name of a value inside its library: the path as written, with the
   leading module aliases (Stdlib., ExtLib., Stdlib__) dropped; for an
   identifier of a functor's result or a local alias (StringMap.find), the
   declaring file's module and the last component. *)
let lib_of_file f =
  let b = Filename.remove_extension (Filename.basename f) in
  let b = match String.index_opt b '_' with
    | Some i when String.length b > i + 1 && b.[i + 1] = '_' -> String.sub b (i + 2) (String.length b - i - 2)
    | _ -> b in
  String.capitalize_ascii b

let rec strip = function
  | "ExtLib" :: m :: rest -> ("Ext" ^ m) :: m :: rest
  | "Stdlib" :: (_ :: _ as rest) -> strip rest
  | m :: rest when String.length m > 8 && String.sub m 0 8 = "Stdlib__" ->
    String.capitalize_ascii (String.sub m 8 (String.length m - 8)) :: rest
  | l -> l

let rec components = function
  | Path.Pident i -> [Ident.name i]
  | Path.Pdot (p, s) -> components p @ [s]
  | Path.Papply (a, _) -> components a
  | Path.Pextra_ty (p, _) -> components p

let global_head p = Ident.global (Path.head p) || Ident.is_predef (Path.head p)

let name_of path decl_file =
  let file_mod = lib_of_file decl_file in
  let c = components path in
  if global_head path then begin
    match strip c with
    | [x] -> file_mod ^ "." ^ x
    | l -> String.concat "." l
  end else file_mod ^ ".(" ^ String.concat "." c ^ ")"

let value path (vd : Types.value_description) l =
  let f = vd.val_loc.loc_start.pos_fname in
  if not (local f) then begin
    let kind = match vd.val_kind with Types.Val_prim _ -> "value" | _ -> "value" in
    bump kind f (name_of path f) (site l)
  end

let project_modules = Hashtbl.create 512

let constr (cd : Types.constructor_description) l =
  let f = cd.cstr_loc.loc_start.pos_fname in
  match cd.cstr_tag with
  | Cstr_extension (p, _) ->
    let h = Path.head p in
    if Ident.is_predef h then bump "exception" "predef" cd.cstr_name (site l)
    else if Ident.global h && not (Hashtbl.mem project_modules (Ident.name h)) then
      bump "exception" f (String.concat "." (strip (components p))) (site l)
  | _ when not (local f) || f = "_none_" ->
      let ty = match Types.get_desc cd.cstr_res with
        | Tconstr (p, _, _) -> String.concat "." (strip (components p)) | _ -> "?" in
      if ty <> "bool" && ty <> "unit" && ty <> "list" && ty <> "option" then
        bump "constructor" (if f = "" || f = "_none_" then "predef" else f) (ty ^ "." ^ cd.cstr_name) (site l)
  | _ -> ()

let label (ld : Types.label_description) l =
  let f = ld.lbl_loc.loc_start.pos_fname in
  if not (local f) then
    let ty = match Types.get_desc ld.lbl_res with
      | Tconstr (p, _, _) -> String.concat "." (strip (components p)) | _ -> "?" in
    bump "field" f (ty ^ "." ^ ld.lbl_name) (site l)

let iterator =
  let open Tast_iterator in
  let expr sub e =
    (match e.exp_desc with
     | Texp_ident (p, _, vd) -> value p vd e.exp_loc
     | Texp_construct (_, cd, _) -> constr cd e.exp_loc
     | Texp_field (_, _, ld) -> label ld e.exp_loc
     | Texp_setfield (_, _, ld, _) -> label ld e.exp_loc
     | Texp_record { fields; _ } ->
       Array.iter (fun (ld, d) -> match d with Overridden _ -> label ld e.exp_loc | Kept _ -> ()) fields
     | _ -> ());
    default_iterator.expr sub e in
  let pat (type k) sub (p : k general_pattern) =
    (match p.pat_desc with
     | Tpat_construct (_, cd, _, _) -> constr cd p.pat_loc
     | Tpat_record (fields, _) -> List.iter (fun (_, ld, _) -> label ld p.pat_loc) fields
     | _ -> ());
    default_iterator.pat sub p in
  let module_expr sub m =
    (match m.mod_desc with
     | Tmod_apply (f, _, _) | Tmod_apply_unit f ->
       let rec ident m = match m.mod_desc with
         | Tmod_ident (p, _) -> Some p
         | Tmod_constraint (m, _, _, _) -> ident m
         | _ -> None in
       (match ident f with
        | Some p when Ident.global (Path.head p) && not (Hashtbl.mem project_modules (Ident.name (Path.head p))) ->
          bump "functor" "" (String.concat "." (strip (components p))) (site m.mod_loc)
        | _ -> ())
     | _ -> ());
    default_iterator.module_expr sub m in
  let structure_item sub si =
    (match si.str_desc with
     | Tstr_primitive vd ->
       List.iter (fun prim -> bump "external" "" prim (site vd.val_loc)) vd.val_prim
     | _ -> ());
    default_iterator.structure_item sub si in
  { default_iterator with expr; pat; module_expr; structure_item }

let () =
  let files = ref [] in
  Arg.parse ["-root", Arg.String (fun r -> roots := r :: !roots), "a root of the compiled sources (and of generated ones)"]
    (fun f -> files := f :: !files) "inventory [-root dir]... file.cmt...";
  let cmts = List.rev_map (fun file -> Cmt_format.read_cmt file) !files in
  List.iter (fun (cmt : Cmt_format.cmt_infos) ->
    Hashtbl.replace project_modules cmt.cmt_modname ();
    match String.index_opt cmt.cmt_modname '_' with
    | Some i when i + 1 < String.length cmt.cmt_modname && cmt.cmt_modname.[i + 1] = '_' ->
      Hashtbl.replace project_modules (String.sub cmt.cmt_modname 0 i) ()
    | _ -> ()) cmts;
  List.iter (fun (cmt : Cmt_format.cmt_infos) ->
    match cmt.cmt_annots with
    | Implementation s -> iterator.structure iterator s
    | _ -> ()) cmts;
  Hashtbl.iter (fun (kind, lib, name) (n, where) ->
    Printf.printf "%s\t%s\t%s\t%d\t%s\n" kind lib name !n where) counts

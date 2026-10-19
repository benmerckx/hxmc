(* ml2hx frontend: OCaml typed trees (.cmt, or .ml typed here) -> JSON IR.

   Compiler-libs is confined to this executable; the versioned JSON protocol
   keeps the Haxe emitter independent of OCaml's internal AST changes. It is
   built with the compiler-libs of the opam switch the pinned Haxe tag builds
   with (see tools/ml2hx/README.md), so the .cmt files always match.

   Protocol 2. Per unit: {file, modname, source, types:[...], items:[...]}.
   Types are hash-consed per unit: every "t" field is an index into "types".
   Paths: {"l":"name_stamp"} local, {"g":"Unit"} compilation unit,
   {"p":"name"} predefined, {"d":[path,"name"]} dot, {"a":[path,path]} apply. *)
open Asttypes
open Typedtree

type json = Null | Bool of bool | Num of int | Str of string | Arr of json list | Obj of (string * json) list
let escape b s =
  Buffer.add_char b '"';
  String.iter (fun c -> match c with
    | '"' -> Buffer.add_string b "\\\"" | '\\' -> Buffer.add_string b "\\\\"
    | '\n' -> Buffer.add_string b "\\n" | '\r' -> Buffer.add_string b "\\r"
    | '\t' -> Buffer.add_string b "\\t"
    | c when Char.code c < 32 || Char.code c >= 127 -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
    | c -> Buffer.add_char b c) s;
  Buffer.add_char b '"'
let rec output b = function
  | Null -> Buffer.add_string b "null" | Bool x -> Buffer.add_string b (string_of_bool x)
  | Num n -> Buffer.add_string b (string_of_int n) | Str s -> escape b s
  | Arr xs -> Buffer.add_char b '['; List.iteri (fun i x -> if i > 0 then Buffer.add_char b ','; output b x) xs; Buffer.add_char b ']'
  | Obj xs -> Buffer.add_char b '{'; List.iteri (fun i (k,v) -> if i > 0 then Buffer.add_char b ','; escape b k; Buffer.add_char b ':'; output b v) xs; Buffer.add_char b '}'

let arr f xs = Arr (List.map f xs)
let opt f = function None -> Null | Some x -> f x
let str s = Str s
let label = function Nolabel -> Str "" | Labelled s -> Str s | Optional s -> Str ("?" ^ s)
let loc (l:Location.t) = let p = l.loc_start in Arr [Num p.pos_lnum; Num (p.pos_cnum - p.pos_bol)]
let ident i = Str (Ident.unique_name i)
(* Module aliases through compilation units (Stdlib.List, ExtLib.List,
   Extlib_leftovers.UTF8) are normalised to the defining unit. *)
let norm_env = ref None
let norm_cache : (string, Path.t) Hashtbl.t = Hashtbl.create 256
let rec global_root = function Path.Pident i -> Ident.global i | Path.Pdot (p,_) -> global_root p | _ -> false
let normalize_module p =
  if not (global_root p) then p else
  let key = Path.name p in
  match Hashtbl.find_opt norm_cache key with
  | Some q -> q
  | None ->
    let env = match !norm_env with Some e -> e | None -> let e = Compmisc.initial_env () in norm_env := Some e; e in
    let q = try Env.normalize_module_path None env p with _ -> p in
    Hashtbl.replace norm_cache key q; q
let rec path p = match p with
  | Path.Pdot (m,s) when global_root m && normalize_module m != m -> path (Path.Pdot (normalize_module m,s))
  | Path.Pident i when Ident.is_predef i -> Obj ["p",Str (Ident.name i)]
  | Path.Pident i when Ident.global i -> Obj ["g",Str (Ident.name i)]
  | Path.Pident i -> Obj ["l",ident i]
  | Path.Pdot (p,s) -> Obj ["d",Arr [path p; Str s]]
  | Path.Papply (a,b) -> Obj ["a",Arr [path a; path b]]
  | Path.Pextra_ty (p,_) -> path p

(* ---- types, hash-consed per unit ---- *)
let type_table : json option array ref = ref [||]
let type_count = ref 0
let type_index : (int, int) Hashtbl.t = Hashtbl.create 1024
let reset_types () = type_table := Array.make 1024 None; type_count := 0; Hashtbl.reset type_index
let rec typ t : json =
  let id = Types.get_id t in
  match Hashtbl.find_opt type_index id with
  | Some i -> Num i
  | None ->
    let i = !type_count in
    incr type_count;
    if i >= Array.length !type_table then begin
      let bigger = Array.make (2 * i) None in Array.blit !type_table 0 bigger 0 i; type_table := bigger
    end;
    Hashtbl.replace type_index id i;
    !type_table.(i) <- Some (typ_desc t);
    Num i
and typ_desc t =
  let node k fields = Obj (("k",Str k)::fields) in
  match Types.get_desc t with
  | Types.Tvar name -> node "var" ["id",Num (Types.get_id t); "name",opt str name; "gen",Bool (Types.get_level t = Btype.generic_level)]
  | Types.Tunivar name -> node "var" ["id",Num (Types.get_id t); "name",opt str name; "univ",Bool true]
  | Types.Tarrow (l,a,b,_) -> node "arrow" ["label",label l; "arg",typ a; "res",typ b]
  | Types.Ttuple ts -> node "tuple" ["args",arr typ ts]
  | Types.Tconstr (p,ts,_) ->
    (* A library type abbreviation (Gen.t, Seq.t...): its expansion, for
       types the emitter does not map by name. *)
    let exp = if not (global_root p) then [] else
      match !norm_env with
      | None -> []
      | Some env ->
        (try
          let d = Env.find_type p env in
          match d.Types.type_kind, d.Types.type_manifest with
          | Types.Type_abstract _, Some _ ->
            let e = Ctype.expand_head_opt env t in
            (match Types.get_desc e with
             | Types.Tconstr (q,_,_) when Path.same p q -> []
             | _ -> ["exp",typ e])
          | _ -> []
        with _ -> []) in
    node "constr" (["path",path p; "args",arr typ ts] @ exp)
  | Types.Tpoly (t,vars) -> node "poly" ["body",typ t; "vars",arr typ vars]
  | Types.Tobject (fields,nm) ->
    let fs,rest = Ctype.flatten_fields fields in
    let fs = List.filter (fun (_,k,_) -> Types.field_kind_repr k = Types.Fpublic) fs in
    node "object" ["fields",arr (fun (n,_,t) -> Obj ["name",Str n; "t",typ t]) fs;
      "open",Bool (match Types.get_desc rest with Types.Tnil -> false | _ -> true);
      "class",(match !nm with Some (p,_) -> path p | None -> Null);
      "classArgs",(match !nm with Some (_,args) -> arr typ args | None -> Arr [])]
  | Types.Tvariant row ->
    let fields = Types.row_fields row in
    node "variant" ["fields",arr (fun (tag,f) -> match Types.row_field_repr f with
        | Types.Rpresent a -> Obj ["tag",Str tag; "args",(match a with None -> Arr [] | Some t -> Arr [typ t]); "present",Bool true]
        | Types.Reither (c,ts,_) -> Obj ["tag",Str tag; "args",(if c then Arr [] else arr typ ts); "present",Bool false]
        | Types.Rabsent -> Obj ["tag",Str tag; "absent",Bool true]) fields;
      "closed",Bool (Types.row_closed row)]
  | Types.Tpackage (p,_) -> node "package" ["path",path p]
  | Types.Tfield _ | Types.Tnil -> node "unsupported" ["text",Str "object row"]
  | Types.Tlink _ | Types.Tsubst _ -> assert false

(* ---- constants ---- *)
let constant c =
  let node k v = Obj ["k",Str k; "v",v] in
  match c with
  | Const_int n -> node "int" (Str (string_of_int n))
  | Const_int32 n -> node "int32" (Str (Int32.to_string n))
  | Const_int64 n -> node "int64" (Str (Int64.to_string n))
  | Const_nativeint n -> node "nativeint" (Str (Nativeint.to_string n))
  | Const_float s -> node "float" (Str s)
  | Const_char c -> node "char" (Num (Char.code c))
  | Const_string (s,_,_) -> node "string" (Str s)

(* ---- constructors and labels ---- *)
let type_path t = match Types.get_desc t with Types.Tconstr (p,_,_) -> path p | _ -> Null
let constructor (c:Types.constructor_description) =
  Obj (["name",Str c.cstr_name; "type",type_path c.cstr_res; "arity",Num c.cstr_arity;
        "inline",Bool (c.cstr_inlined <> None)]
       @ (match c.cstr_tag with Types.Cstr_extension (p,_) -> ["ext",path p] | _ -> []))
let label_ref (l:Types.label_description) =
  Obj ["name",Str l.lbl_name; "type",type_path l.lbl_res; "pos",Num l.lbl_pos;
       "all",Arr (Array.to_list (Array.map (fun (l:Types.label_description) -> Str l.lbl_name) l.lbl_all))]

(* ---- patterns ---- *)
let rec pattern : type k. k general_pattern -> json = fun p ->
  let k, fields = match p.pat_desc with
  | Tpat_any -> "any",[]
  | Tpat_var (i,_,_) -> "var",["id",ident i]
  | Tpat_alias (q,i,_,_) -> "alias",["p",pattern q; "id",ident i]
  | Tpat_constant c -> "const",["c",constant c]
  | Tpat_tuple ps -> "tuple",["args",arr pattern ps]
  | Tpat_construct (_,c,ps,_) -> "construct",["c",constructor c; "args",arr pattern ps]
  | Tpat_variant (tag,q,_) -> "variant",["tag",Str tag; "arg",opt pattern q]
  | Tpat_record (fs,closed) -> "record",["fields",arr (fun (_,l,q) -> Obj ["lbl",label_ref l; "p",pattern q]) fs; "closed",Bool (closed = Closed)]
  | Tpat_array ps -> "array",["args",arr pattern ps]
  | Tpat_lazy q -> "lazy",["p",pattern q]
  | Tpat_or (a,b,_) -> "or",["a",pattern a; "b",pattern b]
  | Tpat_value q -> "value",["p",pattern (q :> pattern)]
  | Tpat_exception q -> "exception",["p",pattern q] in
  let extra = List.filter_map (fun (e,_,_) -> match e with
    | Tpat_unpack -> Some (Str "unpack") | Tpat_type _ -> Some (Str "type") | _ -> None) p.pat_extra in
  Obj (("k",Str k)::("t",typ p.pat_type)::("l",loc p.pat_loc)::(if extra = [] then fields else ("extra",Arr extra)::fields))

(* ---- expressions ---- *)
let value_kind (vd:Types.value_description) = match vd.val_kind with
  | Types.Val_prim p -> ["prim",Obj ["name",Str p.prim_name; "arity",Num p.prim_arity]]
  | _ -> []
let rec expr e =
  let k, fields = match e.exp_desc with
  | Texp_ident (p,_,vd) -> "ident",(["path",path p; "scheme",typ vd.val_type] @ value_kind vd)
  | Texp_constant c -> "const",["c",constant c]
  | Texp_let (r,bs,body) -> "let",["rec",Bool (r = Recursive); "bindings",arr binding bs; "body",expr body]
  | Texp_function (params,body) ->
    "fun",["params",arr (fun fp -> Obj (["label",label fp.fp_arg_label; "id",ident fp.fp_param;
              "partial",Bool (fp.fp_partial = Partial)] @
            (match fp.fp_kind with
             | Tparam_pat p -> ["p",pattern p]
             | Tparam_optional_default (p,d) -> ["p",pattern p; "default",expr d]))) params;
           "body",(match body with
             | Tfunction_body b -> Obj ["k",Str "body"; "e",expr b]
             | Tfunction_cases {cases;partial;param;loc=l;_} ->
               Obj ["k",Str "cases"; "param",ident param; "partial",Bool (partial = Partial); "cases",arr case cases; "l",loc l])]
  | Texp_apply (f,args) -> "apply",["fn",expr f; "args",arr (fun (l,a) -> Obj ["label",label l; "e",opt expr a]) args]
  | Texp_match (s,cs,[],partial) -> "match",["e",expr s; "cases",arr case cs; "partial",Bool (partial = Partial)]
  | Texp_match _ -> "unsupported",["text",Str "effect handler"]
  | Texp_try (b,cs,[]) -> "try",["e",expr b; "cases",arr case cs]
  | Texp_try _ -> "unsupported",["text",Str "effect handler"]
  | Texp_tuple es -> "tuple",["args",arr expr es]
  | Texp_construct (_,c,es) -> "construct",["c",constructor c; "args",arr expr es]
  | Texp_variant (tag,a) -> "variant",["tag",Str tag; "arg",opt expr a]
  | Texp_record {fields;extended_expression;_} ->
    "record",["base",opt expr extended_expression;
      "fields",Arr (Array.to_list (Array.map (fun ((l:Types.label_description),d) ->
        Obj ["lbl",label_ref l; "e",(match d with Kept _ -> Null | Overridden (_,x) -> expr x)]) fields))]
  | Texp_field (r,_,l) -> "field",["e",expr r; "lbl",label_ref l]
  | Texp_setfield (r,_,l,v) -> "setfield",["e",expr r; "lbl",label_ref l; "v",expr v]
  | Texp_array es -> "array",["args",arr expr es]
  | Texp_ifthenelse (c,a,b) -> "if",["cond",expr c; "then",expr a; "else",opt expr b]
  | Texp_sequence (a,b) -> "seq",["a",expr a; "b",expr b]
  | Texp_while (c,b) -> "while",["cond",expr c; "body",expr b]
  | Texp_for (i,_,a,b,d,body) -> "for",["id",ident i; "from",expr a; "to",expr b; "up",Bool (d = Upto); "body",expr body]
  | Texp_send (o,m) -> "send",["obj",expr o; "meth",(match m with
      | Tmeth_name s -> Obj ["name",Str s]
      | Tmeth_val i -> Obj ["name",Str (Ident.name i); "private",Bool true]
      | Tmeth_ancestor (i,p) -> Obj ["name",Str (Ident.name i); "ancestor",path p])]
  | Texp_new (p,_,_) -> "new",["path",path p]
  | Texp_instvar (_,_,n) -> "instvar",["name",Str n.txt]
  | Texp_setinstvar (_,_,n,v) -> "setinstvar",["name",Str n.txt; "v",expr v]
  | Texp_override (_,fs) -> "override",["fields",arr (fun (_,n,v) -> Obj ["name",Str n.txt; "e",expr v]) fs]
  | Texp_letmodule (i,_,_,m,body) -> "letmodule",["id",opt ident i; "m",module_expr m; "body",expr body]
  | Texp_letexception (x,body) -> "letexception",["ext",extension x; "body",expr body]
  | Texp_assert (a,_) -> "assert",["e",expr a]
  | Texp_lazy a -> "lazy",["e",expr a]
  | Texp_object (cs,_) -> "object",["cs",class_structure cs]
  | Texp_pack m -> "pack",["m",module_expr m]
  | Texp_letop _ -> "unsupported",["text",Str "binding operator"]
  | Texp_unreachable -> "unreachable",[]
  | Texp_extension_constructor (_,p) -> "extconstr",["path",path p]
  | Texp_open (_,body) -> "open",["e",expr body] in
  let base = Obj (("k",Str k)::("t",typ e.exp_type)::("l",loc e.exp_loc)::fields) in
  (* Coercions change the static type (objects, polymorphic variants); newtypes
     scope locally abstract types. Constraints are only annotations. *)
  List.fold_left (fun inner (x,l,_) -> match x with
    | Texp_coerce _ -> Obj ["k",Str "coerce"; "t",typ e.exp_type; "l",loc l; "e",inner]
    | Texp_newtype n -> Obj ["k",Str "newtype"; "t",typ e.exp_type; "l",loc l; "name",Str n; "e",inner]
    | _ -> inner) base (List.rev e.exp_extra)
and case : type k. k case -> json = fun c -> Obj ["p",pattern c.c_lhs; "guard",opt expr c.c_guard; "e",expr c.c_rhs]
and binding b = Obj ["p",pattern b.vb_pat; "e",expr b.vb_expr; "l",loc b.vb_loc]
and extension (x:extension_constructor) =
  let t = x.ext_type in
  Obj (["id",ident x.ext_id; "name",Str x.ext_name.txt; "type",path t.ext_type_path; "params",arr typ t.ext_type_params; "l",loc x.ext_loc]
       @ (match x.ext_kind with
          | Text_decl _ -> ["args",constructor_args t.ext_args; "res",opt typ t.ext_ret_type]
          | Text_rebind (p,_) -> ["rebind",path p]))
and constructor_args = function
  | Types.Cstr_tuple ts -> Obj ["tuple",arr typ ts]
  | Types.Cstr_record ls -> Obj ["record",arr label_decl ls]
and label_decl (l:Types.label_declaration) = Obj ["name",Str (Ident.name l.ld_id); "mut",Bool (l.ld_mutable = Mutable); "t",typ l.ld_type]
and type_decl name id (d:Types.type_declaration) =
  Obj (["name",Str name; "id",ident id; "params",arr typ d.type_params; "manifest",opt typ d.type_manifest;
        "private",Bool (d.type_private = Private); "l",loc d.type_loc;
        "unboxed",Bool (match d.type_kind with Types.Type_record (_,Types.Record_unboxed _) | Types.Type_variant (_,Types.Variant_unboxed) -> true | _ -> false)]
       @ (match d.type_kind with
          | Types.Type_abstract _ -> ["kind",Str "abstract"]
          | Types.Type_open -> ["kind",Str "open"]
          | Types.Type_record (ls,_) -> ["kind",Str "record"; "labels",arr label_decl ls]
          | Types.Type_variant (cs,_) -> ["kind",Str "variant"; "ctors",arr (fun (c:Types.constructor_declaration) ->
              Obj ["name",Str (Ident.name c.cd_id); "args",constructor_args c.cd_args; "res",opt typ c.cd_res]) cs]))
(* ---- modules ---- *)
and env_of e = try Some (Envaux.env_of_only_summary e) with ex -> (if Sys.getenv_opt "ML2HX_DEBUG" <> None then prerr_endline (Printexc.to_string ex)); None
and signature env (s:Types.signature) = arr (signature_item env) s
and signature_item env item = match item with
  | Types.Sig_value (i,vd,_) -> Obj (["k",Str "value"; "id",ident i; "t",typ vd.val_type] @ value_kind vd)
  | Types.Sig_type (i,d,_,_) -> Obj ["k",Str "type"; "id",ident i; "decl",type_decl (Ident.name i) i d]
  | Types.Sig_typext (i,x,status,_) -> Obj ["k",Str "typext"; "id",ident i; "type",path x.ext_type_path;
      "exception",Bool (status = Types.Text_exception); "args",constructor_args x.ext_args]
  | Types.Sig_module (i,_,md,_,_) -> Obj ["k",Str "module"; "id",ident i; "mty",module_type env md.md_type]
  | Types.Sig_modtype (i,_,_) -> Obj ["k",Str "modtype"; "id",ident i]
  | Types.Sig_class (i,_,_,_) -> Obj ["k",Str "class"; "id",ident i]
  | Types.Sig_class_type (i,_,_,_) -> Obj ["k",Str "classtype"; "id",ident i]
and module_type env (m:Types.module_type) =
  let m = match env with Some env -> (try Mtype.scrape env m with _ -> m) | None -> m in
  match m with
  | Types.Mty_signature s -> Obj ["k",Str "sig"; "items",signature env s]
  | Types.Mty_functor (Types.Named (i,a),r) -> Obj ["k",Str "functor"; "param",opt ident i; "arg",module_type env a; "res",module_type env r]
  | Types.Mty_functor (Types.Unit,r) -> Obj ["k",Str "functor"; "res",module_type env r]
  | Types.Mty_ident p -> Obj ["k",Str "ident"; "path",path p]
  | Types.Mty_alias p -> Obj ["k",Str "alias"; "path",path p]
and module_expr m =
  let k, fields = match m.mod_desc with
  | Tmod_ident (p,_) -> "ident",["path",path p]
  | Tmod_structure s -> "struct",["items",structure s]
  | Tmod_functor (Named (i,_,mty),body) ->
    "functor",["param",opt ident i; "sig",module_type (env_of mty.mty_env) mty.mty_type; "body",module_expr body]
  | Tmod_functor (Unit,body) -> "functor",["body",module_expr body]
  | Tmod_apply (f,a,_) -> "apply",["fn",module_expr f; "arg",module_expr a]
  | Tmod_apply_unit f -> "apply",["fn",module_expr f]
  | Tmod_constraint (inner,mty,_,_) -> "constraint",["m",module_expr inner; "sig",module_type (env_of m.mod_env) mty]
  | Tmod_unpack (e,_) -> "unpack",["e",expr e] in
  Obj (("k",Str k)::("l",loc m.mod_loc)::fields)
and class_expr ce =
  let k, fields = match ce.cl_desc with
  | Tcl_ident (p,_,_) -> "ident",["path",path p]
  | Tcl_structure cs -> "struct",["cs",class_structure cs]
  | Tcl_fun (l,p,defaults,body,_) -> "fun",["label",label l; "p",pattern p; "defaults",arr (fun (i,d) -> Obj ["id",ident i; "e",expr d]) defaults; "body",class_expr body]
  | Tcl_apply (f,args) -> "apply",["fn",class_expr f; "args",arr (fun (l,a) -> Obj ["label",label l; "e",opt expr a]) args]
  | Tcl_let (r,bs,ivars,body) -> "let",["rec",Bool (r = Recursive); "bindings",arr binding bs;
      "ivars",arr (fun (i,d) -> Obj ["id",ident i; "e",expr d]) ivars; "body",class_expr body]
  | Tcl_constraint (inner,_,_,_,_) -> "constraint",["ce",class_expr inner]
  | Tcl_open (_,inner) -> "constraint",["ce",class_expr inner] in
  Obj (("k",Str k)::("l",loc ce.cl_loc)::fields)
and class_structure cs =
  Obj ["self",pattern cs.cstr_self; "fields",Arr (List.filter_map (fun f -> match f.cf_desc with
    | Tcf_inherit (_,ce,super,vals,meths) -> Some (Obj ["k",Str "inherit"; "ce",class_expr ce; "super",opt str super;
        "vals",arr (fun (n,_) -> Str n) vals; "meths",arr (fun (n,_) -> Str n) meths; "l",loc f.cf_loc])
    | Tcf_val (n,mut,i,kind,_) -> Some (Obj (["k",Str "val"; "name",Str n.txt; "id",ident i; "mut",Bool (mut = Mutable); "l",loc f.cf_loc] @ field_kind kind))
    | Tcf_method (n,priv,kind) -> Some (Obj (["k",Str "method"; "name",Str n.txt; "private",Bool (priv = Private); "l",loc f.cf_loc] @ field_kind kind))
    | Tcf_initializer e -> Some (Obj ["k",Str "initializer"; "e",expr e; "l",loc f.cf_loc])
    | Tcf_constraint _ | Tcf_attribute _ -> None) cs.cstr_fields);
    "methods",Arr (List.rev (Types.Meths.fold (fun n (_,_,t) acc -> Obj ["name",Str n; "t",typ t]::acc) cs.cstr_type.csig_meths []))]
and field_kind = function
  | Tcfk_virtual t -> ["virtual",Bool true; "t",typ t.ctyp_type]
  | Tcfk_concrete (o,e) -> ["override",Bool (o = Override); "e",expr e]
and class_decl (c,_) =
  Obj ["id",ident c.ci_id_class; "name",Str c.ci_id_name.txt; "virtual",Bool (c.ci_virt = Virtual);
       "params",arr (fun (t,_) -> typ t.ctyp_type) c.ci_params; "ce",class_expr c.ci_expr;
       "type",ident c.ci_id_class_type; "object",ident c.ci_id_object; "l",loc c.ci_loc]
and structure s = arr structure_item s.str_items
and structure_item i =
  let k, fields = match i.str_desc with
  | Tstr_value (r,bs) -> "value",["rec",Bool (r = Recursive); "bindings",arr binding bs]
  | Tstr_type (_,ds) -> "type",["decls",arr (fun d -> type_decl d.typ_name.txt d.typ_id d.typ_type) ds]
  | Tstr_eval (e,_) -> "eval",["e",expr e]
  | Tstr_primitive d -> "external",["id",ident d.val_id; "name",Str d.val_name.txt; "t",typ d.val_val.val_type; "prim",(match d.val_val.val_kind with
      | Types.Val_prim p -> Obj ["name",Str p.prim_name; "arity",Num p.prim_arity] | _ -> Null)]
  | Tstr_typext x -> "typext",["type",path x.tyext_path; "ctors",arr extension x.tyext_constructors]
  | Tstr_exception x -> "exception",["ext",extension x.tyexn_constructor]
  | Tstr_module b -> "module",["id",opt ident b.mb_id; "name",opt str b.mb_name.txt; "m",module_expr b.mb_expr]
  | Tstr_recmodule bs -> "recmodule",["bindings",arr (fun b -> Obj ["id",opt ident b.mb_id; "name",opt str b.mb_name.txt; "m",module_expr b.mb_expr]) bs]
  | Tstr_modtype d -> "modtype",["id",ident d.mtd_id; "name",Str d.mtd_name.txt; "mty",opt (fun m -> module_type (env_of i.str_env) m.mty_type) d.mtd_type]
  | Tstr_open d -> "open",["m",module_expr d.open_expr; "sig",signature (env_of i.str_env) d.open_bound_items]
  | Tstr_class cs -> "class",["classes",arr class_decl cs]
  | Tstr_class_type cs -> "classtype",["ids",arr (fun (i,_,_) -> ident i) cs]
  | Tstr_include d -> "include",["m",module_expr d.incl_mod; "sig",signature (env_of i.str_env) d.incl_type]
  | Tstr_attribute _ -> "attribute",[] in
  Obj (("k",Str k)::("l",loc i.str_loc)::fields)

(* ---- driver ---- *)
let parse file =
  let ch = open_in_bin file in
  Fun.protect ~finally:(fun () -> close_in ch) (fun () ->
    let lex = Lexing.from_channel ch in Location.init lex file; Parse.implementation lex)
let unit_json file modname source tree =
  reset_types ();
  (match !norm_env with None -> (try norm_env := Some (Compmisc.initial_env ()) with _ -> ()) | Some _ -> ());
  let items = structure tree in
  let types = Array.to_list (Array.sub !type_table 0 !type_count) |> List.map (function Some j -> j | None -> Null) in
  Obj ["file",Str file; "modname",Str modname; "source",opt str source; "types",Arr types; "items",items]
let () =
  let files = ref [] and out_dir = ref None and serial = ref 0 in
  Arg.parse ["--out-dir",Arg.String(fun s -> out_dir := Some s),"Write each unit to <dir>/<n>.json instead of stdout";
    "-I",Arg.String(fun s -> Clflags.include_dirs := s :: !Clflags.include_dirs),"CMI search directory"]
    (fun s -> files := s :: !files) "ml2hx frontend [-I dir] [--out-dir dir] (file.cmt | file.ml) ...";
  try
    Compmisc.init_path ();
    let results = List.map (fun file ->
      try
        let result =
          if Filename.check_suffix file ".cmt" || Filename.check_suffix file ".cmti" then begin
            let _,info = Cmt_format.read file in
            match info with
            | Some ({Cmt_format.cmt_annots = Cmt_format.Implementation tree; _} as c) ->
              (* Dune records /workspace_root as the build directory; the load
                 path is relative to the build context holding the CMT. *)
              let root = let marker = "/_build/default/" in
                let rec find i = if i < 0 then None
                  else if i + String.length marker <= String.length file && String.sub file i (String.length marker) = marker then Some (String.sub file 0 (i + String.length marker - 1))
                  else find (i - 1) in find (String.length file - 1) in
              Sys.chdir (match root with Some r -> r | None -> if Sys.file_exists c.cmt_builddir then c.cmt_builddir else Sys.getcwd ());
              Load_path.init ~auto_include:Load_path.no_auto_include ~visible:(c.cmt_loadpath.visible @ !Clflags.include_dirs) ~hidden:c.cmt_loadpath.hidden;
              Envaux.reset_cache (); norm_env := None; Hashtbl.reset norm_cache;
              unit_json file c.cmt_modname c.cmt_sourcefile tree
            | Some ({Cmt_format.cmt_annots = Cmt_format.Interface sg; _} as c) ->
              (* An interface without implementation (types only): its type
                 and exception declarations as structure items. *)
              reset_types ();
              let items = Arr (List.filter_map (fun (i:signature_item) -> match i.sig_desc with
                | Tsig_type (_,ds) -> Some (Obj ["k",Str "type"; "l",loc i.sig_loc; "decls",arr (fun d -> type_decl d.typ_name.txt d.typ_id d.typ_type) ds])
                | Tsig_exception x -> Some (Obj ["k",Str "exception"; "l",loc i.sig_loc; "ext",extension x.tyexn_constructor])
                | Tsig_typext x -> Some (Obj ["k",Str "typext"; "l",loc i.sig_loc; "type",path x.tyext_path; "ctors",arr extension x.tyext_constructors])
                | Tsig_value _ | Tsig_attribute _ | Tsig_open _ -> None
                | _ -> Some (Obj ["k",Str "unsupported"; "l",loc i.sig_loc])) sg.sig_items) in
              let types = Array.to_list (Array.sub !type_table 0 !type_count) |> List.map (function Some j -> j | None -> Null) in
              Obj ["file",Str file; "modname",Str c.cmt_modname; "source",opt str c.cmt_sourcefile; "interface",Bool true; "types",Arr types; "items",items]
            | _ -> failwith "expected a CMT or CMTI"
          end else begin
            let ast = parse file in
            let modname = String.capitalize_ascii (Filename.remove_extension (Filename.basename file)) in
            Env.set_current_unit (Unit_info.make ~source_file:file Unit_info.Impl (Filename.remove_extension file));
            let tree,_,_,_,_ = Typemod.type_structure (Compmisc.initial_env ()) ast in
            unit_json file modname (Some file) tree
          end in
        match !out_dir with
        | None -> result
        | Some dir ->
          let dest = Filename.concat dir (string_of_int !serial ^ ".json") in
          incr serial;
          let b = Buffer.create (1 lsl 20) in output b result;
          let ch = open_out_bin dest in
          Fun.protect ~finally:(fun () -> close_out ch) (fun () -> Buffer.output_buffer ch b);
          let field k = match result with Obj fs -> (try List.assoc k fs with Not_found -> Null) | _ -> Null in
          Obj ["file",Str file; "modname",field "modname"; "source",field "source"; "ir",Str dest]
      with e -> Obj ["file",Str file; "error",Str (Format.asprintf "%a" Location.report_exception e)]
    ) (List.rev !files) in
    let b = Buffer.create (1 lsl 16) in
    output b (Obj ["protocol",Num 2; "ocaml",Str Sys.ocaml_version; "files",Arr results]);
    Buffer.output_buffer stdout b; print_newline ()
  with e -> Location.report_exception Format.err_formatter e; exit 1

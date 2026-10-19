(* Compiler-libs is deliberately confined to this executable. The versioned JSON
   protocol keeps the Haxe emitter independent of OCaml's internal AST changes. *)
open Asttypes
open Typedtree

type json = Null | Bool of bool | Num of int | Str of string | Arr of json list | Obj of (string * json) list
let rec write = function
  | Null -> "null" | Bool b -> string_of_bool b | Num n -> string_of_int n
  | Str s ->
    let b = Buffer.create (String.length s + 2) in
    Buffer.add_char b '"';
    String.iter (fun c -> match c with
      | '"' -> Buffer.add_string b "\\\"" | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n" | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c when Char.code c < 32 -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c) s;
    Buffer.add_char b '"'; Buffer.contents b
  | Arr xs -> "[" ^ String.concat "," (List.map write xs) ^ "]"
  | Obj xs -> "{" ^ String.concat "," (List.map (fun (k,v) -> write (Str k) ^ ":" ^ write v) xs) ^ "}"
let node kind fields = Obj (("kind",Str kind)::fields)
let arr f xs = Arr (List.map f xs)
let opt f = function None -> Null | Some x -> f x
let loc l = let p = l.Location.loc_start in Obj ["file",Str p.Lexing.pos_fname; "line",Num p.pos_lnum; "column",Num (p.pos_cnum-p.pos_bol)]
let id i = Str (Ident.unique_name i)
let rec path p = match p with
  | Path.Pident i -> Obj ["name",Str (Ident.name i); "id",id i]
  | Path.Pdot (p,s) -> Obj ["name",Str (Path.name (Path.Pdot(p,s)))]
  | Path.Papply _ | Path.Pextra_ty _ -> Obj ["name",Str (Path.name p)]
let rec typ t =
  match Types.get_desc t with
  | Types.Tvar _ | Types.Tunivar _ -> node "var" ["id",Num (Types.get_id t)]
  | Types.Tarrow (label,a,b,_) -> node "arrow" ["label",Str (match label with Nolabel -> "" | Labelled s -> s | Optional s -> "?"^s); "arg",typ a; "result",typ b]
  | Types.Ttuple ts -> node "tuple" ["args",arr typ ts]
  | Types.Tconstr (p,ts,_) -> node "constr" ["path",Str (Path.name p); "args",arr typ ts]
  | Types.Tpoly (t,_) -> typ t
  | _ -> node "unsupported" ["text",Str (Format.asprintf "%a" Printtyp.type_expr t)]
(* JS hosts use 32-bit OCaml ints. Typecheck machine-integer literals as zero
   and retain their native 63-bit lexical values independently of the host. *)
let literals = Hashtbl.create 32
let literal_key l = (l.Location.loc_start.Lexing.pos_fname, l.Location.loc_start.Lexing.pos_cnum)
let machine_literal l s =
  let s = String.concat "" (String.split_on_char '_' s) in
  let negative = String.length s > 0 && s.[0] = '-' in
  let offset = if String.length s > 0 && (s.[0]='-' || s.[0]='+') then 1 else 0 in
  let unsigned = String.length s > offset + 1 && s.[offset]='0' && List.mem s.[offset+1] ['x';'X';'o';'O';'b';'B';'u';'U'] in
  try
    let v = Int64.of_string s in
    let max_signed = Int64.of_string "4611686018427387903" in
    let min_signed = Int64.of_string "-4611686018427387904" in
    if (unsigned && not negative && Int64.compare v 0L < 0) ||
       ((not unsigned || negative) && (Int64.compare v max_signed > 0 || Int64.compare v min_signed < 0)) then failwith "range";
    Int64.to_string (Int64.shift_right (Int64.shift_left v 1) 1)
  with _ -> Location.raise_errorf ~loc:l "integer literal outside OCaml's native 63-bit range: %s" s
let prepare_literals ast =
  Hashtbl.clear literals;
  let base = Ast_mapper.default_mapper in
  let convert l c = match c.Parsetree.pconst_desc with
    | Parsetree.Pconst_integer (s,None) -> Hashtbl.replace literals (literal_key l) (machine_literal l s); {c with Parsetree.pconst_desc=Parsetree.Pconst_integer ("0",None)}
    | _ -> c in
  let mapper = {base with
    expr = (fun self e -> let e = match e.Parsetree.pexp_desc with
      | Pexp_constant c -> {e with pexp_desc=Pexp_constant(convert e.pexp_loc c)} | _ -> e in base.expr self e);
    pat = (fun self p -> let p = match p.Parsetree.ppat_desc with
      | Ppat_constant c -> {p with ppat_desc=Ppat_constant(convert p.ppat_loc c)} | _ -> p in base.pat self p);
  } in mapper.structure mapper ast
let constant ?at = function
  | Const_int n -> node "int" ["value",Str (match at with Some l -> (try Hashtbl.find literals (literal_key l) with Not_found -> string_of_int n) | None -> string_of_int n)]
  | Const_int32 n -> node "int32" ["value",Str (Int32.to_string n)]
  | Const_int64 n -> node "int64" ["value",Str (Int64.to_string n)]
  | Const_nativeint n -> node "nativeint" ["value",Str (Nativeint.to_string n)]
  | Const_float s -> node "float" ["value",Str s]
  | Const_char c -> node "char" ["value",Num (Char.code c)]
  | Const_string (s,_,_) -> node "string" ["bytes",Arr (List.init (String.length s) (fun i -> Num (Char.code s.[i])))]
let rec pattern : type k. k general_pattern -> json = fun p ->
  let kind, fields = match p.pat_desc with
  | Tpat_any -> "any",[]
  | Tpat_var (i,n,_) -> "var",["id",id i; "name",Str n.txt]
  | Tpat_alias (p,i,n,_) -> "alias",["pattern",pattern p; "id",id i; "name",Str n.txt]
  | Tpat_constant c -> "constant",["value",constant ~at:p.pat_loc c]
  | Tpat_tuple ps -> "tuple",["args",arr pattern ps]
  | Tpat_construct (_,c,ps,_) -> "construct",["name",Str c.Types.cstr_name; "args",arr pattern ps]
  | Tpat_record (fs,_) -> "record",["fields",Arr (List.map (fun (_,l,p) -> Obj ["name",Str l.Types.lbl_name; "pattern",pattern p]) fs)]
  | Tpat_array ps -> "array",["args",arr pattern ps]
  | Tpat_or (a,b,_) -> "or",["left",pattern a; "right",pattern b]
  | Tpat_value p -> "value",["pattern",pattern (p :> pattern)]
  | Tpat_exception p -> "exception",["pattern",pattern p]
  | _ -> "unsupported",[] in
  node kind (("type",typ p.pat_type)::("loc",loc p.pat_loc)::fields)
let rec expr e = match e.exp_desc with
  | Texp_function (params,body) -> function_expr params body e.exp_type e.exp_loc
  | _ ->
  let kind, fields = match e.exp_desc with
  | Texp_ident (p,_,_) -> "ident",["path",path p]
  | Texp_constant c -> "constant",["value",constant ~at:e.exp_loc c]
  | Texp_let (r,bs,e) -> "let",["recursive",Bool (r=Recursive); "bindings",arr binding bs; "body",expr e]
  | Texp_apply (f,args) -> "apply",["fn",expr f; "args",Arr (List.map (fun (l,e) -> Obj ["label",Str (match l with Nolabel -> "" | Labelled s -> s | Optional s -> "?"^s); "expr",opt expr e]) args)]
  | Texp_match (e,cs,effects,_) when effects = [] -> "match",["expr",expr e; "cases",arr case cs]
  | Texp_try (e,cs,effects) when effects = [] -> "try",["expr",expr e; "cases",arr case cs]
  | Texp_tuple es -> "tuple",["args",arr expr es]
  | Texp_construct (_,c,es) -> "construct",["name",Str c.Types.cstr_name; "args",arr expr es]
  | Texp_record {fields; extended_expression; _} -> "record",["base",opt expr extended_expression; "fields",Arr (Array.to_list (Array.map (fun (l,d) -> Obj ["name",Str l.Types.lbl_name; "expr",(match d with Kept _ -> Null | Overridden (_,e) -> expr e)]) fields))]
  | Texp_field (e,_,l) -> "field",["expr",expr e; "name",Str l.Types.lbl_name]
  | Texp_setfield (e,_,l,v) -> "setfield",["expr",expr e; "name",Str l.Types.lbl_name; "value",expr v]
  | Texp_array es -> "array",["args",arr expr es]
  | Texp_ifthenelse (a,b,c) -> "if",["cond",expr a; "then",expr b; "else",opt expr c]
  | Texp_sequence (a,b) -> "sequence",["first",expr a; "second",expr b]
  | Texp_while (a,b) -> "while",["cond",expr a; "body",expr b]
  | Texp_for (i,_,a,b,d,e) -> "for",["id",id i; "start",expr a; "stop",expr b; "up",Bool (d=Upto); "body",expr e]
  | Texp_assert (e,_) -> "assert",["expr",expr e]
  | Texp_lazy e -> "lazy",["expr",expr e]
  | Texp_open (d,e) -> "open",["pure",Bool (match d.open_expr.mod_desc with Tmod_ident _ -> true | _ -> false); "expr",expr e]
  | _ -> "unsupported",["text",Str (Format.asprintf "%a" Pprintast.expression (Untypeast.untype_expression e))] in
  node kind (("type",typ e.exp_type)::("loc",loc e.exp_loc)::fields)
and case : type k. k Typedtree.case -> json = fun c -> Obj ["pattern",pattern c.c_lhs; "guard",opt expr c.c_guard; "body",expr c.c_rhs]
and binding b = Obj ["pattern",pattern b.vb_pat; "expr",expr b.vb_expr; "loc",loc b.vb_loc]
and function_expr params body t at =
  match params with
  | p::ps ->
    (match Types.get_desc t,p.fp_kind with
    | Types.Tarrow (_,_,result,_),Tparam_pat pat ->
      let inner = function_expr ps body result at in
      node "function" ["type",typ t; "loc",loc at;
        "label",Str (match p.fp_arg_label with Nolabel -> "" | Labelled s -> s | Optional s -> "?"^s);
        "param",id p.fp_param; "cases",Arr [Obj ["pattern",pattern pat; "guard",Null; "body",inner]]]
    | _ -> node "unsupported" ["type",typ t; "loc",loc at; "text",Str "optional/default function parameter"])
  | [] -> match body with
    | Tfunction_body e -> expr e
    | Tfunction_cases {cases;param;loc=body_loc;_} ->
      node "function" ["type",typ t; "loc",loc body_loc; "label",Str ""; "param",id param; "cases",arr case cases]
let declaration d =
  let fields = ["name",Str d.typ_name.txt; "params",arr (fun (t,_) -> typ t.ctyp_type) d.typ_params; "loc",loc d.typ_loc] in
  match d.typ_kind with
  | Ttype_variant cs -> node "enum" (("constructors",Arr (List.map (fun c -> Obj ["name",Str c.cd_name.txt; "result",opt (fun t -> typ t.ctyp_type) c.cd_res; "args",(match c.cd_args with Cstr_tuple ts -> arr (fun t -> typ t.ctyp_type) ts | Cstr_record _ -> node "unsupported" [])]) cs))::fields)
  | Ttype_record ls -> node "record" (("fields",Arr (List.map (fun l -> Obj ["name",Str l.ld_name.txt; "mutable",Bool (l.ld_mutable=Mutable); "type",typ l.ld_type.ctyp_type]) ls))::fields)
  | Ttype_abstract -> node "alias" (("type",opt (fun t -> typ t.ctyp_type) d.typ_manifest)::fields)
  | _ -> node "unsupported" fields
let structure s = arr (fun i ->
  let kind, fields = match i.str_desc with
  | Tstr_value (r,bs) -> "value",["recursive",Bool (r=Recursive); "bindings",arr binding bs]
  | Tstr_type (_,ds) -> "type",["declarations",arr declaration ds]
  | Tstr_eval (e,_) -> "eval",["expr",expr e]
  | Tstr_open d -> "open",["pure",Bool (match d.open_expr.mod_desc with Tmod_ident _ -> true | _ -> false)]
  | Tstr_attribute _ -> "attribute",[]
  | _ -> "unsupported",[] in
  node kind (("loc",loc i.str_loc)::fields)) s.str_items
let parse file =
  let ch = open_in_bin file in
  Fun.protect ~finally:(fun () -> close_in ch) (fun () ->
    let lex = Lexing.from_channel ch in Location.init lex file; Parse.implementation lex)
let () =
  let cmt = ref false and files = ref [] in
  Arg.parse ["--cmt",Arg.Set cmt,"Read compiler-produced typedtrees";
    "-I",Arg.String(fun s -> Clflags.include_dirs := s :: !Clflags.include_dirs),"CMI search directory"]
    (fun s -> files := s :: !files) "ml2hx frontend [--cmt] file ...";
  try
    Compmisc.init_path ();
    let results = arr (fun file ->
      try
        if !cmt || Filename.check_suffix file ".cmt" then begin
          let _,info = Cmt_format.read file in
          match info with
          | Some {Cmt_format.cmt_annots = Cmt_format.Implementation tree; cmt_sourcefile=source;_} ->
            (* Typed CMT constants already have native 63-bit values. Reading the
               PPX input as source would reject the syntax CMT exists to preserve. *)
            Hashtbl.clear literals;
            Obj ["file",Str file; "source",opt (fun s -> Str s) source; "items",structure tree]
          | _ -> failwith "expected implementation CMT"
        end else begin
          let ast = parse file in
          let comments = arr (fun (text,l) -> Obj ["text",Str text; "loc",loc l]) (Lexer.comments ()) in
          Env.set_current_unit (Unit_info.make ~source_file:file Unit_info.Impl (Filename.remove_extension file));
          let tree,_,_,_,_ = Typemod.type_structure (Compmisc.initial_env ()) (prepare_literals ast) in
          Obj ["file",Str file; "comments",comments; "items",structure tree]
        end
      with e -> Obj ["file",Str file; "error",Str (Format.asprintf "%a" Location.report_exception e)]
    ) (List.rev !files) in
    print_endline (write (Obj ["protocol",Num 1; "ocaml",Str Sys.ocaml_version; "files",results]))
  with e -> Location.report_exception Format.err_formatter e; exit 1


(* Modules: submodules, includes, functors applied twice, library functors,
   module aliases, local opens. *)
module type ORD = sig type t val compare : t -> t -> int val name : string end
module Counter (O : ORD) = struct
  let count = ref 0
  let max_of a b = incr count; if O.compare a b >= 0 then a else b
  let describe () = Printf.sprintf "%s:%d" O.name !count
end
module IntOrd = struct type t = int let compare = compare let name = "int" end
module StrOrd = struct type t = string let compare = String.compare let name = "string" end
module IC = Counter (IntOrd)
module SC = Counter (StrOrd)
module Base = struct let greet s = "hello " ^ s type color = Red | Green end
module Ext = struct include Base let shout s = String.uppercase_ascii (greet s) end
module SMap = Map.Make (String)
module L = List
let () =
  Printf.printf "%d %s\n" (IC.max_of 3 7) (SC.max_of "a" "b");
  ignore (IC.max_of 1 2);
  print_endline (IC.describe () ^ " " ^ SC.describe ());
  print_endline (Ext.shout "world");
  (match Ext.Red with Base.Red -> print_endline "red" | Base.Green -> ());
  let m = SMap.add "b" 2 (SMap.add "a" 1 SMap.empty) in
  SMap.iter (fun k v -> Printf.printf "%s=%d " k v) m;
  print_newline ();
  Printf.printf "%d\n" (L.length [1; 2; 3]);
  let open Base in print_endline (greet "open")

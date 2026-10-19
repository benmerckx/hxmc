(* OCaml's structural compare and equality at known types: records,
   variants (constant constructors before the others), inline records,
   tuples, lists, options, nan, functional values *)
type color = Red | Green | Blue
type shape = Dot | Circle of float | Rect of int * int | Poly of { n : int; name : string } | Line
type 'a tree = Leaf | Node of 'a tree * 'a * 'a tree
type point = { x : int; y : float; tag : string option }
type wrap = { items : (int * string) list; kind : color; s : shape }
let sign c = if c < 0 then -1 else if c > 0 then 1 else 0
let pr fmt = Printf.printf fmt
let () =
  let shapes = [Line; Rect (1, 2); Dot; Poly {n = 3; name = "tri"}; Circle 2.; Rect (1, 1); Circle nan; Poly {n = 3; name = "a"}] in
  List.iter (fun a -> List.iter (fun b -> pr "%d" (sign (compare a b))) shapes; print_string " ") shapes; print_newline ();
  List.iter (fun a -> List.iter (fun b -> pr "%b" (a = b)) shapes; print_string " ") shapes; print_newline ();
  pr "%d %d %b\n" (compare Red Blue) (compare Blue Green) (Green < Blue);
  let p1 = {x = 1; y = 2.5; tag = Some "a"} and p2 = {x = 1; y = 2.5; tag = None} in
  pr "%d %d %b %b\n" (compare p1 p2) (compare p2 p1) (p1 = p1) (p1 > p2);
  let pn = {x = 0; y = nan; tag = None} in
  pr "%b %d %b %b\n" (pn = pn) (compare pn pn) (pn = {pn with x = 0}) (pn < pn);
  let t1 = Node (Leaf, 3, Node (Leaf, 4, Leaf)) and t2 = Node (Leaf, 3, Leaf) in
  pr "%d %d %b\n" (compare t1 t2) (compare t2 t1) (t1 = Node (Leaf, 3, Node (Leaf, 4, Leaf)));
  let w1 = {items = [(1, "a"); (2, "b")]; kind = Green; s = Dot} and w2 = {items = [(1, "a"); (2, "c")]; kind = Red; s = Dot} in
  pr "%d %d %b\n" (compare w1 w2) (compare w1 {w1 with items = [(1, "a")]}) (w1 = {w1 with kind = Green});
  let l = List.sort compare [(3, "c"); (1, "z"); (1, "a"); (2, "b")] in
  List.iter (fun (i, s) -> pr "%d%s " i s) l; print_newline ();
  pr "%d %d %d\n" (compare (Some (1, 2.)) None) (compare [Some 1; None] [Some 1; Some 0]) (compare (1, nan) (1, nan));
  pr "%b %b\n" ((1, nan) = (1, nan)) ([nan] = [nan]);
  let f = fun x -> x + 1 in
  let r = (f, 1) in
  pr "%d\n" (compare r r);
  (try ignore (compare (f, 1) ((fun x -> x), 1)); print_endline "no raise" with Invalid_argument m -> print_endline m);
  pr "%d %d %s %s %g\n" (min 3 4) (max 3 4) (min "b" "a") (max "b" "a") (max 1. nan)
let () =
  pr "%d %d %d %d %d\n" (Hashtbl.hash "hello") (Hashtbl.hash 42) (Hashtbl.hash (-7)) (Hashtbl.hash 'x') (Hashtbl.hash max_int);
  pr "%c %c %g %g\n" (min 'a' 'b') (max 'a' 'b') (min nan 1.) (min 1. 2.)
let () =
  pr "%d %d %d\n" (Hashtbl.hash_param 0 0 "abc") (Hashtbl.hash_param 0 0 5) (Hashtbl.seeded_hash_param 0 10 3 "x");
  let h = Hashtbl.create 8 in
  List.iter (fun k -> Hashtbl.replace h k (k * 2)) [5; -3; 1000000; max_int; min_int];
  pr "%d %d %b\n" (Hashtbl.find h (-3)) (Hashtbl.find h max_int) (Hashtbl.mem h 4);
  let sorted = List.sort compare [3; -1; max_int; 0; min_int] in
  List.iter (pr "%d ") sorted; print_newline ()
let () =
  pr "%b %b %b %b\n" (List.mem Blue [Red; Blue]) (List.mem (Circle nan) [Circle nan]) (List.mem nan [nan]) (List.mem "b" ["a"]);
  pr "%s %b %s\n" (List.assoc (2, "b") [((1, "a"), "x"); ((2, "b"), "y")]) (List.mem_assoc 'c' [('c', 1)]) (match List.assoc_opt 3 [(1, "o")] with None -> "none" | Some s -> s);
  (try ignore (List.assoc "z" ["a", 1]) with Not_found -> print_endline "Not_found")

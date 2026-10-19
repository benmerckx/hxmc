(* Variants: constant/non-constant constructors, inline records, GADTs,
   polymorphic variants, extensible variants and exceptions. *)
type shape = Circle of float | Rect of { w : int; mutable h : int } | Empty
type _ value = Int : int -> int value | Str : string -> string value | Pair : 'a value * 'b value -> ('a * 'b) value
let rec eval : type a. a value -> a = function Int n -> n | Str s -> s | Pair (a, b) -> (eval a, eval b)
type ext = ..
type ext += A of int | B
exception Oops of string * int
exception Plain
let area = function Circle r -> int_of_float (r *. r) | Rect r -> r.h <- r.h + 1; r.w * r.h | Empty -> 0
let tag = function `Red -> "red" | `Green n -> Printf.sprintf "green%d" n | `Blue -> "blue"
let ext_name = function A n -> Printf.sprintf "A%d" n | B -> "B" | _ -> "other"
let risky n = if n > 2 then raise (Oops ("big", n)) else if n = 2 then raise Plain else n
let guard n = try risky n with Oops (s, k) when k > 3 -> String.length s + k | Oops (_, k) -> -k | Plain -> 100
let () =
  Printf.printf "%d %d %d\n" (area (Circle 2.5)) (area (Rect {w = 2; h = 3})) (area Empty);
  let (n, s) = eval (Pair (Int 4, Str "x")) in Printf.printf "%d %s\n" n s;
  Printf.printf "%s %s %s\n" (tag `Red) (tag (`Green 3)) (tag `Blue);
  Printf.printf "%s %s\n" (ext_name (A 1)) (ext_name B);
  Printf.printf "%d %d %d %d\n" (guard 1) (guard 2) (guard 3) (guard 5);
  Printf.printf "%b %b\n" (compare (Circle 1.0) Empty > 0) (Rect {w=1;h=1} = Rect {w=1;h=1})
type 'a clist = ( :: ) of 'a * 'a clist | Open | Closed
let rec clen = function _ :: t -> 1 + clen t | Open -> 0 | Closed -> -1
let () = Printf.printf "%d %d %s\n" (clen (1 :: 2 :: Open)) (clen Closed) (String.concat "," (List.map string_of_int [1; 2]))
type ('a, _) node = Null : ('a, [> `Null]) node | Node : { mutable next : ('a, [ `Null | `Node ]) node; value : 'a } -> ('a, [> `Node]) node
let rec node_sum : type k. (int, k) node -> int = function Null -> 0 | Node r -> r.value + node_sum r.next
let () =
  let tail = Node {next = Null; value = 2} in
  let head = Node {next = tail; value = 1} in
  (match head with Node r -> r.next <- Node {next = tail; value = 10} | Null -> ());
  Printf.printf "%d\n" (node_sum head)
type ir = IA of { mutable ix : int } | IB
let rebuild v = match v with IA r -> let w = IA r in r.ix <- 5; w | IB -> IB
let () = let v = IA {ix = 1} in let w = rebuild v in Printf.printf "%b %d\n" (v == w) (match w with IA r -> r.ix | IB -> 0)
type 'a link = Link : 'a lnode -> 'a link [@@unboxed]
and 'a lnode = LNull | LNode of 'a * 'a link
let lnull = Link LNull
let () = Printf.printf "%b %b\n" (Link LNull == lnull) (match Link (LNode (1, lnull)) with Link (LNode (x, Link LNull)) -> x = 1 | _ -> false)
type wrap = { inner : int list } [@@unboxed]
let () = let w = { inner = [1; 2] } in Printf.printf "%d %b\n" (List.length w.inner) (match w with { inner = [_; x] } -> x = 2 | _ -> false)
type tr = L of tr list | D of int
let rec first = function L [t] | (D _ as t) -> (match t with D n -> n | L _ -> first t) | L _ -> -1
let () = Printf.printf "%d %d %d\n" (first (L [D 4])) (first (D 7)) (first (L []))

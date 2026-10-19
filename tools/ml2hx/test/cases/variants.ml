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

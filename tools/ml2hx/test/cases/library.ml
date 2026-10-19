(* OCaml's standard library, converted: Hashtbl order and hash, compare,
   sorting, Map/Set, float printing, Format boxes, Buffer, Scanf. *)
let () =
  let h = Hashtbl.create 16 in
  List.iter (fun k -> Hashtbl.replace h k (String.length k)) ["one"; "two"; "three"; "four"; "five"; "six"; "seven"];
  Hashtbl.iter (fun k v -> Printf.printf "%s=%d " k v) h;
  print_newline ();
  List.iter (fun v -> Printf.printf "%d " (Hashtbl.hash v)) [Hashtbl.hash 0; Hashtbl.hash 1; Hashtbl.hash "abc"; Hashtbl.hash 3.5; Hashtbl.hash [1; 2]; Hashtbl.hash (Some "x")];
  print_newline ()

type t = A | B of int | C of string * float
let () =
  let l = [C ("x", 1.5); B 3; A; B (-1); C ("a", 2.0); A] in
  List.iter (fun v -> print_string (match v with A -> "A " | B n -> Printf.sprintf "B%d " n | C (s, f) -> Printf.sprintf "C%s%g " s f)) (List.sort compare l);
  print_newline ();
  Printf.printf "%d %d %d %b %b\n" (compare "abc" "abd") (compare [1; 2] [1]) (compare (1, "z") (1, "a")) (nan = nan) (compare nan nan = 0)

module SM = Map.Make (String)
module IS = Set.Make (Int)
let () =
  let m = List.fold_left (fun m (k, v) -> SM.add k v m) SM.empty [("b", 2); ("a", 1); ("c", 3)] in
  SM.iter (fun k v -> Printf.printf "%s:%d " k v) m;
  let s = IS.of_list [5; 1; 4; 1; 3] in
  Printf.printf "| %s | %d\n" (String.concat "," (List.map string_of_int (IS.elements s))) (IS.cardinal s)

let () =
  List.iter (fun f -> Printf.printf "[%g|%e|%.3f|%F|%h|%s] " f f f f f (string_of_float f)) [0.1; 1e21; -3.25; 1.0 /. 3.0; 123456789.0];
  print_newline ();
  Printf.printf "%5.2f|%-8d|%08.3f|%x|%X|%o|%+d|% d|%S|%C\n" 3.14159 42 (-2.5) 255 255 8 5 5 "a\"b" 'c'

let () =
  Format.printf "@[<v 2>begin@,@[<h>a@ b@ c@]@,end@]@.";
  Format.printf "@[<hov 4>%s@ %s@ %s@ %s@]@." "lorem" "ipsum" "dolor" "sit";
  let b = Buffer.create 4 in
  Buffer.add_string b "hello"; Buffer.add_char b ' '; Buffer.add_string b "world";
  print_endline (Buffer.contents b ^ " " ^ string_of_int (Buffer.length b));
  Scanf.sscanf "12 abc 3.5" "%d %s %f" (fun a s f -> Printf.printf "%d %s %g\n" a s f)

let () =
  let a = [| 5; 3; 9; 1; 7 |] in
  Array.stable_sort compare a;
  print_endline (String.concat " " (Array.to_list (Array.map string_of_int a)));
  print_endline (String.concat "," (List.sort_uniq compare ["b"; "a"; "b"; "c"]));
  Printf.printf "%s %s %d\n" (String.uppercase_ascii "MiXed") (String.escaped "tab\there") (int_of_string "0x1F")
let () =
  let h = Hashtbl.create 0 in
  List.iter (fun k -> Hashtbl.add h k true) [3; 70; 1000; 100000; -5];
  String.iter (fun c -> Printf.printf "%02x" (Char.code c)) (Marshal.to_string h [Marshal.No_sharing]); print_newline ();
  let shared = [1.5; 2.0] in
  String.iter (fun c -> Printf.printf "%02x" (Char.code c)) (Marshal.to_string (shared, shared, "abc", [|1.0; 2.5|], Some (`A 3)) []); print_newline ();
  Printf.printf "%d\n" (Marshal.data_size (Marshal.to_bytes (1, "x") []) 0)
let () = let f = (fun x -> x + 1) in let p = (1, f) in Printf.printf "%d %b\n" (compare p p) (try ignore (p = p); false with Invalid_argument _ -> true)

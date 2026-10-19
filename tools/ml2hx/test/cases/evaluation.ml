(* Evaluation order, sharing, currying, tail calls. *)
type payload = Number of int | Empty
type cell = { mutable value : int; shared : int ref }

let log = ref 0
let mark n = log := !log * 10 + n; n
let combine a b = a * 10 + b
let evaluation_order () = log := 0; let result = combine (mark 1) (mark 2) in result, !log
let shared_ref () = let r = ref 1 in let a = {value = 3; shared = r} in let b = {a with value = 8} in b.shared := 9; a.value, !(a.shared), b.value
let rec sum n acc = if n = 0 then acc else sum (n - 1) (acc + n)
let partial () = let f = sum 100 in f 0, f 5
let payload = function Number n -> n + 1 | Empty -> 0
let guarded = function Number n when n > 10 -> 1 | Number _ -> 2 | Empty -> 3
let wide = 4294967296
let wrap = 4611686018427387903 + 1
let unsigned = 0x7fffffffffffffff
let binary = "\000\255\195\169"
let bounds () = log := 0; for _ = mark 1 to mark 2 do () done; !log
let short_circuit () = log := 0; let _ = false && (mark 9 = 9) in let _ = true || (mark 8 = 8) in !log
let grouped () = log := 0; let a = mark 1 and b = mark 2 in a, b, !log
let copy_order () = log := 0; let original = {value = 0; shared = ref 0} in let copied = {(let _ = mark 1 in original) with value = mark 2} in copied.value, !log
let tuple_order () = log := 0; let t = (mark 1, mark 2, mark 3) in let (a, b, c) = t in Printf.printf "%d%d%d %d\n" a b c !log
let rec length = function [] -> 0 | _ :: t -> 1 + length t
let list_order () = log := 0; let l = [mark 1; mark 2] in Printf.printf "%d %d\n" (length l) !log

let () =
  let a, b = evaluation_order () in Printf.printf "%d,%d\n" a b;
  let a, b, c = shared_ref () in Printf.printf "%d,%d,%d\n" a b c;
  Printf.printf "%d\n" (sum 100000 0);
  let a, b = partial () in Printf.printf "%d,%d\n" a b;
  Printf.printf "%d %d %d %d\n" (payload (Number 5)) (payload Empty) (guarded (Number 5)) (guarded (Number 15));
  Printf.printf "%d:" (String.length binary);
  for i = 0 to String.length binary - 1 do Printf.printf "%d," (Char.code binary.[i]) done;
  print_string "\n";
  Printf.printf "%d %d\n" (bounds ()) (short_circuit ());
  let a, b, c = grouped () in Printf.printf "%d,%d,%d\n" a b c;
  let a, b = copy_order () in Printf.printf "%d,%d\n" a b;
  Printf.printf "%d %d %d\n" wide wrap unsigned;
  tuple_order ();
  list_order ()

(* boxed integer patterns, local exceptions *)
let kind32 = function 0l -> "zero" | 1l -> "one" | _ -> "many"
let kind64 = function 0L -> "zero" | -1L -> "minus" | _ -> "other"
let () = print_endline (kind32 0l ^ kind32 1l ^ kind32 7l ^ kind64 (-1L) ^ kind64 5L)
let find_first p l =
  let exception Found of int in
  try List.iter (fun x -> if p x then raise (Found x)) l; None with Found x -> Some x
let () = match find_first (fun x -> x > 2) [1; 2; 3; 4] with Some x -> Printf.printf "found %d\n" x | None -> print_endline "none"
let rec count_down n = if n = 0 then (incr calls; []) else n :: count_down (n - 1)
and calls = (print_endline "calls made"; ref 0)
let () =
  let rec w = function [] -> () | x :: r -> print_string (prefix ^ x); w r
  and prefix = (print_endline "prefix made"; "-") in
  w ["a"; "b"]; print_newline ();
  Printf.printf "%d %d\n" (List.length (count_down 3)) !calls

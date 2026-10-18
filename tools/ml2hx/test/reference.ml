open Semantics
let () =
  let a,b = evaluation_order () in Printf.printf "%d,%d\n" a b;
  let a,b,c = shared_ref () in Printf.printf "%d,%d,%d\n" a b c;
  Printf.printf "%d\n" (sum 100000 0);
  let a,b = partial () in Printf.printf "%d,%d\n" a b;
  Printf.printf "%d\n%d\n%d\n%d\n" (payload (Number 5)) (payload Empty) (guarded (Number 5)) (guarded (Number 15));
  Printf.printf "%d:%s\n" (String.length binary) (String.concat "," (List.init (String.length binary) (fun i -> string_of_int (Char.code binary.[i]))));
  Printf.printf "%d\n%d\n%d\n" wide wrap unsigned;
  Printf.printf "%d\n%d\n" (bounds ()) (short_circuit ());
  let a,b,c = grouped () in Printf.printf "%d,%d,%d\n" a b c;
  let a,b = copy_order () in Printf.printf "%d,%d\n" a b

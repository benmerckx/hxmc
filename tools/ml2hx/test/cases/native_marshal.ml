(* native: strings shared by physical identity in Marshal's output (hxmc's
   String objects have an identity; the interpreter's strings do not) *)
let () =
  let s = String.make 3 'a' in
  let t = String.make 3 'a' in
  let hex v = String.iter (fun c -> Printf.printf "%02x" (Char.code c)) (Marshal.to_string v []); print_newline () in
  hex (s, s, t, [s; t]);
  hex [| s; String.concat "" [s; t]; t |]

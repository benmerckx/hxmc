(* The Str library: matching, groups, substitution, splitting. *)
let show l = String.concat "|" l
let () =
  let r = Str.regexp "\\([a-z]+\\)\\([0-9]*\\)" in
  if Str.string_match r "abc123def" 0 then
    Printf.printf "%s %s %s %d\n" (Str.matched_string "abc123def") (Str.matched_group 1 "abc123def") (Str.matched_group 2 "abc123def") (Str.match_end ());
  Printf.printf "%d\n" (Str.search_forward (Str.regexp "[0-9]+") "ab12cd345" 4);
  print_endline (Str.global_replace (Str.regexp "a\\(b*\\)") "<\\1>" "abbbxaay");
  print_endline (show (Str.split (Str.regexp "[ \t]+") "  a b\t c  "));
  print_endline (show (Str.split_delim (Str.regexp ",") ",a,,b,"));
  List.iter (function Str.Text s -> Printf.printf "T(%s)" s | Str.Delim s -> Printf.printf "D(%s)" s) (Str.full_split (Str.regexp "[,;]") "a,b;;c");
  print_newline ();
  print_endline (Str.global_substitute (Str.regexp "[0-9]+") (fun s -> string_of_int (2 * int_of_string (Str.matched_string s))) "x1y22z");
  print_endline (Str.replace_first (Str.regexp_case_fold "HELLO") "bye" "say hello Hello");
  Printf.printf "%b %b\n" (Str.string_match (Str.regexp "a\\|ab\\|abc$") "abc" 0) (Str.string_match (Str.regexp "^x*$") "xxy" 0);
  print_endline (Str.matched_string "abc")

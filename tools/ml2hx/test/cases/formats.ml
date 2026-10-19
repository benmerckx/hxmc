(* Printf: literal formats compiled inline, formats as values, k-variants,
   conversions with flags, widths and precisions; string and char semantics. *)
let show fmt = Printf.sprintf fmt
let log fmt = Printf.ksprintf (fun s -> print_string ("[" ^ s ^ "]\n")) fmt
let () =
  Printf.printf "%d|%5d|%-5d|%05d|%x|%X|%o|%u\n" 42 42 42 42 255 255 8 7;
  Printf.printf "%s|%10s|%-10s|%S|%c|%C|%b\n" "ab" "ab" "ab" "a\"b\n" 'z' '\'' true;
  Printf.printf "%f|%.2f|%e|%g|%g|%F|%.3g\n" 3.14159 2.5 12345.678 0.0001 1e20 1.0 3.14159;
  Printf.printf "%ld|%Ld|%nd\n" 7l 8L 9n;
  print_string (show "%d-%s\n" 1 "x");
  log "%d+%d" 2 3;
  let b = Buffer.create 10 in
  Printf.bprintf b "%s=%d;" "k" 5;
  print_endline (Buffer.contents b);
  let s = "h\233llo" in
  Printf.printf "%d %d %s\n" (String.length s) (Char.code s.[1]) (String.uppercase_ascii "abc");
  let by = Bytes.of_string "abc" in
  Bytes.set by 1 'X';
  print_endline (Bytes.to_string by)

let () =
  Printf.printf "[%*s][%-*d][%.*f][%*.*f]\n" 6 "ab" 5 42 2 3.14159 8 3 2.5;
  let pad w s = Printf.sprintf "%*s|" w s in
  print_endline (pad 4 "x" ^ pad (-4) "y")

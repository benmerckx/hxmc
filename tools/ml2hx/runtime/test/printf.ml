(* Printf over printf.cases (format, type, value): each line printed as
   "<format> <value> => [<result>]". *)
let unhex s = String.init (String.length s / 2) (fun i -> Char.chr (int_of_string ("0x" ^ String.sub s (2 * i) 2)))

let run fmt ty v =
  let open Scanf in
  match ty with
  | "i" -> Printf.sprintf (format_from_string fmt "%d") (int_of_string v)
  | "l" -> Printf.sprintf (format_from_string fmt "%ld") (Int32.of_string v)
  | "L" -> Printf.sprintf (format_from_string fmt "%Ld") (Int64.of_string v)
  | "f" -> Printf.sprintf (format_from_string fmt "%f") (float_of_string v)
  | "s" -> Printf.sprintf (format_from_string fmt "%s") v
  | "sx" -> Printf.sprintf (format_from_string fmt "%s") (unhex v)
  | "c" -> Printf.sprintf (format_from_string fmt "%c") (Char.chr (int_of_string v))
  | "b" -> Printf.sprintf (format_from_string fmt "%b") (bool_of_string v)
  | _ -> failwith ty

let () =
  let ic = open_in_bin (Filename.concat Sys.argv.(1) "printf.cases") in
  (try
     while true do
       let line = input_line ic in
       if line <> "" && line.[0] <> '#' then
         match String.split_on_char '\t' line with
         | [fmt; ty; v] ->
             let r = try run fmt ty v with e -> "exception " ^ Printexc.to_string e in
             print_endline (fmt ^ " " ^ v ^ " => [" ^ r ^ "]")
         | _ -> failwith line
     done
   with End_of_file -> ());
  (* the star forms and several conversions in one format *)
  print_endline (Printf.sprintf "%*d|%-*d|%.*f|%*.*f" 6 42 6 42 2 3.14159 10 3 2.5);
  print_endline (Printf.sprintf "%-*s|%*s|" 8 "ab" (-8) "cd");
  print_endline (Printf.sprintf "%d %s %c %b %f %ld %Ld %%%% %x@,%!" 1 "two" '3' true 4.5 6l 7L 255);
  print_endline (Printf.sprintf "%a and %t" (fun () x -> "<" ^ x ^ ">") "alpha" (fun () -> "theta"));
  let b = Buffer.create 16 in
  Printf.bprintf b "%s=%d;" "x" 1;
  Printf.bprintf b "%a" (fun b x -> Buffer.add_string b (string_of_int x)) 99;
  print_endline (Buffer.contents b);
  print_endline (Printf.ksprintf (fun s -> "k:" ^ s) "%d-%d" 1 2);
  Printf.printf "printf %s %d\n" "to stdout" 3;
  Printf.fprintf stdout "fprintf %S\n" "q\"uote"

(* ml2hx replacement of OCaml 5.3's stdlib/string.ml (LGPL 2.1 with the
   OCaml linking exception, see its header below): the same module with the
   character-level decoders (get_utf_8_uchar, is_valid_utf_8, the UTF-16 ones
   and the binary integer getters) written over the string, as bytes.ml
   writes them over bytes, instead of applied to [Bytes.unsafe_of_string s]:
   strings and bytes are different values once transpiled, so that view is a
   copy, and a decoder called per character copied the whole string each
   time. (tools/ml2hx/README.md, Replacements) *)
(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*           Damien Doligez, projet Gallium, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 2014 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* String operations, based on byte sequence operations *)

(* WARNING: Some functions in this file are duplicated in bytes.ml for
   efficiency reasons. When you modify the one in this file you need to
   modify its duplicate in bytes.ml.
   These functions have a "duplicated" comment above their definition.
*)

external length : string -> int = "%string_length"
external get : string -> int -> char = "%string_safe_get"
external unsafe_get : string -> int -> char = "%string_unsafe_get"
external unsafe_blit : string -> int ->  bytes -> int -> int -> unit
                     = "caml_blit_string" [@@noalloc]

module B = Bytes

let bts = B.unsafe_to_string
let bos = B.unsafe_of_string

let make n c =
  B.make n c |> bts
let init n f =
  B.init n f |> bts
let empty = ""
let of_bytes = B.to_string
let to_bytes = B.of_string
let sub s ofs len =
  B.sub (bos s) ofs len |> bts
let blit =
  B.blit_string

let ensure_ge (x:int) y = if x >= y then x else invalid_arg "String.concat"

let rec sum_lengths acc seplen = function
  | [] -> acc
  | hd :: [] -> length hd + acc
  | hd :: tl -> sum_lengths (ensure_ge (length hd + seplen + acc) acc) seplen tl

let rec unsafe_blits dst pos sep seplen = function
    [] -> dst
  | hd :: [] ->
    unsafe_blit hd 0 dst pos (length hd); dst
  | hd :: tl ->
    unsafe_blit hd 0 dst pos (length hd);
    unsafe_blit sep 0 dst (pos + length hd) seplen;
    unsafe_blits dst (pos + length hd + seplen) sep seplen tl

let concat sep = function
    [] -> ""
  | l -> let seplen = length sep in bts @@
          unsafe_blits
            (B.create (sum_lengths 0 seplen l))
            0 sep seplen l

let cat = ( ^ )

(* duplicated in bytes.ml *)
let iter f s =
  for i = 0 to length s - 1 do f (unsafe_get s i) done

(* duplicated in bytes.ml *)
let iteri f s =
  for i = 0 to length s - 1 do f i (unsafe_get s i) done

let map f s =
  B.map f (bos s) |> bts
let mapi f s =
  B.mapi f (bos s) |> bts
let fold_right f x a =
  B.fold_right f (bos x) a
let fold_left f a x =
  B.fold_left f a (bos x)
let exists f s =
  B.exists f (bos s)
let for_all f s =
  B.for_all f (bos s)

(* Beware: we cannot use B.trim or B.escape because they always make a
   copy, but String.mli spells out some cases where we are not allowed
   to make a copy. *)

let is_space = function
  | ' ' | '\012' | '\n' | '\r' | '\t' -> true
  | _ -> false

let trim s =
  if s = "" then s
  else if is_space (unsafe_get s 0) || is_space (unsafe_get s (length s - 1))
    then bts (B.trim (bos s))
  else s

let escaped s =
  let b = bos s in
  (* We satisfy [unsafe_escape]'s precondition by passing an
     immutable byte sequence [b]. *)
  let b' = B.unsafe_escape b in
  (* With js_of_ocaml, [bos] and [bts] are not the identity.
     We can avoid a [bts] conversion if [unsafe_escape] returned
     its argument. *)
  if b == b' then s else bts b'

(* duplicated in bytes.ml *)
let rec index_rec s lim i c =
  if i >= lim then raise Not_found else
  if unsafe_get s i = c then i else index_rec s lim (i + 1) c

(* duplicated in bytes.ml *)
let index s c = index_rec s (length s) 0 c

(* duplicated in bytes.ml *)
let rec index_rec_opt s lim i c =
  if i >= lim then None else
  if unsafe_get s i = c then Some i else index_rec_opt s lim (i + 1) c

(* duplicated in bytes.ml *)
let index_opt s c = index_rec_opt s (length s) 0 c

(* duplicated in bytes.ml *)
let index_from s i c =
  let l = length s in
  if i < 0 || i > l then invalid_arg "String.index_from / Bytes.index_from" else
    index_rec s l i c

(* duplicated in bytes.ml *)
let index_from_opt s i c =
  let l = length s in
  if i < 0 || i > l then
    invalid_arg "String.index_from_opt / Bytes.index_from_opt"
  else
    index_rec_opt s l i c

(* duplicated in bytes.ml *)
let rec rindex_rec s i c =
  if i < 0 then raise Not_found else
  if unsafe_get s i = c then i else rindex_rec s (i - 1) c

(* duplicated in bytes.ml *)
let rindex s c = rindex_rec s (length s - 1) c

(* duplicated in bytes.ml *)
let rindex_from s i c =
  if i < -1 || i >= length s then
    invalid_arg "String.rindex_from / Bytes.rindex_from"
  else
    rindex_rec s i c

(* duplicated in bytes.ml *)
let rec rindex_rec_opt s i c =
  if i < 0 then None else
  if unsafe_get s i = c then Some i else rindex_rec_opt s (i - 1) c

(* duplicated in bytes.ml *)
let rindex_opt s c = rindex_rec_opt s (length s - 1) c

(* duplicated in bytes.ml *)
let rindex_from_opt s i c =
  if i < -1 || i >= length s then
    invalid_arg "String.rindex_from_opt / Bytes.rindex_from_opt"
  else
    rindex_rec_opt s i c

(* duplicated in bytes.ml *)
let contains_from s i c =
  let l = length s in
  if i < 0 || i > l then
    invalid_arg "String.contains_from / Bytes.contains_from"
  else
    try ignore (index_rec s l i c); true with Not_found -> false

(* duplicated in bytes.ml *)
let contains s c = contains_from s 0 c

(* duplicated in bytes.ml *)
let rcontains_from s i c =
  if i < 0 || i >= length s then
    invalid_arg "String.rcontains_from / Bytes.rcontains_from"
  else
    try ignore (rindex_rec s i c); true with Not_found -> false

let uppercase_ascii s =
  B.uppercase_ascii (bos s) |> bts
let lowercase_ascii s =
  B.lowercase_ascii (bos s) |> bts
let capitalize_ascii s =
  B.capitalize_ascii (bos s) |> bts
let uncapitalize_ascii s =
  B.uncapitalize_ascii (bos s) |> bts

(* duplicated in bytes.ml *)
let starts_with ~prefix s =
  let len_s = length s
  and len_pre = length prefix in
  let rec aux i =
    if i = len_pre then true
    else if unsafe_get s i <> unsafe_get prefix i then false
    else aux (i + 1)
  in len_s >= len_pre && aux 0

(* duplicated in bytes.ml *)
let ends_with ~suffix s =
  let len_s = length s
  and len_suf = length suffix in
  let diff = len_s - len_suf in
  let rec aux i =
    if i = len_suf then true
    else if unsafe_get s (diff + i) <> unsafe_get suffix i then false
    else aux (i + 1)
  in diff >= 0 && aux 0

external seeded_hash : int -> string -> int = "caml_string_hash" [@@noalloc]
let hash x = seeded_hash 0 x

(* duplicated in bytes.ml *)
let split_on_char sep s =
  let r = ref [] in
  let j = ref (length s) in
  for i = length s - 1 downto 0 do
    if unsafe_get s i = sep then begin
      r := sub s (i + 1) (!j - i - 1) :: !r;
      j := i
    end
  done;
  sub s 0 !j :: !r

type t = string

let compare (x: t) (y: t) = Stdlib.compare x y
external equal : string -> string -> bool = "caml_string_equal" [@@noalloc]

(** {1 Iterators} *)

let to_seq s = bos s |> B.to_seq

let to_seqi s = bos s |> B.to_seqi

let of_seq g = B.of_seq g |> bts

(* UTF decoders and validators *)

(* (decoded here, as in bytes.ml, rather than through B on (bos s)) *)
external unsafe_get_uint8 : string -> int -> int = "%string_unsafe_get"
external unsafe_get_uint16_ne : string -> int -> int = "%caml_string_get16u"
external get_uint8 : string -> int -> int = "%string_safe_get"
external get_uint16_ne : string -> int -> int = "%caml_string_get16"
external get_int32_ne : string -> int -> int32 = "%caml_string_get32"
external get_int64_ne : string -> int -> int64 = "%caml_string_get64"
external swap16 : int -> int = "%bswap16"
external swap32 : int32 -> int32 = "%bswap_int32"
external swap64 : int64 -> int64 = "%bswap_int64"

let unsafe_get_uint16_le b i =
  if Sys.big_endian
  then swap16 (unsafe_get_uint16_ne b i)
  else unsafe_get_uint16_ne b i

let unsafe_get_uint16_be b i =
  if Sys.big_endian
  then unsafe_get_uint16_ne b i
  else swap16 (unsafe_get_uint16_ne b i)

let dec_invalid = Uchar.utf_decode_invalid
let[@inline] dec_ret n u = Uchar.utf_decode n (Uchar.unsafe_of_int u)

(* In case of decoding error, if we error on the first byte, we
   consume the byte, otherwise we consume the [n] bytes preceding
   the erroring byte.

   This means that if a client uses decodes without caring about
   validity it naturally replace bogus data with Uchar.rep according
   to the WHATWG Encoding standard. Other schemes are possible by
   consulting the number of used bytes on invalid decodes. For more
   details see https://hsivonen.fi/broken-utf-8/

   For this reason in [get_utf_8_uchar] we gradually check the next
   byte is available rather than doing it immediately after the
   first byte. Contrast with [is_valid_utf_8]. *)

(* UTF-8 *)

let[@inline] not_in_x80_to_xBF b = b lsr 6 <> 0b10
let[@inline] not_in_xA0_to_xBF b = b lsr 5 <> 0b101
let[@inline] not_in_x80_to_x9F b = b lsr 5 <> 0b100
let[@inline] not_in_x90_to_xBF b = b < 0x90 || 0xBF < b
let[@inline] not_in_x80_to_x8F b = b lsr 4 <> 0x8

let[@inline] utf_8_uchar_2 b0 b1 =
  ((b0 land 0x1F) lsl 6) lor
  ((b1 land 0x3F))

let[@inline] utf_8_uchar_3 b0 b1 b2 =
  ((b0 land 0x0F) lsl 12) lor
  ((b1 land 0x3F) lsl 6) lor
  ((b2 land 0x3F))

let[@inline] utf_8_uchar_4 b0 b1 b2 b3 =
  ((b0 land 0x07) lsl 18) lor
  ((b1 land 0x3F) lsl 12) lor
  ((b2 land 0x3F) lsl 6) lor
  ((b3 land 0x3F))

let get_utf_8_uchar b i =
  let b0 = get_uint8 b i in (* raises if [i] is not a valid index. *)
  let get = unsafe_get_uint8 in
  let max = length b - 1 in
  match Char.unsafe_chr b0 with (* See The Unicode Standard, Table 3.7 *)
  | '\x00' .. '\x7F' -> dec_ret 1 b0
  | '\xC2' .. '\xDF' ->
      let i = i + 1 in if i > max then dec_invalid 1 else
      let b1 = get b i in if not_in_x80_to_xBF b1 then dec_invalid 1 else
      dec_ret 2 (utf_8_uchar_2 b0 b1)
  | '\xE0' ->
      let i = i + 1 in if i > max then dec_invalid 1 else
      let b1 = get b i in if not_in_xA0_to_xBF b1 then dec_invalid 1 else
      let i = i + 1 in if i > max then dec_invalid 2 else
      let b2 = get b i in if not_in_x80_to_xBF b2 then dec_invalid 2 else
      dec_ret 3 (utf_8_uchar_3 b0 b1 b2)
  | '\xE1' .. '\xEC' | '\xEE' .. '\xEF' ->
      let i = i + 1 in if i > max then dec_invalid 1 else
      let b1 = get b i in if not_in_x80_to_xBF b1 then dec_invalid 1 else
      let i = i + 1 in if i > max then dec_invalid 2 else
      let b2 = get b i in if not_in_x80_to_xBF b2 then dec_invalid 2 else
      dec_ret 3 (utf_8_uchar_3 b0 b1 b2)
  | '\xED' ->
      let i = i + 1 in if i > max then dec_invalid 1 else
      let b1 = get b i in if not_in_x80_to_x9F b1 then dec_invalid 1 else
      let i = i + 1 in if i > max then dec_invalid 2 else
      let b2 = get b i in if not_in_x80_to_xBF b2 then dec_invalid 2 else
      dec_ret 3 (utf_8_uchar_3 b0 b1 b2)
  | '\xF0' ->
      let i = i + 1 in if i > max then dec_invalid 1 else
      let b1 = get b i in if not_in_x90_to_xBF b1 then dec_invalid 1 else
      let i = i + 1 in if i > max then dec_invalid 2 else
      let b2 = get b i in if not_in_x80_to_xBF b2 then dec_invalid 2 else
      let i = i + 1 in if i > max then dec_invalid 3 else
      let b3 = get b i in if not_in_x80_to_xBF b3 then dec_invalid 3 else
      dec_ret 4 (utf_8_uchar_4 b0 b1 b2 b3)
  | '\xF1' .. '\xF3' ->
      let i = i + 1 in if i > max then dec_invalid 1 else
      let b1 = get b i in if not_in_x80_to_xBF b1 then dec_invalid 1 else
      let i = i + 1 in if i > max then dec_invalid 2 else
      let b2 = get b i in if not_in_x80_to_xBF b2 then dec_invalid 2 else
      let i = i + 1 in if i > max then dec_invalid 3 else
      let b3 = get b i in if not_in_x80_to_xBF b3 then dec_invalid 3 else
      dec_ret 4 (utf_8_uchar_4 b0 b1 b2 b3)
  | '\xF4' ->
      let i = i + 1 in if i > max then dec_invalid 1 else
      let b1 = get b i in if not_in_x80_to_x8F b1 then dec_invalid 1 else
      let i = i + 1 in if i > max then dec_invalid 2 else
      let b2 = get b i in if not_in_x80_to_xBF b2 then dec_invalid 2 else
      let i = i + 1 in if i > max then dec_invalid 3 else
      let b3 = get b i in if not_in_x80_to_xBF b3 then dec_invalid 3 else
      dec_ret 4 (utf_8_uchar_4 b0 b1 b2 b3)
  | _ -> dec_invalid 1

let is_valid_utf_8 b =
  let rec loop max b i =
    if i > max then true else
    let get = unsafe_get_uint8 in
    match Char.unsafe_chr (get b i) with
    | '\x00' .. '\x7F' -> loop max b (i + 1)
    | '\xC2' .. '\xDF' ->
        let last = i + 1 in
        if last > max
        || not_in_x80_to_xBF (get b last)
        then false
        else loop max b (last + 1)
    | '\xE0' ->
        let last = i + 2 in
        if last > max
        || not_in_xA0_to_xBF (get b (i + 1))
        || not_in_x80_to_xBF (get b last)
        then false
        else loop max b (last + 1)
    | '\xE1' .. '\xEC' | '\xEE' .. '\xEF' ->
        let last = i + 2 in
        if last > max
        || not_in_x80_to_xBF (get b (i + 1))
        || not_in_x80_to_xBF (get b last)
        then false
        else loop max b (last + 1)
    | '\xED' ->
        let last = i + 2 in
        if last > max
        || not_in_x80_to_x9F (get b (i + 1))
        || not_in_x80_to_xBF (get b last)
        then false
        else loop max b (last + 1)
    | '\xF0' ->
        let last = i + 3 in
        if last > max
        || not_in_x90_to_xBF (get b (i + 1))
        || not_in_x80_to_xBF (get b (i + 2))
        || not_in_x80_to_xBF (get b last)
        then false
        else loop max b (last + 1)
    | '\xF1' .. '\xF3' ->
        let last = i + 3 in
        if last > max
        || not_in_x80_to_xBF (get b (i + 1))
        || not_in_x80_to_xBF (get b (i + 2))
        || not_in_x80_to_xBF (get b last)
        then false
        else loop max b (last + 1)
    | '\xF4' ->
        let last = i + 3 in
        if last > max
        || not_in_x80_to_x8F (get b (i + 1))
        || not_in_x80_to_xBF (get b (i + 2))
        || not_in_x80_to_xBF (get b last)
        then false
        else loop max b (last + 1)
    | _ -> false
  in
  loop (length b - 1) b 0

(* UTF-16BE *)

let get_utf_16be_uchar b i =
  let get = unsafe_get_uint16_be in
  let max = length b - 1 in
  if i < 0 || i > max then invalid_arg "index out of bounds" else
  if i = max then dec_invalid 1 else
  match get b i with
  | u when u < 0xD800 || u > 0xDFFF -> dec_ret 2 u
  | u when u > 0xDBFF -> dec_invalid 2
  | hi -> (* combine [hi] with a low surrogate *)
      let last = i + 3 in
      if last > max then dec_invalid (max - i + 1) else
      match get b (i + 2) with
      | u when u < 0xDC00 || u > 0xDFFF -> dec_invalid 2 (* retry here *)
      | lo ->
          let u = (((hi land 0x3FF) lsl 10) lor (lo land 0x3FF)) + 0x10000 in
          dec_ret 4 u

let is_valid_utf_16be b =
  let rec loop max b i =
    let get = unsafe_get_uint16_be in
    if i > max then true else
    if i = max then false else
    match get b i with
    | u when u < 0xD800 || u > 0xDFFF -> loop max b (i + 2)
    | u when u > 0xDBFF -> false
    | _hi ->
        let last = i + 3 in
        if last > max then false else
        match get b (i + 2) with
        | u when u < 0xDC00 || u > 0xDFFF -> false
        | _lo -> loop max b (i + 4)
  in
  loop (length b - 1) b 0

(* UTF-16LE *)

let get_utf_16le_uchar b i =
  let get = unsafe_get_uint16_le in
  let max = length b - 1 in
  if i < 0 || i > max then invalid_arg "index out of bounds" else
  if i = max then dec_invalid 1 else
  match get b i with
  | u when u < 0xD800 || u > 0xDFFF -> dec_ret 2 u
  | u when u > 0xDBFF -> dec_invalid 2
  | hi -> (* combine [hi] with a low surrogate *)
      let last = i + 3 in
      if last > max then dec_invalid (max - i + 1) else
      match get b (i + 2) with
      | u when u < 0xDC00 || u > 0xDFFF -> dec_invalid 2 (* retry here *)
      | lo ->
          let u = (((hi land 0x3FF) lsl 10) lor (lo land 0x3FF)) + 0x10000 in
          dec_ret 4 u

let is_valid_utf_16le b =
  let rec loop max b i =
    let get = unsafe_get_uint16_le in
    if i > max then true else
    if i = max then false else
    match get b i with
    | u when u < 0xD800 || u > 0xDFFF -> loop max b (i + 2)
    | u when u > 0xDBFF -> false
    | _hi ->
        let last = i + 3 in
        if last > max then false else
        match get b (i + 2) with
        | u when u < 0xDC00 || u > 0xDFFF -> false
        | _lo -> loop max b (i + 4)
  in
  loop (length b - 1) b 0


(** {6 Binary encoding/decoding of integers} *)

external get_uint8 : string -> int -> int = "%string_safe_get"
external get_uint16_ne : string -> int -> int = "%caml_string_get16"
external get_int32_ne : string -> int -> int32 = "%caml_string_get32"
external get_int64_ne : string -> int -> int64 = "%caml_string_get64"

let get_int8 b i =
  ((get_uint8 b i) lsl (Sys.int_size - 8)) asr (Sys.int_size - 8)

let get_uint16_le b i =
  if Sys.big_endian then swap16 (get_uint16_ne b i)
  else get_uint16_ne b i

let get_uint16_be b i =
  if not Sys.big_endian then swap16 (get_uint16_ne b i)
  else get_uint16_ne b i

let get_int16_ne b i =
  ((get_uint16_ne b i) lsl (Sys.int_size - 16)) asr (Sys.int_size - 16)

let get_int16_le b i =
  ((get_uint16_le b i) lsl (Sys.int_size - 16)) asr (Sys.int_size - 16)

let get_int16_be b i =
  ((get_uint16_be b i) lsl (Sys.int_size - 16)) asr (Sys.int_size - 16)

let get_int32_le b i =
  if Sys.big_endian then swap32 (get_int32_ne b i)
  else get_int32_ne b i

let get_int32_be b i =
  if not Sys.big_endian then swap32 (get_int32_ne b i)
  else get_int32_ne b i

let get_int64_le b i =
  if Sys.big_endian then swap64 (get_int64_ne b i)
  else get_int64_ne b i

let get_int64_be b i =
  if not Sys.big_endian then swap64 (get_int64_ne b i)
  else get_int64_ne b i


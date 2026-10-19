(* ml2hx replacement of extlib 1.8's extList.ml (LGPL 2.1 with the OCaml linking
   exception, see its header below): the same module without the mutable
   cons cells it builds lists with (a record injected into 'a list with
   %identity), which the transpiled list representation cannot share. Each
   such function is written with an accumulator instead; it applies its
   function arguments in the same order and returns equal lists (sharing the
   same unchanged tails in remove, remove_if and the remove_assocs).
   (tools/ml2hx/README.md, Replacements) *)
(*
 * ExtList - additional and modified functions for lists.
 * Copyright (C) 2003 Brian Hurt
 * Copyright (C) 2003 Nicolas Cannasse
 * Copyright (C) 2008 Red Hat Inc.
 * 
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version,
 * with the special exception on linking described in file LICENSE.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *)


module List = struct


exception Empty_list
exception Invalid_index of int
exception Different_list_size of string

include List


let hd = function
  | [] -> raise Empty_list
  | h :: t -> h

let tl = function
  | [] -> raise Empty_list
  | h :: t -> t

let nth l index =
  if index < 0 then raise (Invalid_index index);
  let rec loop n = function
    | [] -> raise (Invalid_index index);
    | h :: t ->
      if n = 0 then h else loop (n - 1) t
  in
  loop index l

let append l1 l2 =
  match l1 with
  | [] -> l2
  | _ -> rev_append (rev l1) l2
let rec flatten l =
  rev (fold_left (fun acc x -> rev_append x acc) [] l)
let concat = flatten

let map f l =
  let rec loop acc = function
    | [] -> rev acc
    | h :: t -> let x = f h in loop (x :: acc) t
  in
  loop [] l
let rec drop n = function
  | _ :: l when n > 0 -> drop (n-1) l
  | l -> l

let take n l =
  let rec loop n acc = function
    | h :: t when n > 0 -> loop (n-1) (h :: acc) t
    | _ -> rev acc
  in
  loop n [] l
(* takewhile and dropwhile by Richard W.M. Jones. *)
let rec takewhile f = function
  | [] -> []
  | x :: xs when f x -> x :: takewhile f xs
  | _ -> []

let rec dropwhile f = function
  | [] -> []
  | x :: xs when f x -> dropwhile f xs
  | xs -> xs


let rec unique ?(cmp = ( = )) l =
  let rec loop acc = function
    | [] -> rev acc
    | h :: t ->
      match exists (cmp h) t with
      | true -> loop acc t
      | false -> loop (h :: acc) t
  in
  loop [] l
let filter_map f l =
  let rec loop acc = function
    | [] -> rev acc
    | h :: t ->
      match f h with
      | None -> loop acc t
      | Some x -> loop (x :: acc) t
  in
  loop [] l
let rec find_map_exn f = function
  | [] -> raise Not_found
  | x :: xs ->
      match f x with
      | Some y -> y
      | None -> find_map_exn f xs

let rec find_map_opt f = function
  | [] -> None
  | x :: xs ->
      match f x with
      | Some _ as y -> y
      | None -> find_map_opt f xs

let find_map = find_map_opt

let filteri f l =
  let rec findnext i acc = function
    | [] -> rev acc
    | h :: t -> if f i h then findnext (i+1) (h :: acc) t else findnext (i+1) acc t
  in
  findnext 0 [] l
let fold_left_map f accu l =
  let rec aux accu acc = function
    | [] -> accu, rev acc
    | x :: l ->
        let accu, x = f accu x in
        aux accu (x :: acc) l
  in
  aux accu [] l
let fold_right_max = 1000

let fold_right f l init =
  let rec tail_loop acc = function
    | [] -> acc
    | h :: t -> tail_loop (f h acc) t
  in
  let rec loop n = function
    | [] -> init
    | h :: t ->
      if n < fold_right_max then
        f h (loop (n+1) t)
      else
        f h (tail_loop init (rev t))
  in
  loop 0 l

let map2 f l1 l2 =
  let rec loop acc src1 src2 =
    match src1, src2 with
      | [], [] -> rev acc
      | h1 :: t1, h2 :: t2 -> let x = f h1 h2 in loop (x :: acc) t1 t2
      | _ -> raise (Different_list_size "map2")
  in
  loop [] l1 l2
let rev_map2 f l1 l2 =
  let rec loop acc l1 l2 =
    match l1, l2 with
    | [], [] -> acc
    | h1 :: t1, h2 :: t2 -> loop (f h1 h2 :: acc) t1 t2
    | _ -> raise (Different_list_size "rev_map2")
  in
  loop [] l1 l2

let rec iter2 f l1 l2 =
  match l1, l2 with
  | [], [] -> ()
  | h1 :: t1, h2 :: t2 -> f h1 h2; iter2 f t1 t2
  | _ -> raise (Different_list_size "iter2")

let rec fold_left2 f accum l1 l2 =
  match l1, l2 with
  | [], [] -> accum
  | h1 :: t1, h2 :: t2 -> fold_left2 f (f accum h1 h2) t1 t2
  | _ -> raise (Different_list_size "fold_left2")

let fold_right2 f l1 l2 init =
  let rec tail_loop acc l1 l2 =
    match l1, l2 with
    | [] , [] -> acc
    | h1 :: t1 , h2 :: t2 -> tail_loop (f h1 h2 acc) t1 t2
    | _ -> raise (Different_list_size "fold_right2")
  in
  let rec loop n l1 l2 =
    match l1, l2 with
    | [], [] -> init
    | h1 :: t1, h2 :: t2 ->
      if n < fold_right_max then
        f h1 h2 (loop (n+1) t1 t2)
      else
        f h1 h2 (tail_loop init (rev t1) (rev t2))
    | _ -> raise (Different_list_size "fold_right2")
  in
  loop 0 l1 l2

let for_all2 p l1 l2 =
  let rec loop l1 l2 =
    match l1, l2 with
    | [], [] -> true
    | h1 :: t1, h2 :: t2 -> if p h1 h2 then loop t1 t2 else false
    | _ -> raise (Different_list_size "for_all2")
  in
  loop l1 l2

let exists2 p l1 l2 =
  let rec loop l1 l2 =
    match l1, l2 with
      | [], [] -> false
      | h1 :: t1, h2 :: t2 -> if p h1 h2 then true else loop t1 t2
      | _ -> raise (Different_list_size "exists2")
  in
  loop l1 l2

let remove_assoc x lst =
  let rec loop acc = function
    | [] -> rev acc
    | (a, _ as pair) :: t -> if a = x then rev_append acc t else loop (pair :: acc) t
  in
  loop [] lst
let remove_assq x lst =
  let rec loop acc = function
    | [] -> rev acc
    | (a, _ as pair) :: t -> if a == x then rev_append acc t else loop (pair :: acc) t
  in
  loop [] lst
let rfind p l = find p (rev l)

let find_all p l =
  let rec findnext acc = function
    | [] -> rev acc
    | h :: t -> if p h then findnext (h :: acc) t else findnext acc t
  in
  findnext [] l
let rec findi p l =
  let rec loop n = function
    | [] -> raise Not_found
    | h :: t ->
      if p n h then (n,h) else loop (n+1) t
  in
  loop 0 l

let filter = find_all

let partition p lst =
  let rec loop yes no = function
    | [] -> rev yes, rev no
    | h :: t -> if p h then loop (h :: yes) no t else loop yes (h :: no) t
  in
  loop [] [] lst
let split lst =
  let rec loop a b = function
    | [] -> rev a, rev b
    | (x, y) :: t -> loop (x :: a) (y :: b) t
  in
  loop [] [] lst
let combine l1 l2 =
  let rec loop acc l1 l2 =
    match l1, l2 with
    | [], [] -> rev acc
    | h1 :: t1, h2 :: t2 -> loop ((h1, h2) :: acc) t1 t2
    | _, _ -> raise (Different_list_size "combine")
  in
  loop [] l1 l2
let sort ?(cmp=Stdlib.compare) = List.sort cmp


let make i x =
  if i < 0 then invalid_arg "ExtList.List.make";
  let rec loop acc x = function
  | 0 -> acc
  | i -> loop (x::acc) x (i-1)
  in
  loop [] x i

let mapi f l =
  let rec loop acc n = function
    | [] -> rev acc
    | h :: t -> let x = f n h in loop (x :: acc) (n+1) t
  in
  loop [] 0 l
let first = hd

let rec last = function
  | [] -> raise Empty_list
  | h :: [] -> h
  | _ :: t -> last t

let split_nth index = function
  | [] -> if index = 0 then [],[] else raise (Invalid_index index)
  | (h :: t as l) ->
    if index = 0 then [],l
    else if index < 0 then raise (Invalid_index index)
    else
      let rec loop n acc l =
        if n = 0 then rev acc, l else
        match l with
        | [] -> raise (Invalid_index index)
        | h :: t -> loop (n-1) (h :: acc) t
      in
      loop (index-1) [h] t
let find_exc f e l =
  try
    find f l
  with
    Not_found -> raise e

let remove l x =
  let rec loop acc = function
    | [] -> rev acc
    | h :: t -> if x = h then rev_append acc t else loop (h :: acc) t
  in
  loop [] l
let rec remove_if f lst =
  let rec loop acc = function
    | [] -> rev acc
    | x :: l -> if f x then rev_append acc l else loop (x :: acc) l
  in
  loop [] lst
let rec remove_all l x =
  let rec loop acc = function
    | [] -> rev acc
    | h :: t -> if x = h then loop acc t else loop (h :: acc) t
  in
  loop [] l
let enum l =
  let rec make lr count =
    Enum.make
      ~next:(fun () ->
        match !lr with
        | [] -> raise Enum.No_more_elements
        | h :: t ->
          decr count;
          lr := t;
          h
      )
      ~count:(fun () ->
        if !count < 0 then count := length !lr;
        !count
      )
      ~clone:(fun () ->
        make (ref !lr) (ref !count)
      )
  in
  make (ref l) (ref (-1))

let of_enum e =
  rev (Enum.fold (fun x acc -> x :: acc) [] e)
end

let ( @ ) = List.append

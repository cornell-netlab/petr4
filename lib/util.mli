(* Copyright 2019-present Cornell University
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy
 * of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software 
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT 
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the 
 * License for the specific language governing permissions and limitations 
 * under the License. 
 *)

type ('a,'b) alternative = 
    Left of 'a 
  | Right of 'b
  [@@deriving sexp,yojson]

val option_map: ('a -> 'b) -> 'a option -> 'b option

val uncurry: ('a -> 'b -> 'c) -> 'a * 'b -> 'c

val combine_opt: 'a list -> 'b list -> ('a option * 'b option) list

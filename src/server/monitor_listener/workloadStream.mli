(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

type workload = ServerEnv.env -> ServerEnv.env Lwt.t

type parallelizable_workload = ServerEnv.env -> unit Lwt.t

type t

val create : unit -> t

val push : name:string -> workload -> t -> unit

val push_parallelizable : name:string -> parallelizable_workload -> t -> unit

val requeue_parallelizable : name:string -> parallelizable_workload -> t -> unit

val pop : t -> workload option

val pop_parallelizable : t -> parallelizable_workload option

val wait_for_workload : t -> unit Lwt.t

val wait_for_parallelizable_workload : t -> unit Lwt.t

(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2

let tests =
  "utils"
  >::: [
         Line_test.tests;
         Nel_test.tests;
         ResizableArray_test.tests;
         Graph_test.tests;
         Cache_test.tests;
       ]

let () = run_test_tt_main tests

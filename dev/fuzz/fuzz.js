// The fuzz target: parses the input and calls every accessor on the result
// (test/eml/support.gleam, `exercise`). Any exception is a finding.
import { exercise } from "../../build/dev/javascript/eml/eml/support.mjs";
import { BitArray } from "../../build/dev/javascript/eml/gleam.mjs";

export function fuzz(data) {
  exercise(new BitArray(new Uint8Array(data)));
}

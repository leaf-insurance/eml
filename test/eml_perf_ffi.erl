-module(eml_perf_ffi).
-export([now_us/0]).

now_us() -> erlang:monotonic_time(microsecond).

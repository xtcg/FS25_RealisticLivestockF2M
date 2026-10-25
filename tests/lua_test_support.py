"""Shared Lua bootstrapping and result conversion for offline species tools.

Scenario selection, scientific references and verdicts belong to each species.
This module neither runs a simulation nor changes its calibration thresholds.
"""
import glob
import os

import lupa

TESTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TESTS)


def new_runtime():
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().REPO = REPO + "/"
    lua.globals().listRepoLua = lambda sub: lua.table_from(sorted(
        os.path.relpath(path, REPO)
        for path in glob.glob(os.path.join(REPO, sub, "**", "*.lua"), recursive=True)))
    with open(os.path.join(TESTS, "stubs.lua"), encoding="utf-8") as handle:
        lua.execute(handle.read())
    return lua


def to_python(value):
    if lupa.lua_type(value) == "table":
        keys = list(value.keys())
        if keys and all(isinstance(key, int) for key in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
            return [to_python(value[key]) for key in sorted(keys)]
        return {str(key): to_python(value[key]) for key in keys}
    return value

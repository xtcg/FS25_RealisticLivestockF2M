"""Static check of scripts/main.lua's source order.

main.lua says in comments which files "must follow" another because they read a sibling at file
scope; only a game run ever caught a violation. This reads every sourced file, finds the globals
it assigns at file scope and the globals it touches at file scope (outside any function body),
and fails when a file touches a global that a file sourced LATER assigns.

Only reads that execute while the file loads count: a global named inside a function body is
resolved at call time and is free. Base-game globals (Animal, Utils, ...) are not assigned by a
bare `Name = ...` in a mod file, so they never create a dependency.

    python tests/check_structure.py          # exit 1 on a violation
"""
import os
import re
import sys

TESTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TESTS)

OPEN_WORDS = {"function", "if", "do", "repeat"}
CLOSE_WORDS = {"end", "until"}
IDENT = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")


def strip_noise(src):
    """Blank comments and string literals (keeping newlines) so only code tokens remain."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("--", i):
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i + m.end())
                j = n if j < 0 else j + len(close)
            else:
                j = src.find("\n", i)
                j = n if j < 0 else j
            out.append(re.sub(r"[^\n]", " ", src[i:j]))
            i = j
        elif c == "[" and re.match(r"\[=*\[", src[i:]):
            m = re.match(r"\[(=*)\[", src[i:])
            close = "]" + m.group(1) + "]"
            j = src.find(close, i + m.end())
            j = n if j < 0 else j + len(close)
            out.append('""' + re.sub(r"[^\n]", " ", src[i + 2:j]))
            i = j
        elif c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append('""' + " " * max(0, j - i - 1))
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def scan(path):
    """Return (assigned, touched): file-scope globals assigned (name -> True when written `X = X or ...`),
    and (name, line) reads at file scope."""
    src = strip_noise(open(path, encoding="utf-8").read())
    assigned, touched = {}, []
    stack = []  # block openers: True for a function body, False for any other block
    nest = 0  # open ( and { : a `Name =` inside them is a table field or argument, not a global
    local_names = set()
    line = 1
    prev = ""  # previous significant token
    for m in re.finditer(r"[A-Za-z_][A-Za-z_0-9]*|\n|\.\.\.|\.\.|[^\sA-Za-z_0-9]", src):
        tok = m.group(0)
        if tok == "\n":
            line += 1
            continue
        in_function = any(stack)
        if IDENT.fullmatch(tok):
            if tok == "function":
                stack.append(True)
            elif tok == "if":
                stack.append(False)
            elif tok == "do":
                # `for ... do` / `while ... do` open a block; a bare `do` does too.
                stack.append(False)
            elif tok == "repeat":
                stack.append(False)
            elif tok in CLOSE_WORDS:
                if stack:
                    stack.pop()
            elif not in_function:
                after = src[m.end():m.end() + 80]
                if prev == "local":
                    local_names.add(tok)
                elif prev in (".", ":"):
                    pass
                elif tok[0].isupper() and tok not in local_names:
                    # a bare `Name =` (not `==`) at depth 0 is an assignment, not a read
                    if nest == 0 and re.match(r"\s*=(?!=)", after) and prev not in ("local",):
                        assigned[tok] = re.match(r"\s*=\s*" + tok + r"\s+or\b", after) is not None
                    elif prev == "function":
                        # `function Name.x()` needs Name to exist; its own file may have just assigned it
                        if tok not in assigned:
                            touched.append((tok, line))
                    elif tok not in assigned:
                        touched.append((tok, line))
            prev = tok
        else:
            if tok in "({":
                nest += 1
            elif tok in ")}":
                nest = max(0, nest - 1)
            prev = tok
    return assigned, touched


def source_order():
    main_src = open(os.path.join(REPO, "scripts", "main.lua"), encoding="utf-8").read()
    return re.findall(r'source\(modDirectory \.\. "([^"]+)"\)', main_src)


def violations(order, scans):
    """(file, line, name, owner) for each file-scope read of a global a later file assigns."""
    index = {p: i for i, p in enumerate(order)}
    defined_by = {}
    for p in order:
        for name in scans[p][0]:
            defined_by.setdefault(name, p)
    found = []
    for p in order:
        seen = set()
        for name, line in scans[p][1]:
            owner = defined_by.get(name)
            if owner is None or owner == p or name in seen:
                continue
            seen.add(name)
            if index[owner] > index[p]:
                found.append((p, line, name, owner))
    return found, len(defined_by)


# Pairs main.lua documents as "must follow": swapping either must be reported, or the scan is blind.
KNOWN = [
    ("scripts/disease/RLDiseaseRecord.lua", "scripts/disease/RLDiseaseDefinition.lua"),
    ("scripts/dealer/RLDealerQualityModel.lua", "scripts/dealer/RLDealerQualityResolver.lua"),
    ("scripts/core/RLConstants.lua", "scripts/animal/RLGenetics.lua"),
    ("scripts/herdsman/RLHerdsmanRuleService.lua", "scripts/gui/rlmenu/services/RLHerdsmanRulePresenter.lua"),
    ("scripts/gui/rlmenu/RLMenuTabPolicy.lua", "scripts/gui/rlmenu/RLMenu.lua"),
]


def collisions(order, scans):
    """Globals that more than one file assigns without the idempotent `X = X or ...` form."""
    owners = {}
    for p in order:
        for name, idempotent in scans[p][0].items():
            if not idempotent:
                owners.setdefault(name, []).append(p)
    return {name: files for name, files in owners.items() if len(files) > 1}


# Normalised bodies of the private helpers RLPlain replaced: lowercase identifiers renamed in order
# of appearance, so `v`/`value`/`t` and `;` placement do not matter. Equivalent finite spellings
# (abs < huge, ~= both infinities, > -huge and < huge) are all listed.
LUA_NAMES = set("""type pairs ipairs math table string assert error getmetatable setmetatable tostring tonumber
select next pcall nil true false and or not if then else elseif end for in do while repeat until return
local function break huge abs""".split())
PRIMITIVES = {
    "copy": ['local function copy(v) if type(v)~="table" then return v end local out={} for k,x in pairs(v) do out[k]=copy(x) end return out end'],
    "finite": ['local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end',
               'local function finite(v) return type(v)=="number" and v==v and v~=math.huge and v~=-math.huge end',
               'local function finite(v) return type(v)=="number" and v==v and v>-math.huge and v<math.huge end',
               'local function finite(v) return type(v)=="number" and v==v and math.abs(v)~=math.huge end'],
    "text": ['local function text(v) return type(v)=="string" and v:match("%S")~=nil end'],
    "equal": ['local function equal(a,b) if type(a)~=type(b) then return false end if type(a)~="table" then return a==b end for k,v in pairs(a) do if not equal(v,b[k]) then return false end end for k in pairs(b) do if a[k]==nil then return false end end return true end'],
}
PRIMITIVES["isFinite"] = [v.replace("function finite", "function isFinite") for v in PRIMITIVES["finite"]]
# Files that keep private definitions on purpose (see RLPlain's header), or sit outside the shared layers.
PRIVATE_OK = {"scripts/market/RLMarketSchema.lua", "scripts/animal/RLGrowth.lua", "scripts/animal/RLMeatValue.lua",
              "scripts/animal/RealisticLivestock_Animal.lua"}
PRIVATE_SCOPES = ("scripts/dealer/", "scripts/market/", "scripts/animal/")


def normalise(text, name):
    text = re.sub(r"--[^\n]*", "", text).replace(";", " ")  # strings stay: "table" and "%S" matter
    names = {}

    def rename(m):
        word = m.group(0)
        if word in LUA_NAMES or word[0].isupper() or word == name:
            return word
        return names.setdefault(word, "_%d" % len(names))

    text = re.sub(r"[A-Za-z_][A-Za-z_0-9]*", rename, text)
    text = re.sub(r"\s+", " ", text).strip()
    return re.sub(r"\s*([=,(){}~<>+*/%-])\s*", r"\1", text)


def function_end(lines, start):
    depth = 0
    for index in range(start, len(lines)):
        code = re.sub(r"--.*", "", re.sub(r"\"[^\"]*\"|'[^']*'", "", lines[index]))
        for word in re.findall(r"\b(function|if|repeat|do|end|until)\b", code):
            depth += 1 if word in ("function", "if", "repeat", "do") else -1
        if depth <= 0:
            return index
    return len(lines) - 1


def private_copies():
    """(file, line, name) of each file-scope local that duplicates an RLPlain primitive."""
    accepted = {name: {normalise(v, name) for v in variants} for name, variants in PRIMITIVES.items()}
    found = []
    for directory in PRIVATE_SCOPES:
        for root, _, files in os.walk(os.path.join(REPO, directory)):
            for filename in sorted(files):
                path = os.path.relpath(os.path.join(root, filename), REPO)
                if not filename.endswith(".lua") or path in PRIVATE_OK:
                    continue
                lines = open(os.path.join(REPO, path), encoding="utf-8").read().split("\n")
                for index, line in enumerate(lines):
                    m = re.match(r"local function (copy|finite|isFinite|text|equal)\b", line)
                    if m and normalise("\n".join(lines[index:function_end(lines, index) + 1]), m.group(1)) in accepted[m.group(1)]:
                        found.append((path, index + 1, m.group(1)))
    return found


def check():
    """Return a list of failure messages; empty when the order is sound and the scan can see."""
    order = source_order()
    scans = {p: scan(os.path.join(REPO, p)) for p in order}
    messages = []
    found, _ = violations(order, scans)
    for path, line, name in private_copies():
        shared = "finite" if name == "isFinite" else name
        messages.append(f"{path}:{line}: private {name}() duplicates RLPlain.{shared}; bind it with `local {name}=RLPlain.{shared}`")
    for name, files in sorted(collisions(order, scans).items()):
        messages.append(f"{name} is assigned by {len(files)} files ({', '.join(files)}); the later one silently replaces the first")
    messages += [f"{p}:{line}: reads {name} at file scope, but {owner} (sourced later) assigns it" for p, line, name, owner in found]
    for before, after in KNOWN:
        swapped = list(order)
        a, b = swapped.index(before), swapped.index(after)
        swapped[a], swapped[b] = swapped[b], swapped[a]
        if not any(f[0] == after and f[3] == before for f in violations(swapped, scans)[0]):
            messages.append(f"scan is blind: swapping {before} and {after} is not reported")
    return messages


def main():
    order = source_order()
    scans = {p: scan(os.path.join(REPO, p)) for p in order}
    _, count = violations(order, scans)
    messages = check()
    for message in messages:
        print(message)
    print(f"{len(order)} files, {count} file-scope globals, {len(messages)} problem(s)")
    return 1 if messages else 0


if __name__ == "__main__":
    sys.exit(main())

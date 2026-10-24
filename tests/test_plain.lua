-- RLPlain: the plain-data primitives the dealer, market and trade modules share.
local P = RLPlain

check("plain: finite accepts numbers", P.finite(0) and P.finite(-1.5) and P.finite(2 ^ 52))
check("plain: finite rejects NaN, infinities and non-numbers",
    not P.finite(0 / 0) and not P.finite(math.huge) and not P.finite(-math.huge)
    and not P.finite("1") and not P.finite(nil) and not P.finite(true) and not P.finite({}))

check("plain: text needs a non-space character",
    P.text("a") and P.text("  a ") and not P.text("") and not P.text("   ") and not P.text("\t\n"))
check("plain: text rejects non-strings", not P.text(nil) and not P.text(1) and not P.text({}))

local source = { a = { 1, 2, { b = "x" } }, n = 3, flag = false }
local copied = P.copy(source)
check("plain: copy equals its source", P.equal(copied, source))
copied.a[3].b = "y"
check("plain: copy is deep", source.a[3].b == "x")
local shared = { n = 1 }
local dag = P.copy({ a = shared, b = shared })
dag.a.n = 4
check("plain: a shared subtable becomes two independent copies", dag.b.n == 1 and shared.n == 1)
check("plain: copy passes scalars through", P.copy(5) == 5 and P.copy("s") == "s" and P.copy(nil) == nil and P.copy(false) == false)
local meta = setmetatable({ k = 1 }, { __index = { inherited = true } })
local plainCopy = P.copy(meta)
check("plain: copy drops the metatable", getmetatable(plainCopy) == nil and plainCopy.k == 1 and plainCopy.inherited == nil)

check("plain: equal compares structure", P.equal({ 1, { 2 } }, { 1, { 2 } }) and not P.equal({ 1, { 2 } }, { 1, { 3 } }))
check("plain: equal sees an extra key on either side", not P.equal({ a = 1 }, { a = 1, b = 2 }) and not P.equal({ a = 1, b = 2 }, { a = 1 }))
check("plain: equal separates types", not P.equal(1, "1") and not P.equal({}, 0) and not P.equal(nil, false))
check("plain: equal treats NaN as unequal to itself", not P.equal({ n = 0 / 0 }, { n = 0 / 0 }))
check("plain: equal ignores table identity", P.equal({}, {}) and P.equal("a", "a"))

check("plain: dense accepts a sequence and an empty table", P.dense({ 1, 2, 3 }) and P.dense({}))
check("plain: dense rejects holes", not P.dense({ [1] = "a", [3] = "c" }))
check("plain: dense rejects string and fractional keys", not P.dense({ 1, 2, x = 3 }) and not P.dense({ [1] = 1, [1.5] = 2 }))
check("plain: dense rejects zero and negative keys", not P.dense({ [0] = 1 }) and not P.dense({ [-1] = 1, 2 }))
check("plain: dense rejects non-tables", not P.dense(nil) and not P.dense("abc") and not P.dense(3))

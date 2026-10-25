loadMod("scripts/market/RLMarketData.lua")
local D=RLMarketData
local input={a={1,true,"text"},[1.5]="fractional data keys",zero=0}
local before=assert(D.fingerprint(input));local copied=assert(D.copy(input))
check("market data: cloned canonical value unchanged",D.fingerprint(copied)==before)
copied.a[1]=99
check("market data: nested isolation",input.a[1]==1)
local calls=0
local executable=setmetatable({}, {__pairs=function()calls=calls+1;error("must not run")end})
check("market data: reject metatables without executing them",D.copy({nested=executable})==nil and calls==0)
local cycle={};cycle.self=cycle
for _,bad in ipairs({cycle,{n=math.huge},{n=0/0},{callback=function()end},{[true]=1}}) do
    check("market data: clone and fingerprint reject same data",D.copy(bad)==nil and D.fingerprint(bad)==nil)
end
local shared={n=1};local dag=assert(D.copy({a=shared,b=shared}));dag.a.n=4
check("market data: repeated references cloned independently",dag.b.n==1 and shared.n==1)
local big={};for i=1,50000 do big[i]=i end
check("market data: node budget counts keys and values",D.copy(big)==nil and D.fingerprint(big)==nil)
-- Prove a copy does not materialize a canonical string as a side effect.
local fingerprint=D.fingerprint;D.fingerprint=function()error("copy must not encode")end
local okay,result=pcall(D.copy,input);D.fingerprint=fingerprint
check("market data: copying independent of canonical encoding",okay and result and fingerprint(result)==before)

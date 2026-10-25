addModEventListener=function()end
loadMod("scripts/gui/rlmenu/services/RLAnimalEventRequest.lua")
local R=RLAnimalEventRequest
local function fixture()
    R.reset()
    local x={subscriptions={},timers={},sent=0,replies={}}
    local center={}
    function center:subscribe(event,fn,token)x.subscriptions[token]={event=event,fn=fn}end
    function center:unsubscribe(_,token)
        if x.unsubscribeError then error("unsubscribe fault")end
        x.subscriptions[token]=nil
    end
    local function timerFactory(_,fn)
        local timer={fn=fn,stops=0}
        function timer:stop()self.stops=self.stops+1;if x.stopError then error("stop fault")end end
        x.timers[#x.timers+1]=timer
        if x.synchronousTimeout then fn()end
        return timer
    end
    x.deps={messageCenter=center,timerFactory=timerFactory,sendEvent=function()
        x.sent=x.sent+1
        if x.synchronousReply then x:reply(x.synchronousReply)end
        if x.sendError then error("send fault")end
    end}
    function x:reply(code)
        local pending={};for token,s in pairs(self.subscriptions)do pending[#pending+1]={token,s.fn}end
        for _,s in ipairs(pending)do s[2](s[1],code)end
    end
    function x:start(event)
        return R.dispatch(event or self.event,{},function(code)self.replies[#self.replies+1]=code end,nil,self.deps)
    end
    x.event={};return x
end
local x=fixture();assert(x:start());local token=R._inFlight[x.event]
check("request lifetime: duplicate class refused without dispatch",not x:start() and x.sent==1)
x:reply(0);x.timers[1].fn();x:reply(1)
check("request lifetime: reply consumes once and stops watchdog",#x.replies==1 and x.replies[1]==0 and x.timers[1].stops==1 and not R.isInFlight(x.event) and token.cancel==nil)
x=fixture();assert(x:start());local pending=x.timers[1]
R.deleteMap();pending.fn();x:reply(0)
check("request lifetime: teardown cancels subscription and watchdog silently",pending.stops==1 and next(x.subscriptions)==nil and #x.replies==0 and not R.isInFlight(x.event))
R.loadMap();assert(x:start());pending.fn()
check("request lifetime: old timer cannot complete a new session request",#x.replies==0 and R.isInFlight(x.event))
x:reply(0);check("request lifetime: new session request completes normally",#x.replies==1)
x=fixture();x.stopError=true;x.unsubscribeError=true;assert(x:start());x:reply(0)
check("request lifetime: cleanup exceptions cannot strand gate or callback",#x.replies==1 and not R.isInFlight(x.event))
x:reply(0);x.timers[1].fn()
check("request lifetime: surviving engine subscription cannot double-complete",#x.replies==1)
x=fixture();x.sendError=true
check("request lifetime: send failure returns false and releases resources",not x:start() and x.sent==1 and next(x.subscriptions)==nil and x.timers[1].stops==1 and not R.isInFlight(x.event))
x.timers[1].fn();check("request lifetime: failed send timer cannot later call UI",#x.replies==0)
x=fixture();x.synchronousReply=0;x.sendError=true
check("request lifetime: synchronous completed reply wins over later send throw",x:start() and #x.replies==1 and x.replies[1]==0)
x=fixture();x.synchronousTimeout=true
check("request lifetime: synchronous timeout consumes before send and closes returned timer",x:start() and x.sent==0 and #x.replies==1 and x.replies[1]==R.TIMEOUT_CODE and x.timers[1].stops==1)
x=fixture();assert(x:start());local other={};assert(x:start(other));R.reset()
check("request lifetime: reset cancels every event class",x.timers[1].stops==1 and x.timers[2].stops==1 and next(x.subscriptions)==nil and #x.replies==0)
check("request lifetime: invalid callback refused",not R.dispatch({}, {},true,nil,x.deps))
local accepted=R.dispatch({}, {},function()end,nil,{messageCenter=false})
check("request lifetime: malformed dependency refuses without leaking gate",accepted==false and next(R._inFlight)==nil)

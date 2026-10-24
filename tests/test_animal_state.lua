local A=RLAnimalState
local animal={weight=450,pregnancy={pregnancies={{genetics={quality=1.4}}}},genetics={health=1}}
animal.clusterSystem={animals={animal}}
animal.visualAnimal={animal=animal,nodes={root=99}}
animal.visualAnimalIndex=3;animal.id="1-7";animal.idFull="999-7"
local state=assert(A.capture(animal))
check("animal state: visuals and engine links excluded",state.visualAnimal==nil and state.clusterSystem==nil and state.id==nil and state.visualAnimalIndex==nil)
check("animal state: unborn genetics retained",state.pregnancy.pregnancies[1].genetics.quality==1.4)
state.pregnancy.pregnancies[1].genetics.quality=9
check("animal state: detached copy",animal.pregnancy.pregnancies[1].genetics.quality==1.4)
animal.pregnancy.self=animal.pregnancy
check("animal state: business cycles are errors",A.capture(animal)==nil)
animal.pregnancy.self=nil;animal.weight=math.huge
check("animal state: nonfinite business state rejected",A.capture(animal)==nil)
animal.weight=450;animal.genetics.get=function()end
check("animal state: nested executable state refused for Broker",A.capture(animal)==nil)
check("animal state: existing Dealer method policy explicit",A.capture(animal,{ignoreNestedMethods=true})~=nil)

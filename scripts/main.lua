--[[
    main.lua
    The mod loader. Source order is load-bearing wherever a module reads a sibling at
    file scope; those lines say so, and the rest are free.
]]

local modDirectory = g_currentModDirectory

-- SECTION 0: Logging
source(modDirectory .. "scripts/rmlib/RmLogging.lua")
Log = RmLogging.getLogger("RLRM")
source(modDirectory .. "scripts/rmlib/RmVersion.lua")
local Ver = RmVersion.forMod(g_currentModName, Log)
Log:info("Build: %s", Ver:describe())
-- DEBUG unless this is a released stable version (>= 1.0.0.0 with no -dev suffix).
Ver:applyBuildLogLevel()

-- SECTION 1: Font Library
source(modDirectory .. "scripts/fontlib/RmFontCharacter.lua")
source(modDirectory .. "scripts/fontlib/RmFontManager.lua")

-- SECTION 2: GUI Loading Screen
source(modDirectory .. "scripts/gui/MPLoadingScreen.lua")

-- SECTION 2b: Utilities
source(modDirectory .. "scripts/utils/RmSafeUtils.lua")
source(modDirectory .. "scripts/utils/RLAnimalUtil.lua")
source(modDirectory .. "scripts/utils/RLPenLog.lua")
source(modDirectory .. "scripts/utils/RLEppAge.lua")
source(modDirectory .. "scripts/utils/RLFacilityAge.lua")
source(modDirectory .. "scripts/utils/RLPermissionHelper.lua")
source(modDirectory .. "scripts/utils/RLScaleHelper.lua")
source(modDirectory .. "scripts/utils/RLAnimalDisplayHelper.lua")
source(modDirectory .. "scripts/utils/RLMoveDestinationHelper.lua")
source(modDirectory .. "scripts/utils/RLTimeFormat.lua")
source(modDirectory .. "scripts/utils/RLCalendar.lua")

-- SECTION 2c: Constants
source(modDirectory .. "scripts/core/RLConstants.lua")

-- SECTION 2d: Map country resolution (needs RLConstants)
source(modDirectory .. "scripts/core/RLMapCountry.lua")

-- SECTION 2e: Breed traits (xml/breedTraits.xml; its layered lookup is shared with the carcass yield config)
-- Weight arithmetic of the growth line, the old weight rule and the body condition budget (pure)
source(modDirectory .. "scripts/animal/RLWeightMath.lua")
source(modDirectory .. "scripts/animal/RLMilkParity.lua")
source(modDirectory .. "scripts/animal/RLBreedTraits.lua")
source(modDirectory .. "scripts/animal/RLCurveScale.lua")
-- Which species section of the nutrition configs an animal or pen reads (sheep; cattle read the root)
source(modDirectory .. "scripts/animal/RLSpecies.lua")
-- Carcass yield arithmetic, pure; AnimalMoveEvent feeds it the animal and config snapshot
source(modDirectory .. "scripts/animal/RLMeatMath.lua")
-- Delivery rules shared by the delivery code and the trade quote (contract order, fee, butcher recipe), pure
source(modDirectory .. "scripts/animal/RLFacilityRules.lua")
-- Weight model v2 (xml/weightProfiles.xml): continuous growth curves (pure), the budget step
-- (pure), and the profile each cattle subtype resolves to. RLGrowth, the game side, is sourced
-- after the body condition it reads.
source(modDirectory .. "scripts/animal/RLGrowthCurve.lua")
source(modDirectory .. "scripts/animal/RLGrowthMath.lua")
source(modDirectory .. "scripts/animal/RLWeightProfiles.lua")
-- Livestock prices follow the difficulty multiplier: live prices, semen, contract slaughter fees
source(modDirectory .. "scripts/animal/RLLivestockPrices.lua")
-- Body condition of cattle (xml/bodyCondition.xml): nutrition budget, reserve, finish score / BCS.
-- Read by Animal, the husbandry specs, the carcass yield and the conception rolls.
source(modDirectory .. "scripts/nutrition/RLNutritionMath.lua")
source(modDirectory .. "scripts/nutrition/RLBodyConditionConfig.lua")
source(modDirectory .. "scripts/nutrition/RLBodyCondition.lua")
source(modDirectory .. "scripts/nutrition/RLCalfRearing.lua")
source(modDirectory .. "scripts/animal/RLGrowth.lua")
-- Real-equivalent nutrition (xml/feedProfiles.xml): units and profiles, the pure ration math and
-- planner, then the game side, which wraps AnimalFoodSystem after RLCalfRearing's wrapper.
source(modDirectory .. "scripts/feed/RLFeedUnits.lua")
source(modDirectory .. "scripts/feed/RLFeedProfiles.lua")
source(modDirectory .. "scripts/feed/RLFeedMath.lua")
source(modDirectory .. "scripts/feed/RLFeedRationPlanner.lua")
source(modDirectory .. "scripts/feed/RLFeed.lua")
source(modDirectory .. "scripts/feed/RLFeedInfoService.lua")
source(modDirectory .. "scripts/animal/RLBirthWeight.lua")

-- SECTION 3: Animal Husbandry - Cluster System
source(modDirectory .. "scripts/animals/husbandry/cluster/RealisticLivestock_AnimalCluster.lua")
source(modDirectory .. "scripts/animals/husbandry/cluster/RealisticLivestock_AnimalClusterHusbandry.lua")
source(modDirectory .. "scripts/animals/husbandry/cluster/RealisticLivestock_AnimalClusterSystem.lua")
source(modDirectory .. "scripts/animals/husbandry/cluster/VisualAnimal.lua")

-- SECTION 4: Animal Husbandry - Placeables
source(modDirectory .. "scripts/animals/husbandry/placeables/PlaceableHusbandry.lua")
source(modDirectory .. "scripts/animals/husbandry/placeables/PlaceableHusbandryLiquidManure.lua")
source(modDirectory .. "scripts/animals/husbandry/placeables/PlaceableHusbandryStraw.lua")
source(modDirectory .. "scripts/animals/husbandry/placeables/PlaceableHusbandryWater.lua")
source(modDirectory .. "scripts/animals/husbandry/placeables/RealisticLivestock_PlaceableHusbandryAnimals.lua")
source(modDirectory .. "scripts/animals/husbandry/placeables/RealisticLivestock_PlaceableHusbandryMilk.lua")
source(modDirectory .. "scripts/animals/husbandry/placeables/RealisticLivestock_PlaceableHusbandryFood.lua")
-- Pasture seasons (xml/pastureSeasons.xml: config and pure season arithmetic, then the meadow
-- adapter) and the wool shearing season (breedTraits.xml woolShearing), read by the pallets module.
source(modDirectory .. "scripts/animals/husbandry/placeables/RLPastureSeason.lua")
source(modDirectory .. "scripts/animals/husbandry/placeables/RLMeadowSeason.lua")
source(modDirectory .. "scripts/animals/husbandry/placeables/RLWoolShearing.lua")
source(modDirectory .. "scripts/animals/husbandry/placeables/RealisticLivestock_PlaceableHusbandryPallets.lua")

-- SECTION 5: Animal Husbandry - Core Systems
source(modDirectory .. "scripts/events/AnimalSystemStateEvent.lua")
source(modDirectory .. "scripts/animals/husbandry/RealisticLivestock_HusbandrySystem.lua")
source(modDirectory .. "scripts/animals/husbandry/RealisticLivestock_AnimalNameSystem.lua")
source(modDirectory .. "scripts/animals/husbandry/RealisticLivestock_AnimalSystem.lua")

-- SECTION 7: Animal Shop - Events
source(modDirectory .. "scripts/animals/shop/events/AIAnimalBuyEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AIAnimalInseminationEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AIAnimalMoveEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AIAnimalSellEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AnimalBuyEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AnimalInseminationEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AnimalInseminationResultEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AnimalMoveEvent.lua")
source(modDirectory .. "scripts/animal/RLMeatValue.lua")
-- Read-only trade quote: model meat vs a facility's units and effective recipe (rlTradeReport)
source(modDirectory .. "scripts/animal/RLTradeQuote.lua")
-- T02 shadow budget and offline coordinator. No live transaction adapter is enabled.
source(modDirectory .. "scripts/animal/RLContractPlan.lua")
source(modDirectory .. "scripts/animal/RLContractPreview.lua")
source(modDirectory .. "scripts/animal/RLTradeTransaction.lua")
-- T02 controlled contract delivery (OFF by default): HB target adapter, source adapter, entry
source(modDirectory .. "scripts/animal/RLHBContractAdapter.lua")
source(modDirectory .. "scripts/animal/RLTradeSourceAdapter.lua")
source(modDirectory .. "scripts/animal/RLContractTrade.lua")
-- T02 batch 3 live sales (OFF by default): money receipt, recovery decisions, entry
source(modDirectory .. "scripts/animal/RLSaleSettlement.lua")
source(modDirectory .. "scripts/animal/RLSaleRecovery.lua")
source(modDirectory .. "scripts/animal/RLLiveSale.lua")
-- T02 batch 4: the ledger saved with the savegame, checked on load (gate before any T02 work)
source(modDirectory .. "scripts/animal/RLTradePersistence.lua")
-- Dealer v2 identity ledger (T1 pure service, T2 runtime / world / save checkpoint). SHADOW by default.
source(modDirectory .. "scripts/animal/RLAnimalIdentity.lua")
source(modDirectory .. "scripts/animal/RLAnimalIdentityPersistence.lua")
source(modDirectory .. "scripts/animal/RLAnimalIdentityRuntime.lua")
source(modDirectory .. "scripts/animal/RLAnimalIdentityWorld.lua")
source(modDirectory .. "scripts/animal/RLAnimalIdentityRepair.lua")
source(modDirectory .. "scripts/animal/RLAnimalIdentityCheckpoint.lua")
source(modDirectory .. "scripts/animal/RLTradeRecovery.lua")
source(modDirectory .. "scripts/animal/RLTradeCheckpoint.lua")
source(modDirectory .. "scripts/animal/RLContractDiag.lua")
source(modDirectory .. "scripts/animals/shop/events/AnimalSellEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/SemenBuyEvent.lua")

-- SECTION 8: Animal Shop - Core
source(modDirectory .. "scripts/animals/shop/RealisticLivestock_AnimalItemStock.lua")

-- SECTION 9: Events (General)
source(modDirectory .. "scripts/events/HusbandryMessageStateEvent.lua")
source(modDirectory .. "scripts/events/RLBodyConditionStateEvent.lua")
source(modDirectory .. "scripts/events/RLBodyConditionConfigEvent.lua")
source(modDirectory .. "scripts/events/RLFeedRationEvent.lua")
source(modDirectory .. "scripts/events/HusbandryMessageAddEvent.lua")
source(modDirectory .. "scripts/events/HusbandryMessageDeleteEvent.lua")
source(modDirectory .. "scripts/events/ReturnStrawEvent.lua")
source(modDirectory .. "scripts/events/TakeStrawEvent.lua")
source(modDirectory .. "scripts/events/DiseaseTreatmentToggleEvent.lua")
source(modDirectory .. "scripts/events/DiseaseCullEvent.lua")
source(modDirectory .. "scripts/events/DiseaseVaccinateEvent.lua")

-- SECTION 10: Farms
source(modDirectory .. "scripts/farms/FarmManager.lua")
source(modDirectory .. "scripts/farms/RealisticLivestock_FarmStats.lua")

-- SECTION 11: Fill Types
source(modDirectory .. "scripts/fillTypes/RealisticLivestock_FillTypeManager.lua")

-- SECTION 11a: Map Bridge System
source(modDirectory .. "scripts/bridge/RLVersionSpec.lua")
source(modDirectory .. "scripts/bridge/RLModelMerge.lua")
source(modDirectory .. "scripts/bridge/RLMapBridge.lua")
source(modDirectory .. "scripts/bridge/RLModBridge.lua")
source(modDirectory .. "scripts/bridge/RLHusbandryProfiles.lua")
source(modDirectory .. "scripts/bridge/RLPenConstruction.lua")

-- SECTION 11b: Breeding Mathematics
source(modDirectory .. "scripts/animal/BreedingMath.lua")
source(modDirectory .. "scripts/animal/RLBreedingValue.lua")
source(modDirectory .. "scripts/animal/RLGeneticsDraw.lua")
-- Reads RLConstants at file scope, so it must follow SECTION 2c; a consumer binding one of
-- its re-exported tables at file scope must follow this line.
source(modDirectory .. "scripts/animal/RLGenetics.lua")

-- SECTION 11c: Horse Logic (delegate module, sourced before Animal.lua)
source(modDirectory .. "scripts/animal/AnimalHorse.lua")

-- SECTION 11d: Reproduction Logic (delegate module, sourced before Animal.lua); the milk rule
-- births, the monthly tick, milk yield, the feed forecast and the dealer share.
source(modDirectory .. "scripts/animal/RLLactation.lua")
source(modDirectory .. "scripts/animal/AnimalReproduction.lua")

-- SECTION 11e: Health/Death Logic (delegate module, sourced before Animal.lua)
source(modDirectory .. "scripts/animal/AnimalHealth.lua")

-- SECTION 11f: Persistence & Serialization (delegate modules, sourced before Animal.lua)
source(modDirectory .. "scripts/animal/AnimalPersistence.lua")
source(modDirectory .. "scripts/animal/AnimalSerialization.lua")

-- SECTION 11g: Saveable Filters - headless service + MP events
source(modDirectory .. "scripts/filters/RLFilterFieldCatalog.lua")
source(modDirectory .. "scripts/filters/RLFilterFieldDisplay.lua")
source(modDirectory .. "scripts/filters/RLFilterEvaluator.lua")
source(modDirectory .. "scripts/filters/RLFilterUsage.lua")
source(modDirectory .. "scripts/filters/RLFilterSerialization.lua")
source(modDirectory .. "scripts/filters/RLFilterWire.lua")
source(modDirectory .. "scripts/filters/RLFilterService.lua")
source(modDirectory .. "scripts/events/RLFilterCreateEvent.lua")
source(modDirectory .. "scripts/events/RLFilterUpdateEvent.lua")
source(modDirectory .. "scripts/events/RLFilterDeleteEvent.lua")
source(modDirectory .. "scripts/events/RLFilterStateEvent.lua")
-- Depends on RLFilterUsage (above) and RLScaleHelper (SECTION 2b).
source(modDirectory .. "scripts/utils/RLQuickFilterToSavedFilter.lua")

-- SECTION 11h: Herdsman Rules - headless service + persistence + MP events
-- Serializer before service: the service's save/loadFromXMLFile call into it.
-- RLHusbandryTargetKey first - the wire and its consumers key targets through it
-- (uniqueId on the server, net-object-id on a pure client).
source(modDirectory .. "scripts/herdsman/RLHusbandryTargetKey.lua")
source(modDirectory .. "scripts/herdsman/RLHerdsmanRuleSerialization.lua")
source(modDirectory .. "scripts/herdsman/RLHerdsmanRuleService.lua")
source(modDirectory .. "scripts/herdsman/RLHerdsmanRuleWire.lua")
source(modDirectory .. "scripts/events/RLHerdsmanRuleCreateEvent.lua")
source(modDirectory .. "scripts/events/RLHerdsmanRuleUpdateEvent.lua")
source(modDirectory .. "scripts/events/RLHerdsmanRuleDeleteEvent.lua")
source(modDirectory .. "scripts/events/RLHerdsmanRuleStateEvent.lua")

-- SECTION 11i: Herdsman day-tick planner - run order, candidate selection, sequential claim
source(modDirectory .. "scripts/herdsman/RLHerdsmanPlanner.lua")

-- SECTION 11j: Herdsman day-tick executor - applies the planner's actions in-game
source(modDirectory .. "scripts/herdsman/RLHerdsmanExecutor.lua")

-- SECTION 11j2: Herdsman day-tick messages - the player-notification readout
source(modDirectory .. "scripts/herdsman/RLHerdsmanMessages.lua")

-- SECTION 11k: Herdsman day-tick wiring - fires planner then executor once per day, server-side
source(modDirectory .. "scripts/herdsman/RLHerdsmanDayTick.lua")

-- SECTION 11l: Dealer sale-availability. Registry first - the serializer and the apply layer
-- both reference it at load, and the wire codec must precede the two events below.
source(modDirectory .. "scripts/dealer/RLDealerSaleRegistry.lua")
source(modDirectory .. "scripts/dealer/RLDealerSaleSerialization.lua")
source(modDirectory .. "scripts/dealer/RLDealerSaleApply.lua")
source(modDirectory .. "scripts/dealer/RLDealerSaleCatalog.lua")
source(modDirectory .. "scripts/dealer/RLDealerSaleSelectorModel.lua")
source(modDirectory .. "scripts/dealer/RLDealerSaleReconcile.lua")
source(modDirectory .. "scripts/dealer/RLDealerSaleWire.lua")
source(modDirectory .. "scripts/events/RLDealerSaleStateEvent.lua")
source(modDirectory .. "scripts/events/RLDealerSaleSetEvent.lua")

-- SECTION 11m: Dealer quality presets. Reads RLConstants at file scope for the genetics
-- domain, so it must follow SECTION 2c.
source(modDirectory .. "scripts/dealer/RLDealerQualityModel.lua")

-- Dereferences RLDealerQualityModel.DEFAULT_INDEX at file scope, so it must follow the model.
source(modDirectory .. "scripts/dealer/RLDealerQualityResolver.lua")

-- SECTION 11n: Dealer stock purposes (xml/dealerStock.xml): what ages and breeding states the
-- dealer sells. Loads its file through RLBreedTraits.loadConfig on first use.
source(modDirectory .. "scripts/dealer/RLDealerStockPolicy.lua")
source(modDirectory .. "scripts/dealer/RLDealerStockWeight.lua")
source(modDirectory .. "scripts/dealer/RLDealerHistory.lua")
source(modDirectory .. "scripts/dealer/RLDealerReplay.lua")
-- Strict source ledgers and monthly listing lifecycle; dormant until the complete
-- server purchase/checkpoint adapter is installed. No map callbacks or RNG here.
source(modDirectory .. "scripts/dealer/RLDealerSourceState.lua")
source(modDirectory .. "scripts/dealer/RLDealerSourceReproduction.lua")
source(modDirectory .. "scripts/dealer/RLDealerSourceOwnership.lua")
source(modDirectory .. "scripts/dealer/RLDealerSourceAdapter.lua")
source(modDirectory .. "scripts/dealer/RLDealerObservedGrowth.lua")
source(modDirectory .. "scripts/dealer/RLDealerOwnedStock.lua")
source(modDirectory .. "scripts/dealer/RLDealerHandoff.lua")
source(modDirectory .. "scripts/dealer/RLDealerSourceFactory.lua")
source(modDirectory .. "scripts/dealer/RLDealerDestination.lua")
source(modDirectory .. "scripts/dealer/RLDealerTargetAdapter.lua")
source(modDirectory .. "scripts/dealer/RLDealerMoneyAdapter.lua")
source(modDirectory .. "scripts/dealer/RLDealerClock.lua")
source(modDirectory .. "scripts/dealer/RLDealerSourceFarm.lua")
source(modDirectory .. "scripts/dealer/RLDealerListingRegistry.lua")
source(modDirectory .. "scripts/dealer/RLDealerPurchase.lua")
source(modDirectory .. "scripts/dealer/RLDealerPurchaseProtocol.lua")
source(modDirectory .. "scripts/events/RLDealerPurchaseEvent.lua")
source(modDirectory .. "scripts/dealer/RLDealerQuote.lua")
source(modDirectory .. "scripts/dealer/RLDealerQuoteProtocol.lua")
source(modDirectory .. "scripts/events/RLDealerQuoteEvent.lua")
source(modDirectory .. "scripts/dealer/RLDealerClientRequest.lua")
source(modDirectory .. "scripts/dealer/RLDealerPersistence.lua")
source(modDirectory .. "scripts/dealer/RLDealerStockService.lua")
source(modDirectory .. "scripts/dealer/RLDealerOwnedProgress.lua")
source(modDirectory .. "scripts/dealer/RLDealerOwnedBirth.lua")
source(modDirectory .. "scripts/dealer/RLDealerOwnedAdmission.lua")
source(modDirectory .. "scripts/dealer/RLDealerWorld.lua")
source(modDirectory .. "scripts/dealer/RLDealerCapacity.lua")
source(modDirectory .. "scripts/dealer/RLDealerJournal.lua")
source(modDirectory .. "scripts/dealer/RLDealerPurchaseAdapter.lua")
source(modDirectory .. "scripts/dealer/RLDealerCheckpoint.lua")
-- Dealer v2 T3/T4: stock generation, scheduler, service facade, game binding. Dormant until rlDealerEnable.
source(modDirectory .. "scripts/dealer/RLDealerRng.lua")
source(modDirectory .. "scripts/dealer/RLDealerCatalog.lua")
source(modDirectory .. "scripts/dealer/RLDealerCatalogProtocol.lua")
source(modDirectory .. "scripts/events/RLDealerCatalogEvent.lua")
source(modDirectory .. "scripts/dealer/RLDealerPlanner.lua")
source(modDirectory .. "scripts/dealer/RLDealerGeneration.lua")
source(modDirectory .. "scripts/dealer/RLDealerScheduler.lua")
source(modDirectory .. "scripts/dealer/RLDealerAssembly.lua")
source(modDirectory .. "scripts/dealer/RLDealerService.lua")
source(modDirectory .. "scripts/dealer/RLDealerGameBinding.lua")
source(modDirectory .. "scripts/dealer/RLDealerRuntime.lua")

-- SECTION 12: GUI Elements
source(modDirectory .. "scripts/gui/elements/DoubleOptionSliderElement.lua")
source(modDirectory .. "scripts/gui/elements/RenderElement.lua")
source(modDirectory .. "scripts/gui/elements/TripleOptionElement.lua")

-- SECTION 13: GUI Dialogs and Frames
source(modDirectory .. "scripts/gui/VisualAnimalsDialog.lua")
source(modDirectory .. "scripts/gui/NameInputDialog.lua")
source(modDirectory .. "scripts/gui/RealisticLivestockFrame.lua")
source(modDirectory .. "scripts/gui/AnimalAIDialog.lua")
source(modDirectory .. "scripts/gui/AnimalFilterDialog.lua")
source(modDirectory .. "scripts/gui/AnimalMoveDestinationDialog.lua")
source(modDirectory .. "scripts/gui/RLSeverityIcon.lua")
source(modDirectory .. "scripts/gui/DiseaseDialog.lua")
source(modDirectory .. "scripts/gui/EarTagColourPickerDialog.lua")
source(modDirectory .. "scripts/gui/RLFilterConditionDialog.lua")
source(modDirectory .. "scripts/gui/RLFilterValueSetDialog.lua")
source(modDirectory .. "scripts/gui/RLHerdsmanFilterPickerDialog.lua")
source(modDirectory .. "scripts/gui/RLHerdsmanHusbandryPickerDialog.lua")
source(modDirectory .. "scripts/gui/RLHerdsmanDestinationPickerDialog.lua")
source(modDirectory .. "scripts/gui/RLDealerSaleSelectorDialog.lua")
-- Reads the disease-selection modules (SECTION 20e2) at call time only.
source(modDirectory .. "scripts/gui/RLDiseaseSelectorDialog.lua")
source(modDirectory .. "scripts/gui/RLFeedRationDialog.lua")
source(modDirectory .. "scripts/gui/FileExplorerDialog.lua")
source(modDirectory .. "scripts/gui/RL_InfoDisplayKeyValueBox.lua")
source(modDirectory .. "scripts/gui/RealisticLivestock_InGameMenuAnimalsFrame.lua")

-- SECTION 13b: RL Tabbed Menu. Services before the frames that call them; frames before the
-- menu, so FrameReference refs resolve.
source(modDirectory .. "scripts/gui/rlmenu/services/RLMessageService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalQuery.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLHusbandrySelector.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLGeneticsFormatter.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLPenFeedForecast.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLFeedRationModel.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalInfoService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLDetailPaneHelper.lua")
-- The shared trade-request guard, before the three trade services that dispatch through it.
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalEventRequest.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLSelectionKey.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalMoveService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalSellService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalBuyService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLDealerQuery.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAIStockService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLTrailerEndpointService.lua")
-- The transfer adapter seam, before the three counterpart adapters that register into it.
source(modDirectory .. "scripts/gui/rlmenu/services/RLTransferAdapter.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLFilterCycleHelper.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLFilterChipHelper.lua")
-- Copies RLHerdsmanRuleService's operation tables and gate names by value at file scope,
-- so it must follow SECTION 11h; sourcing it without the service raises at load.
source(modDirectory .. "scripts/gui/rlmenu/services/RLHerdsmanRulePresenter.lua")
-- Reads the presenter's per-operation defaults, so it must follow it.
source(modDirectory .. "scripts/gui/rlmenu/services/RLHerdsmanRuleEditModel.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuMessagesFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuInfoFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuMoveFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuSellFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuBuyFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuAIFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuSettingsFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuHerdsmanFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuTransferFrame.lua")
-- Before RLMenu, whose MODE_TRAILER / TRAILER_* constants re-export the policy's values.
source(modDirectory .. "scripts/gui/rlmenu/RLMenuTabPolicy.lua")
source(modDirectory .. "scripts/gui/rlmenu/RLMenuHusbandryAnchor.lua")
-- The three counterpart adapters register into RLTransferAdapter._adapters at load, keyed by
-- an RLMenuTabPolicy constant, so both must precede them. The AnimalUnloadEvent codec
-- override precedes the world service so the unload dispatch fires the patched event.
source(modDirectory .. "scripts/gui/rlmenu/services/RLTransferPenAdapter.lua")
source(modDirectory .. "scripts/animals/shop/events/AnimalUnloadEvent.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLTrailerWorldService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLTransferWorldAdapter.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLTransferEppAdapter.lua")
source(modDirectory .. "scripts/gui/rlmenu/RLMenu.lua")
-- Last in 13b: the sole installer of the AnimalScreen.show and LivestockTrailerActivatable.run
-- overrides, and it reads RLMenu's constants at load.
source(modDirectory .. "scripts/gui/rlmenu/RLAnimalScreenBridge.lua")

-- SECTION 14: Migration System
source(modDirectory .. "scripts/migration/RmMigrationManager.lua")
source(modDirectory .. "scripts/migration/RmMigrationDialog.lua")
source(modDirectory .. "scripts/migration/RmItemSystemMigration.lua")

-- SECTION 15: Hand Tools
source(modDirectory .. "scripts/handTools/specializations/HandToolHorseBrush.lua")
source(modDirectory .. "scripts/handTools/HandTool.lua")
source(modDirectory .. "scripts/handTools/HandToolSystem.lua")
source(modDirectory .. "scripts/handTools/RLHandTools.lua")

-- SECTION 16: Insemination - Dewar (DewarData specialization and rlDewar vehicle type registered in Lua)
source(modDirectory .. "scripts/insemination/DewarMigration.lua")
source(modDirectory .. "scripts/insemination/DewarTypeRegistration.lua")
source(modDirectory .. "scripts/insemination/DewarObjectStorageHook.lua")

-- SECTION 17: Placeables
source(modDirectory .. "scripts/placeables/RealisticLivestock_PlaceableSystem.lua")

-- SECTION 18: Player
source(modDirectory .. "scripts/player/RealisticLivestock_PlayerHUDUpdater.lua")
source(modDirectory .. "scripts/player/RealisticLivestock_PlayerInputComponent.lua")

-- SECTION 19: Vehicles
source(modDirectory .. "scripts/vehicles/specializations/RealisticLivestock_LivestockTrailer.lua")
source(modDirectory .. "scripts/vehicles/specializations/Rideable.lua")

-- SECTION 20b: Insemination (dewar/straw infrastructure)
source(modDirectory .. "scripts/insemination/AIStrawUpdater.lua")

-- SECTION 20c: Events (general lifecycle events)
source(modDirectory .. "scripts/events/AnimalBirthEvent.lua")
source(modDirectory .. "scripts/events/AnimalDeathEvent.lua")
source(modDirectory .. "scripts/events/AnimalCastrateEvent.lua")
source(modDirectory .. "scripts/insemination/RLSemenBatch.lua")
source(modDirectory .. "scripts/insemination/RLSemenCollection.lua")
source(modDirectory .. "scripts/insemination/RLStrawLedger.lua")
source(modDirectory .. "scripts/events/SemenCollectEvent.lua")
source(modDirectory .. "scripts/events/SemenSellEvent.lua")
source(modDirectory .. "scripts/player/RLSemenSalePrompt.lua")
source(modDirectory .. "scripts/events/AnimalMarkEvent.lua")
source(modDirectory .. "scripts/events/AnimalMonitorEvent.lua")
source(modDirectory .. "scripts/events/AnimalNameChangeEvent.lua")
source(modDirectory .. "scripts/events/AnimalPregnancyEvent.lua")
source(modDirectory .. "scripts/events/AnimalUpdateEvent.lua")
source(modDirectory .. "scripts/events/RL_BroadcastSettingsEvent.lua")
source(modDirectory .. "scripts/events/RL_ResetDealerEvent.lua")

-- SECTION 20d: Insemination (dewar manager)
source(modDirectory .. "scripts/insemination/DewarManager.lua")

-- SECTION 20e: Disease. The pure tier first, then the entities that consume it.
source(modDirectory .. "scripts/disease/RLDiseaseRates.lua")
-- Must precede the parser: RLDiseaseDefinition reads RLDiseaseRecord.ENDPOINT at file scope,
-- so sourcing the parser first raises on a nil global. The headless env sources the record
-- itself, so only the in-game run covers this ordering.
source(modDirectory .. "scripts/disease/RLDiseaseRecord.lua")
-- Reads RLDiseaseRecord at call time only.
source(modDirectory .. "scripts/disease/RLDiseaseDifficulty.lua")
source(modDirectory .. "scripts/disease/RLDiseaseDefinition.lua")
-- Reads RLConstants at file scope, so it must follow SECTION 2c.
source(modDirectory .. "scripts/disease/RLDiseaseVulnerability.lua")
source(modDirectory .. "scripts/disease/RLDiseaseFatality.lua")
source(modDirectory .. "scripts/disease/RLDiseaseGenetics.lua")
source(modDirectory .. "scripts/disease/RLDiseaseTransmission.lua")
source(modDirectory .. "scripts/disease/RLDiseaseSpread.lua")
source(modDirectory .. "scripts/disease/RLDiseaseEffects.lua")
source(modDirectory .. "scripts/disease/RLDiseaseProgression.lua")
source(modDirectory .. "scripts/disease/RLDiseaseStatus.lua")
source(modDirectory .. "scripts/disease/RLDiseaseCull.lua")
source(modDirectory .. "scripts/disease/RLDiseaseVaccination.lua")
source(modDirectory .. "scripts/disease/RLDiseaseSaleGate.lua")
source(modDirectory .. "scripts/disease/Disease.lua")
source(modDirectory .. "scripts/disease/DiseaseManager.lua")

-- SECTION 20e2: Disease selection (registry first: the serializer bootstraps its singleton at file scope)
source(modDirectory .. "scripts/disease/RLDiseaseOverrideRegistry.lua")
source(modDirectory .. "scripts/disease/RLDiseaseOverrideSerialization.lua")
source(modDirectory .. "scripts/disease/RLDiseaseOverrideCatalog.lua")
source(modDirectory .. "scripts/disease/RLDiseaseSelectorModel.lua")
source(modDirectory .. "scripts/disease/RLDiseaseOverrideReconcile.lua")
source(modDirectory .. "scripts/events/RLDiseaseOverrideStateEvent.lua")
source(modDirectory .. "scripts/events/RLDiseaseOverrideSetEvent.lua")

-- SECTION 20f: Core (lifecycle, settings, i18n)
source(modDirectory .. "scripts/core/FSCareerMissionInfo.lua")
-- T02 ledger save hooks; after RLRM's own careerSavegame append, so the ledger is written last.
RLTradeCheckpoint.install()
RLDealerCheckpoint.install()
RLAnimalIdentityCheckpoint.install()
source(modDirectory .. "scripts/core/I18N.lua")
source(modDirectory .. "scripts/core/RealisticLivestock.lua")

-- SECTION 20g: Animal entity
source(modDirectory .. "scripts/animal/RealisticLivestock_Animal.lua")

-- SECTION 20h: Core (FS base mission hooks)
source(modDirectory .. "scripts/core/RealisticLivestock_FSBaseMission.lua")

-- SECTION 20i: Console commands
source(modDirectory .. "scripts/console/RLBodyConditionConsole.lua")
source(modDirectory .. "scripts/console/RLTradeReportConsole.lua")
source(modDirectory .. "scripts/console/RLPenConsole.lua")
source(modDirectory .. "scripts/console/RLDealerConsole.lua")
source(modDirectory .. "scripts/console/RLIdentityConsole.lua")
source(modDirectory .. "scripts/console/RLFeedConsole.lua")
source(modDirectory .. "scripts/console/RLConsoleCommandManager.lua")

-- SECTION 20j: Messaging
-- Reads RLConstants at file scope, so it must follow SECTION 2c.
source(modDirectory .. "scripts/messaging/RLMessage.lua")
source(modDirectory .. "scripts/messaging/RLMessageAggregator.lua")

-- SECTION 20k: Core (settings)
source(modDirectory .. "scripts/core/RLAnimalExport.lua")
source(modDirectory .. "scripts/core/RLSettings.lua")
source(modDirectory .. "scripts/utils/RLDebugUtils.lua")

-- =============================================================================
-- RL Tabbed Menu: install hooks, after every source above has loaded.
-- =============================================================================

RLMenu.install()

-- =============================================================================
-- TESTING (conditional - delete tests/ folder for production)
-- =============================================================================

local testRunnerPath = modDirectory .. "scripts/tests/RLTestRunner.lua"
if fileExists(testRunnerPath) then
    source(testRunnerPath)
end

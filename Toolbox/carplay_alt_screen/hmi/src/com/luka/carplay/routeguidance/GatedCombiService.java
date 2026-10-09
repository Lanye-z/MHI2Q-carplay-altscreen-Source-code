/*
 * V3.3 per-field BAP ownership gate.
 * Every field defaults to fail-open stock passthrough.
 */
package com.luka.carplay.routeguidance;

import de.audi.atip.interapp.combi.bap.navi.CombiBAPServiceNavi;
import de.audi.atip.interapp.combi.bap.audio.data.CombiBAPTMCInfoMessage;
import de.audi.atip.interapp.combi.bap.navi.data.*;

public final class GatedCombiService implements CombiBAPServiceNavi {
    final CombiBAPServiceNavi real;
    private volatile boolean blockFct19;
    private volatile boolean blockFct21;
    private volatile boolean blockFct22;
    private volatile boolean blockPresentationContext;

    public GatedCombiService(CombiBAPServiceNavi r) { real = r; }

    public void setBlockedFields(boolean fct19, boolean fct21, boolean fct22) {
        blockFct19 = fct19; blockFct21 = fct21; blockFct22 = fct22;
    }
    public boolean isFct19Blocked() { return blockFct19; }
    public boolean isFct21Blocked() { return blockFct21; }
    public boolean isFct22Blocked() { return blockFct22; }
    public void setPresentationContextBlocked(boolean value) {
        blockPresentationContext = value;
    }
    public boolean isPresentationContextBlocked() {
        return blockPresentationContext;
    }

    public void updateCurrentPositionInfo(String v) { if (!blockFct19) real.updateCurrentPositionInfo(v); }
    public void updateDistanceToDestination(int v,int u,boolean s) { if (!blockFct21) real.updateDistanceToDestination(v,u,s); }
    public void updateTimeToDestination(int t,int f,long v) { if (!blockFct22) real.updateTimeToDestination(t,f,v); }
    public void updateRGStatus(int a){if(!blockPresentationContext)real.updateRGStatus(a);}
    public void updateActiveRGType(int a){if(!blockPresentationContext)real.updateActiveRGType(a);}
    public void updateDistanceToNextManeuver(int a,int b,boolean c,int d){if(!blockPresentationContext)real.updateDistanceToNextManeuver(a,b,c,d);}
    public void updateManeuverDescriptor(CombiBAPNaviManeuverDescriptor[] a){if(!blockPresentationContext)real.updateManeuverDescriptor(a);}
    public void updateLaneGuidance(boolean a,CombiBAPNaviLaneGuidanceData[] b){if(!blockPresentationContext)real.updateLaneGuidance(a,b);}
    public void updateExitView(int a,int b){if(!blockPresentationContext)real.updateExitView(a,b);}
    public void updateManeuverState(int a){if(!blockPresentationContext)real.updateManeuverState(a);}
    public void showInitializingScreen(){real.showInitializingScreen();}
    public void hideInitializingScreen(){real.hideInitializingScreen();}
    public void updateCompassInfo(int a,int b){real.updateCompassInfo(a,b);}
    public void updateTurnToInfo(String a,String b){real.updateTurnToInfo(a,b);}
    public void updateTMCInfoMessages(CombiBAPTMCInfoMessage[] a){real.updateTMCInfoMessages(a);}
    public void updateLastDestinationsList(CombiBAPDestinationListEntry[] a){real.updateLastDestinationsList(a);}
    public void updateFavoriteDestinationsList(CombiBAPDestinationListEntry[] a){real.updateFavoriteDestinationsList(a);}
    public void updateHomeAddress(CombiBAPNaviDestination a){real.updateHomeAddress(a);}
    public void routeGuidanceActDeactResult(int a){real.routeGuidanceActDeactResult(a);}
    public void repeatLastNavAnnouncementResult(int a){real.repeatLastNavAnnouncementResult(a);}
    public void updateVoiceGuidanceState(int a){real.updateVoiceGuidanceState(a);}
    public void updateInfoStates(int a){real.updateInfoStates(a);}
    public void updateTrafficBlockIndication(int a){real.updateTrafficBlockIndication(a);}
    public void updateMapColor(int a){real.updateMapColor(a);}
    public void updateMapType(int a,int b){real.updateMapType(a,b);}
    public void updateSupportedMapTypes(boolean a,int b){real.updateSupportedMapTypes(a,b);}
    public void updateMapView(int a,int b){real.updateMapView(a,b);}
    public void updateSupportedMapViews(int a,int b){real.updateSupportedMapViews(a,b);}
    public void updateMapVisibility(boolean a,boolean b){real.updateMapVisibility(a,b);}
    public void updateMapOrientation(int a){real.updateMapOrientation(a);}
    public void updateMapScale(int a,boolean b,int c,int d,boolean e){real.updateMapScale(a,b,c,d,e);}
    public void updateDestinationInfo(CombiBAPDestinationInfo a){real.updateDestinationInfo(a);}
    public void updateAltitude(int a,int b){real.updateAltitude(a,b);}
    public void updateOnlineNavigationState(int a,int b,int c){real.updateOnlineNavigationState(a,b,c);}
    public void updateSemidynamicRouteGuidance(CombiBAPSemiDynamicRouteInfo a){real.updateSemidynamicRouteGuidance(a);}
    public void poiSearchResult(int a,int b){real.poiSearchResult(a,b);}
    public void updatePOIListSize(int a){real.updatePOIListSize(a);}
    public void updateFSGSetup(int a,boolean b){real.updateFSGSetup(a,b);}
    public void updateMapPresentation(boolean a,boolean b,boolean c){real.updateMapPresentation(a,b,c);}
    public void updateEtcStatus(EtcStatus a){real.updateEtcStatus(a);}
}

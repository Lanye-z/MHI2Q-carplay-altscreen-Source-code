/*
 * V3.3 BAP ownership gate.
 *
 * Route/maneuver/map behavior stays stock.  While CarPlay RGI is active only
 * the three OEM lower-bar fields owned by V3.3 are blocked from the stock
 * navigator:
 *   FctID 19 CurrentPositionInfo
 *   FctID 21 DistanceToDestination
 *   FctID 22 TimeToDestination
 *
 * FctID 45 MapScale and FctID 47 Altitude always pass through unchanged.
 */
package com.luka.carplay.routeguidance;

import de.audi.atip.interapp.combi.bap.navi.CombiBAPServiceNavi;
import de.audi.atip.interapp.combi.bap.audio.data.CombiBAPTMCInfoMessage;
import de.audi.atip.interapp.combi.bap.navi.data.CombiBAPDestinationInfo;
import de.audi.atip.interapp.combi.bap.navi.data.CombiBAPDestinationListEntry;
import de.audi.atip.interapp.combi.bap.navi.data.CombiBAPNaviDestination;
import de.audi.atip.interapp.combi.bap.navi.data.CombiBAPNaviLaneGuidanceData;
import de.audi.atip.interapp.combi.bap.navi.data.CombiBAPNaviManeuverDescriptor;
import de.audi.atip.interapp.combi.bap.navi.data.CombiBAPSemiDynamicRouteInfo;
import de.audi.atip.interapp.combi.bap.navi.data.EtcStatus;

public final class GatedCombiService implements CombiBAPServiceNavi {
    final CombiBAPServiceNavi real;
    private volatile boolean blockLowerBar;

    public GatedCombiService(CombiBAPServiceNavi r) { this.real = r; }

    public void setLowerBarBlocked(boolean active) { blockLowerBar = active; }
    public boolean isLowerBarBlocked() { return blockLowerBar; }

    /* V3.3-owned OEM lower-bar fields. */
    public void updateCurrentPositionInfo(String value) {
        if (!blockLowerBar) real.updateCurrentPositionInfo(value);
    }
    public void updateDistanceToDestination(int value, int unit, boolean stopover) {
        if (!blockLowerBar) real.updateDistanceToDestination(value, unit, stopover);
    }
    public void updateTimeToDestination(int infoType, int format, long value) {
        if (!blockLowerBar) real.updateTimeToDestination(infoType, format, value);
    }

    /* Everything else remains OEM stock-owned. */
    public void updateRGStatus(int a) { real.updateRGStatus(a); }
    public void updateActiveRGType(int a) { real.updateActiveRGType(a); }
    public void updateDistanceToNextManeuver(int a, int b, boolean c, int d) {
        real.updateDistanceToNextManeuver(a, b, c, d);
    }
    public void updateManeuverDescriptor(CombiBAPNaviManeuverDescriptor[] a) {
        real.updateManeuverDescriptor(a);
    }
    public void updateLaneGuidance(boolean a, CombiBAPNaviLaneGuidanceData[] b) {
        real.updateLaneGuidance(a, b);
    }
    public void updateExitView(int a, int b) { real.updateExitView(a, b); }
    public void updateManeuverState(int a) { real.updateManeuverState(a); }
    public void showInitializingScreen() { real.showInitializingScreen(); }
    public void hideInitializingScreen() { real.hideInitializingScreen(); }
    public void updateCompassInfo(int a, int b) { real.updateCompassInfo(a, b); }
    public void updateTurnToInfo(String a, String b) { real.updateTurnToInfo(a, b); }
    public void updateTMCInfoMessages(CombiBAPTMCInfoMessage[] a) {
        real.updateTMCInfoMessages(a);
    }
    public void updateLastDestinationsList(CombiBAPDestinationListEntry[] a) {
        real.updateLastDestinationsList(a);
    }
    public void updateFavoriteDestinationsList(CombiBAPDestinationListEntry[] a) {
        real.updateFavoriteDestinationsList(a);
    }
    public void updateHomeAddress(CombiBAPNaviDestination a) { real.updateHomeAddress(a); }
    public void routeGuidanceActDeactResult(int a) { real.routeGuidanceActDeactResult(a); }
    public void repeatLastNavAnnouncementResult(int a) {
        real.repeatLastNavAnnouncementResult(a);
    }
    public void updateVoiceGuidanceState(int a) { real.updateVoiceGuidanceState(a); }
    public void updateInfoStates(int a) { real.updateInfoStates(a); }
    public void updateTrafficBlockIndication(int a) { real.updateTrafficBlockIndication(a); }
    public void updateMapColor(int a) { real.updateMapColor(a); }
    public void updateMapType(int a, int b) { real.updateMapType(a, b); }
    public void updateSupportedMapTypes(boolean a, int b) { real.updateSupportedMapTypes(a, b); }
    public void updateMapView(int a, int b) { real.updateMapView(a, b); }
    public void updateSupportedMapViews(int a, int b) { real.updateSupportedMapViews(a, b); }
    public void updateMapVisibility(boolean a, boolean b) { real.updateMapVisibility(a, b); }
    public void updateMapOrientation(int a) { real.updateMapOrientation(a); }
    public void updateMapScale(int a, boolean b, int c, int d, boolean e) {
        real.updateMapScale(a, b, c, d, e);
    }
    public void updateDestinationInfo(CombiBAPDestinationInfo a) {
        real.updateDestinationInfo(a);
    }
    public void updateAltitude(int a, int b) { real.updateAltitude(a, b); }
    public void updateOnlineNavigationState(int a, int b, int c) {
        real.updateOnlineNavigationState(a, b, c);
    }
    public void updateSemidynamicRouteGuidance(CombiBAPSemiDynamicRouteInfo a) {
        real.updateSemidynamicRouteGuidance(a);
    }
    public void poiSearchResult(int a, int b) { real.poiSearchResult(a, b); }
    public void updatePOIListSize(int a) { real.updatePOIListSize(a); }
    public void updateFSGSetup(int a, boolean b) { real.updateFSGSetup(a, b); }
    public void updateMapPresentation(boolean a, boolean b, boolean c) {
        real.updateMapPresentation(a, b, c);
    }
    public void updateEtcStatus(EtcStatus a) { real.updateEtcStatus(a); }
}

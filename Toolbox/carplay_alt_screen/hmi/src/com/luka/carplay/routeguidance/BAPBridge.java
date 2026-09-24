/*
 * V3.5 OEM lower-bar + local KOMO gray-bar bridge with read-only diagnostics.
 *
 * Partial takeover only:
 *   FctID 19 CurrentPositionInfo      -> CarPlay only while a valid road exists
 *   FctID 21 DistanceToDestination   -> CarPlay only while a valid distance exists
 *   FctID 22 TimeToDestination       -> CarPlay only while a valid ETA exists
 *
 * Invalid/missing CarPlay lower-bar data always fails open to the stock Audi producer.
 * V3.4 mirrors the same road/distance/ETA into ClusterService/KOMO follow-info
 * so the existing gray route-info strip is updated without setting rgActive,
 * rgiDataValid, RGStatus, ActiveRGType or any maneuver presentation field.
 * FctID 45 MapScale is never written here.
 *
 * Java 1.2 compatible.
 */
package com.luka.carplay.routeguidance;

import com.luka.carplay.CarPlayHook;
import com.luka.carplay.framework.Log;
import de.audi.atip.base.IFrameworkAccess;
import de.audi.atip.interapp.combi.bap.navi.CombiBAPServiceNavi;
import de.audi.atip.interapp.combi.bap.navi.data.CombiBAPNaviLaneGuidanceData;
import de.audi.atip.interapp.combi.bap.navi.data.CombiBAPNaviManeuverDescriptor;
import de.audi.atip.log.LogChannel;
import de.audi.atip.metrics.DateMetric;
import de.audi.atip.metrics.Distance;
import de.audi.tghu.navi.app.Navigation;
import de.audi.tghu.navi.app.cluster.BAPDistanceFormatter;
import de.audi.tghu.navi.app.cluster.ClusterService;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

public final class BAPBridge {
    private static final String TAG = "VCOemLowerBar";
    private static final int FCT19 = 19;
    private static final int FCT21 = 21;
    private static final int FCT22 = 22;

    private CombiBAPServiceNavi appConnectorNavi;
    private GatedCombiService gate;
    private final BAPDistanceFormatter distanceFormatter =
        new BAPDistanceFormatter(new SilentLogChannel());

    private boolean initialized;
    private boolean sessionActive;
    private boolean ownFct19;
    private boolean ownFct21;
    private boolean ownFct22;

    private boolean oemRgStateKnown;
    private boolean oemRgActiveAtStart;

    private long lastEtaSeconds = -1L;
    private long lastRemainingSeconds = -1L;
    private long lastRemainingSampleUtcSeconds = -1L;

    public boolean init(Object naviService) {
        if (initialized) return true;
        try {
            if (!(naviService instanceof CombiBAPServiceNavi)) {
                Log.e(TAG, "Init failed: service is not CombiBAPServiceNavi");
                return false;
            }
            appConnectorNavi = (CombiBAPServiceNavi)naviService;
            initialized = true;
            Log.i(TAG, "Initialized partial_takeover=LAZY_PER_FIELD"
                + " fields=19,21,22 mapScale=stock");
            return true;
        } catch (Throwable t) {
            Log.e(TAG, "Init failed", t);
            return false;
        }
    }

    public void onStart() {
        releaseAllFields("session_start", true);
        sessionActive = true;
        oemRgStateKnown = false;
        oemRgActiveAtStart = false;
        lastEtaSeconds = -1L;
        lastRemainingSeconds = -1L;
        lastRemainingSampleUtcSeconds = -1L;

        captureOemRgState();
        Log.i(TAG, "LOWER_BAR_SESSION=ACTIVE takeover=LAZY_PER_FIELD"
            + " fields=19,21,22"
            + " gray_bar=KOMO_FOLLOW_INFO"
            + " rg_presentation=UNTOUCHED");
    }

    public void onStop() {
        /* Actual release is centralized in onShutdown(). */
    }

    public void onShutdown() {
        sessionActive = false;
        clearOwnedKomoFieldsBestEffort("shutdown");
        releaseAllFields("shutdown", true);
        lastEtaSeconds = -1L;
        lastRemainingSeconds = -1L;
        lastRemainingSampleUtcSeconds = -1L;
        oemRgStateKnown = false;
        Log.i(TAG, "LOWER_BAR_SESSION=INACTIVE"
            + " stock_listener_restore=BEST_EFFORT"
            + " gray_bar_release=BEST_EFFORT"
            + " rg_presentation=UNTOUCHED");
    }

    public void update(RouteGuidance.State s) {
        if (!initialized || !sessionActive || s == null) return;
        int dirty = s.dirtyMask;

        if ((dirty & RouteGuidance.State.DIRTY_CURRENT_ROAD) != 0) {
            String road = limitUtf8(s.currentRoad, 96);
            if (road.length() > 0) publishRoad(road);
            else releaseField(FCT19, "invalid_or_empty");
        }

        if ((dirty & RouteGuidance.State.DIRTY_DIST_DEST) != 0) {
            if (s.distDestM > 0) publishDistance(s.distDestM);
            else releaseField(FCT21, "invalid_or_zero");
        }

        if ((dirty & RouteGuidance.State.DIRTY_ETA) != 0)
            lastEtaSeconds = s.etaSeconds;
        if ((dirty & RouteGuidance.State.DIRTY_TIME_REMAINING) != 0) {
            lastRemainingSeconds = s.timeRemainingSeconds;
            lastRemainingSampleUtcSeconds =
                lastRemainingSeconds >= 0L ? getUtcMillis() / 1000L : -1L;
        }
        if ((dirty & (RouteGuidance.State.DIRTY_ETA
                    | RouteGuidance.State.DIRTY_TIME_REMAINING)) != 0)
            publishArrivalOrRelease();
    }

    private void publishRoad(String road) {
        if (!acquireField(FCT19)) return;
        try {
            publishKomoCurrentStreet(road);
            appConnectorNavi.updateCurrentPositionInfo(road);
            Log.i(TAG, "OEM_FCT19 source=CARPLAY current_road=" + road
                + " gray_bar=KOMO_CURRENT_STREET");
        } catch (Throwable t) {
            Log.e(TAG, "OEM_FCT19 publish failed; fail-open to stock", t);
            releaseField(FCT19, "publish_failed");
        }
    }

    private void publishDistance(int meters) {
        FormattedDistance fd = formatDistanceToDestination(meters);
        if (fd.value < 0) {
            releaseField(FCT21, "format_failed");
            return;
        }
        if (!acquireField(FCT21)) return;
        try {
            publishKomoDistance(meters);
            appConnectorNavi.updateDistanceToDestination(fd.value, fd.unit, false);
            Log.i(TAG, "OEM_FCT21 source=CARPLAY dist_m=" + meters
                + " bap_value=" + fd.value + " bap_unit=" + fd.unit
                + " gray_bar=KOMO_DISTANCE");
        } catch (Throwable t) {
            Log.e(TAG, "OEM_FCT21 publish failed; fail-open to stock", t);
            releaseField(FCT21, "publish_failed");
        }
    }

    private void publishArrivalOrRelease() {
        long utcSeconds = currentArrivalSeconds();
        if (utcSeconds < 0L) {
            releaseField(FCT22, "invalid_eta");
            return;
        }

        long localSeconds = convertUtcToLocalMs(utcSeconds * 1000L) / 1000L;
        int timeFormat = getHuNavigationTimeFormat();
        if (!acquireField(FCT22)) return;
        try {
            publishKomoArrival(utcSeconds);
            appConnectorNavi.updateTimeToDestination(1, timeFormat, localSeconds);
            Log.i(TAG, "OEM_FCT22 source=CARPLAY eta_utc=" + utcSeconds
                + " eta_local=" + localSeconds + " format=" + timeFormat
                + " gray_bar=KOMO_ETA");
        } catch (Throwable t) {
            Log.e(TAG, "OEM_FCT22 publish failed; fail-open to stock", t);
            releaseField(FCT22, "publish_failed");
        }
    }

    private boolean acquireField(int fct) {
        if (!sessionActive) return false;
        if (!ensureGateInstalled()) {
            Log.w(TAG, "LOWER_BAR_FIELD=FCT" + fct
                + " action=PENDING reason=gate_unavailable");
            return false;
        }

        boolean wasOwned = isFieldOwned(fct);
        setFieldOwned(fct, true);
        syncGateBlocks();
        if (!wasOwned)
            Log.i(TAG, "LOWER_BAR_FIELD=FCT" + fct
                + " action=ACQUIRE stock_blocked=YES");
        return true;
    }

    private void releaseField(int fct, String reason) {
        boolean wasOwned = isFieldOwned(fct);
        if (!wasOwned) return;

        clearKomoFieldBestEffort(fct, reason);
        setFieldOwned(fct, false);
        syncGateBlocks();
        Log.i(TAG, "LOWER_BAR_FIELD=FCT" + fct
            + " action=RELEASE reason=" + reason
            + " stock_passthrough=YES synthetic_clear=NO");
        if (!anyFieldOwned())
            restoreStockListenerIfOwned("no_owned_fields");
    }

    private void releaseAllFields(String reason, boolean restoreListener) {
        boolean hadOwnership = anyFieldOwned();
        ownFct19 = false;
        ownFct21 = false;
        ownFct22 = false;
        syncGateBlocks();

        if (hadOwnership)
            Log.i(TAG, "LOWER_BAR_FIELDS=19,21,22 action=RELEASE_ALL reason="
                + reason + " synthetic_clear=NO");
        if (restoreListener)
            restoreStockListenerIfOwned(reason);
    }

    private boolean ensureGateInstalled() {
        try {
            Navigation nav = Navigation.getInstance();
            if (nav == null) return false;
            ClusterService cs = nav.getClusterService();
            if (cs == null) return false;

            CombiBAPServiceNavi current = cs.getCombiBAPListenerCombiService();
            if (current == null) return false;

            if (current == gate) {
                /*
                 * Keep the raw publisher aligned with the listener currently
                 * wrapped by the gate.  This matters after HMI service
                 * replacement: Fct19/21/22 and the presentation sync must not
                 * keep writing to an old detached CombiBAPServiceNavi.
                 */
                if (gate != null && gate.real != null)
                    appConnectorNavi = gate.real;
                syncGateBlocks();
                return true;
            }

            if (current instanceof GatedCombiService) {
                gate = (GatedCombiService)current;
                appConnectorNavi = gate.real;
                syncGateBlocks();
                Log.w(TAG, "LOWER_BAR_GATE=ADOPTED existing_gate=YES service=REFRESHED");
                return true;
            }

            boolean replacingDetachedGate = gate != null;
            appConnectorNavi = current;
            gate = new GatedCombiService(current);
            syncGateBlocks();
            cs.setCombiBAPListenerCombiService(gate);
            if (replacingDetachedGate) {
                Log.w(TAG, "LOWER_BAR_GATE=REINSTALLED reason=cluster_listener_replaced");
            }
            else
                Log.i(TAG, "LOWER_BAR_GATE=INSTALLED mode=LAZY_PER_FIELD");
            return true;
        } catch (Throwable t) {
            Log.w(TAG, "gate install failed: " + t);
            return false;
        }
    }

    private void restoreStockListenerIfOwned(String reason) {
        GatedCombiService oldGate = gate;
        if (oldGate == null) return;

        oldGate.setBlockedFields(false, false, false);
        try {
            Navigation nav = Navigation.getInstance();
            ClusterService cs = nav != null ? nav.getClusterService() : null;
            if (cs == null) {
                gate = null;
                Log.w(TAG, "LOWER_BAR_GATE=DETACHED reason=" + reason
                    + " stock_restore=UNAVAILABLE");
                return;
            }

            CombiBAPServiceNavi current = cs.getCombiBAPListenerCombiService();
            if (current == oldGate) {
                cs.setCombiBAPListenerCombiService(oldGate.real);
                Log.i(TAG, "LOWER_BAR_GATE=REMOVED reason=" + reason
                    + " stock_listener_restored=YES");
            } else {
                Log.i(TAG, "LOWER_BAR_GATE=DETACHED reason=" + reason
                    + " stock_listener_restored=SKIP_CURRENT_CHANGED");
            }
        } catch (Throwable t) {
            Log.w(TAG, "stock listener restore failed: " + t);
        } finally {
            gate = null;
        }
    }

    private void syncGateBlocks() {
        if (gate != null) {
            gate.setBlockedFields(ownFct19, ownFct21, ownFct22);
            gate.setPresentationContextBlocked(false);
        }
    }

    private boolean anyFieldOwned() {
        return ownFct19 || ownFct21 || ownFct22;
    }

    private boolean isFieldOwned(int fct) {
        if (fct == FCT19) return ownFct19;
        if (fct == FCT21) return ownFct21;
        if (fct == FCT22) return ownFct22;
        return false;
    }

    private void setFieldOwned(int fct, boolean value) {
        if (fct == FCT19) ownFct19 = value;
        else if (fct == FCT21) ownFct21 = value;
        else if (fct == FCT22) ownFct22 = value;
    }


    /*
     * Gray-bar integration.
     *
     * Vehicle evidence showed that driving rgActive/rgiDataValid plus
     * Fct17/Fct39 activates the maneuver/arrow window. The lower gray strip is
     * fed by ClusterService's KOMO follow-info path instead. Mirror only the
     * values needed by that strip and leave complete RGI presentation state
     * untouched.
     */
    private void captureOemRgState() {
        ClusterService cs = currentClusterService();
        Object container = findDsiContainer(cs);
        Boolean active = readBooleanMethod(container, "isRgActive");
        if (active != null) {
            oemRgStateKnown = true;
            oemRgActiveAtStart = active.booleanValue();
            Log.i(TAG, "OEM_GRAY_BAR_CONTEXT rg_active_snapshot="
                + oemRgActiveAtStart + " presentation_mutation=NO");
        } else {
            Log.w(TAG, "OEM_GRAY_BAR_CONTEXT rg_active_snapshot=UNKNOWN"
                + " presentation_mutation=NO");
        }
        /*
         * V3.5 diagnostics are observation-only.  Do not turn any of these
         * reads into an activation gate: their purpose is to distinguish
         * "KOMO data reached an already-following strip" from "KOMO data was
         * accepted while the cluster remained outside Follow mode".
         */
        logGrayBarObservation("BEFORE", cs, "SESSION_START");
    }

    private void publishKomoCurrentStreet(String road) {
        ClusterService cs = currentClusterService();
        logGrayBarObservation("BEFORE", cs, "CURRENT_STREET");
        if (cs == null) {
            Log.w(TAG, "SET_CURRENT_STREET=FAIL reason=KOMO_SERVICE_NULL");
            Log.i(TAG, "ROUTE_INFO_FLUSH=NOT_ATTEMPTED field=CURRENT_STREET behavior_preserved=YES");
            logGrayBarObservation("AFTER", cs, "CURRENT_STREET");
            Log.w(TAG, "OEM_GRAY_BAR field=ROAD result=SKIP reason=cluster_unavailable");
            return;
        }
        try {
            invokeCluster(cs, "updateCurrentStreet",
                new Class[]{String.class}, new Object[]{road});
            Log.i(TAG, "SET_CURRENT_STREET=PASS");
            /* V3.4 did not flush after CurrentStreet; keep that exact behavior. */
            Log.i(TAG, "ROUTE_INFO_FLUSH=NOT_ATTEMPTED field=CURRENT_STREET behavior_preserved=YES");
            Log.i(TAG, "OEM_GRAY_BAR field=ROAD result=PASS value=" + road);
        } catch (Throwable t) {
            Log.w(TAG, "SET_CURRENT_STREET=FAIL error=" + t);
            Log.w(TAG, "OEM_GRAY_BAR field=ROAD result=FAIL error=" + t);
        } finally {
            logGrayBarObservation("AFTER", cs, "CURRENT_STREET");
        }
    }

    private void publishKomoDistance(int meters) {
        ClusterService cs = currentClusterService();
        logGrayBarObservation("BEFORE", cs, "DISTANCE");
        if (cs == null) {
            Log.w(TAG, "SET_DISTANCE=FAIL reason=KOMO_SERVICE_NULL");
            Log.i(TAG, "ROUTE_INFO_FLUSH=NOT_ATTEMPTED field=DISTANCE reason=KOMO_SERVICE_NULL");
            logGrayBarObservation("AFTER", cs, "DISTANCE");
            Log.w(TAG, "OEM_GRAY_BAR field=DISTANCE result=SKIP reason=cluster_unavailable");
            return;
        }
        try {
            invokeCluster(cs, "updateDistanceToDestination",
                new Class[]{Integer.TYPE, Boolean.TYPE},
                new Object[]{new Integer(meters), Boolean.FALSE});
            Log.i(TAG, "SET_DISTANCE=PASS");
            flushKomoFollowInfo(cs, "DISTANCE");
            Log.i(TAG, "OEM_GRAY_BAR field=DISTANCE result=PASS meters=" + meters);
        } catch (Throwable t) {
            Log.w(TAG, "SET_DISTANCE=FAIL_OR_FLUSH_FAIL error=" + t);
            Log.w(TAG, "OEM_GRAY_BAR field=DISTANCE result=FAIL error=" + t);
        } finally {
            logGrayBarObservation("AFTER", cs, "DISTANCE");
        }
    }

    private void publishKomoArrival(long utcSeconds) {
        ClusterService cs = currentClusterService();
        logGrayBarObservation("BEFORE", cs, "ETA");
        if (cs == null) {
            Log.w(TAG, "SET_ETA=FAIL reason=KOMO_SERVICE_NULL");
            Log.i(TAG, "ROUTE_INFO_FLUSH=NOT_ATTEMPTED field=ETA reason=KOMO_SERVICE_NULL");
            logGrayBarObservation("AFTER", cs, "ETA");
            Log.w(TAG, "OEM_GRAY_BAR field=ETA result=SKIP reason=cluster_unavailable");
            return;
        }
        try {
            long utcMillis = utcSeconds * 1000L;
            invokeCluster(cs, "updateArrivalTime",
                new Class[]{Boolean.TYPE, Long.TYPE, Boolean.TYPE},
                new Object[]{Boolean.TRUE, new Long(utcMillis), Boolean.FALSE});
            Log.i(TAG, "SET_ETA=PASS");
            flushKomoFollowInfo(cs, "ETA");
            Log.i(TAG, "OEM_GRAY_BAR field=ETA result=PASS utc_ms=" + utcMillis
                + " timezone_offset_flag=0");
        } catch (Throwable t) {
            Log.w(TAG, "SET_ETA=FAIL_OR_FLUSH_FAIL error=" + t);
            Log.w(TAG, "OEM_GRAY_BAR field=ETA result=FAIL error=" + t);
        } finally {
            logGrayBarObservation("AFTER", cs, "ETA");
        }
    }

    private void clearOwnedKomoFieldsBestEffort(String reason) {
        if (ownFct19) clearKomoFieldBestEffort(FCT19, reason);
        if (ownFct21) clearKomoFieldBestEffort(FCT21, reason);
        if (ownFct22) clearKomoFieldBestEffort(FCT22, reason);
    }

    private void clearKomoFieldBestEffort(int fct, String reason) {
        ClusterService cs = currentClusterService();
        Boolean active = readBooleanMethod(findDsiContainer(cs), "isRgActive");
        if (active == null) {
            Log.w(TAG, "OEM_GRAY_BAR_CLEAR field=FCT" + fct
                + " result=SKIP reason=oem_rg_state_unknown");
            return;
        }
        if (active.booleanValue()) {
            Log.i(TAG, "OEM_GRAY_BAR_CLEAR field=FCT" + fct
                + " result=SKIP reason=oem_rg_active stock_refresh_expected=YES");
            return;
        }
        if (cs == null) return;
        try {
            if (fct == FCT19) {
                invokeCluster(cs, "updateCurrentStreet",
                    new Class[]{String.class}, new Object[]{""});
            } else if (fct == FCT21) {
                invokeCluster(cs, "updateDistanceToDestination",
                    new Class[]{Integer.TYPE, Boolean.TYPE},
                    new Object[]{new Integer(0), Boolean.FALSE});
                flushKomoFollowInfo(cs, "CLEAR_FCT21");
            } else if (fct == FCT22) {
                invokeCluster(cs, "updateArrivalTime",
                    new Class[]{Boolean.TYPE, Long.TYPE, Boolean.TYPE},
                    new Object[]{Boolean.FALSE, new Long(0L), Boolean.FALSE});
                flushKomoFollowInfo(cs, "CLEAR_FCT22");
            }
            Log.i(TAG, "OEM_GRAY_BAR_CLEAR field=FCT" + fct
                + " result=PASS reason=" + reason);
        } catch (Throwable t) {
            Log.w(TAG, "OEM_GRAY_BAR_CLEAR field=FCT" + fct
                + " result=FAIL reason=" + reason + " error=" + t);
        }
    }

    private static void flushKomoFollowInfo(ClusterService cs, String field)
            throws Exception {
        Log.i(TAG, "ROUTE_INFO_FLUSH=ATTEMPTED field=" + field
            + " behavior_change=NO");
        invokeCluster(cs, "updateKOMOFollowInfo", new Class[0], new Object[0]);
        Log.i(TAG, "ROUTE_INFO_FLUSH=PASS field=" + field);
    }

    private static void logGrayBarObservation(
            String edge, ClusterService cs, String field) {
        Log.i(TAG, "KOMO_SERVICE=" + (cs != null ? "AVAILABLE" : "NULL")
            + " edge=" + edge + " field=" + field);

        Boolean follow = readKomoFollowMode(cs);
        if (follow == null) {
            Log.i(TAG, "KOMO_FOLLOW_MODE=UNKNOWN edge=" + edge + " field=" + field);
            Log.i(TAG, "ROUTE_INFO_MODE=UNKNOWN edge=" + edge + " field=" + field);
        } else {
            Log.i(TAG, "KOMO_FOLLOW_MODE="
                + (follow.booleanValue() ? "YES" : "NO")
                + " edge=" + edge + " field=" + field);
            Log.i(TAG, "ROUTE_INFO_MODE="
                + (follow.booleanValue() ? "FOLLOW" : "NOT_FOLLOW")
                + " edge=" + edge + " field=" + field);
        }

        Boolean rgActive = readBooleanMethod(findDsiContainer(cs), "isRgActive");
        Boolean rgiValid = readRgiDataValid(cs);
        Log.i(TAG, "RG_ACTIVE_" + edge + "=" + booleanBit(rgActive)
            + " field=" + field);
        Log.i(TAG, "RGI_VALID_" + edge + "=" + booleanBit(rgiValid)
            + " field=" + field);
    }

    private static String booleanBit(Boolean value) {
        if (value == null) return "UNKNOWN";
        return value.booleanValue() ? "1" : "0";
    }

    private static Boolean readRgiDataValid(ClusterService cs) {
        if (cs == null) return null;
        Boolean value = readBooleanFieldExact(cs, new String[]{
            "rgiDataValid", "RGIDataValid", "mRgiDataValid", "mRGIDataValid"
        }, "RGI_VALID");
        if (value != null) return value;
        return readBooleanFieldByHints(cs,
            new String[]{"rgi", "valid"}, "RGI_VALID");
    }

    private static Boolean readKomoFollowMode(ClusterService cs) {
        if (cs == null) return null;
        Boolean value = readBooleanFieldExact(cs, new String[]{
            "komoFollowMode", "KOMOFollowMode", "followMode",
            "routeInfoFollowMode", "routeInfoModeFollow"
        }, "KOMO_FOLLOW");
        if (value != null) return value;

        value = readBooleanFieldByHints(cs,
            new String[]{"follow"}, "KOMO_FOLLOW");
        if (value != null) return value;

        Object container = findDsiContainer(cs);
        value = readBooleanFieldExact(container, new String[]{
            "komoFollowMode", "KOMOFollowMode", "followMode",
            "routeInfoFollowMode", "routeInfoModeFollow"
        }, "KOMO_FOLLOW_CONTAINER");
        if (value != null) return value;
        return readBooleanFieldByHints(container,
            new String[]{"follow"}, "KOMO_FOLLOW_CONTAINER");
    }

    private static Boolean readBooleanFieldExact(
            Object target, String[] names, String probe) {
        if (target == null || names == null) return null;
        for (int i = 0; i < names.length; ++i) {
            Field f = findField(target.getClass(), names[i]);
            if (f == null) continue;
            Boolean value = readBooleanField(target, f);
            if (value != null) {
                Log.i(TAG, probe + "_PROBE=FIELD_EXACT"
                    + " owner=" + target.getClass().getName()
                    + " field=" + f.getName()
                    + " value=" + booleanBit(value));
                return value;
            }
        }
        return null;
    }

    private static Boolean readBooleanFieldByHints(
            Object target, String[] hints, String probe) {
        if (target == null || hints == null) return null;
        Field candidate = null;
        Class c = target.getClass();
        while (c != null) {
            Field[] fields;
            try { fields = c.getDeclaredFields(); }
            catch (Throwable t) { fields = null; }
            if (fields != null) {
                for (int i = 0; i < fields.length; ++i) {
                    Field f = fields[i];
                    String name = f.getName().toLowerCase();
                    boolean matches = true;
                    for (int h = 0; h < hints.length; ++h) {
                        if (name.indexOf(hints[h].toLowerCase()) < 0) {
                            matches = false;
                            break;
                        }
                    }
                    if (!matches) continue;
                    Class type = f.getType();
                    if (type != Boolean.TYPE && type != Boolean.class) continue;
                    Boolean value = readBooleanField(target, f);
                    if (value == null) continue;
                    Log.i(TAG, probe + "_PROBE=FIELD_CANDIDATE"
                        + " owner=" + c.getName()
                        + " field=" + f.getName()
                        + " value=" + booleanBit(value));
                    if (candidate != null) {
                        Log.w(TAG, probe + "_PROBE=AMBIGUOUS"
                            + " first=" + candidate.getName()
                            + " second=" + f.getName()
                            + " classification=UNKNOWN");
                        return null;
                    }
                    candidate = f;
                }
            }
            c = c.getSuperclass();
        }
        return candidate != null ? readBooleanField(target, candidate) : null;
    }

    private static Boolean readBooleanField(Object target, Field field) {
        if (target == null || field == null) return null;
        try {
            field.setAccessible(true);
            Object value = field.get(target);
            return value instanceof Boolean ? (Boolean)value : null;
        } catch (Throwable t) {
            Log.w(TAG, "OEM_GRAY_BAR read field failed "
                + field.getName() + ": " + t);
            return null;
        }
    }

    private static ClusterService currentClusterService() {
        try {
            Navigation nav = Navigation.getInstance();
            return nav != null ? nav.getClusterService() : null;
        } catch (Throwable t) { return null; }
    }

    private static Object findDsiContainer(ClusterService cs) {
        if (cs == null) return null;
        try {
            Method m = findMethod(cs.getClass(), "getDSIResponseContainer", new Class[0]);
            if (m == null) return null;
            m.setAccessible(true);
            return m.invoke(cs, new Object[0]);
        } catch (Throwable direct) {
            try {
                Field envField = findField(cs.getClass(), "env");
                if (envField == null) return null;
                envField.setAccessible(true);
                Object env = envField.get(cs);
                if (env == null) return null;
                Method getContainer =
                    findMethod(env.getClass(), "getContainer", new Class[0]);
                if (getContainer == null) return null;
                getContainer.setAccessible(true);
                return getContainer.invoke(env, new Object[0]);
            } catch (Throwable fallback) {
                Log.w(TAG, "OEM_GRAY_BAR container lookup failed: " + fallback);
                return null;
            }
        }
    }

    private static Field findField(Class type, String name) {
        Class c = type;
        while (c != null) {
            try { return c.getDeclaredField(name); }
            catch (Throwable t) { c = c.getSuperclass(); }
        }
        return null;
    }

    private static Method findMethod(Class type, String name, Class[] signature) {
        Class c = type;
        while (c != null) {
            try { return c.getDeclaredMethod(name, signature); }
            catch (Throwable t) { c = c.getSuperclass(); }
        }
        return null;
    }

    private static Object invokeCluster(
            Object target, String name, Class[] signature, Object[] args)
            throws Exception {
        if (target == null) throw new Exception(name + ": target null");
        Method m = findMethod(target.getClass(), name, signature);
        if (m == null) throw new NoSuchMethodException(name);
        m.setAccessible(true);
        return m.invoke(target, args);
    }

    private static Boolean readBooleanMethod(Object target, String name) {
        if (target == null) return null;
        try {
            Method m = findMethod(target.getClass(), name, new Class[0]);
            if (m == null) return null;
            m.setAccessible(true);
            Object value = m.invoke(target, new Object[0]);
            return value instanceof Boolean ? (Boolean)value : null;
        } catch (Throwable t) {
            Log.w(TAG, "OEM_GRAY_BAR read method failed " + name + ": " + t);
            return null;
        }
    }

    private FormattedDistance formatDistanceToDestination(int meters) {
        try {
            boolean metric = isMetricDistanceUnits();
            Object d = distanceFormatter.formatDistanceToDestination(meters, metric);
            int value = ((Integer)d.getClass()
                .getMethod("getValue", new Class[0])
                .invoke(d, new Object[0])).intValue();
            int unit = ((Integer)d.getClass()
                .getMethod("getUnit", new Class[0])
                .invoke(d, new Object[0])).intValue();
            return new FormattedDistance(value, unit);
        } catch (Throwable t) {
            Log.w(TAG, "distance formatter failed: " + t);
            return new FormattedDistance(-1, 0);
        }
    }

    private long currentArrivalSeconds() {
        if (lastEtaSeconds >= 0L) return lastEtaSeconds;
        if (lastRemainingSeconds < 0L) return -1L;
        long now = getUtcMillis() / 1000L;
        long elapsed = lastRemainingSampleUtcSeconds >= 0L
            ? now - lastRemainingSampleUtcSeconds : 0L;
        if (elapsed < 0L) elapsed = 0L;
        long remaining = lastRemainingSeconds - elapsed;
        if (remaining < 0L) remaining = 0L;
        return now + remaining;
    }

    private static boolean isMetricDistanceUnits() {
        try {
            int unit = Distance.getSystemUnit();
            return unit == Distance.NONE || unit == Distance.METERS || unit == Distance.KM;
        } catch (Throwable t) { return true; }
    }

    private static int getHuNavigationTimeFormat() {
        try { return DateMetric.timeFormat == 11 ? 1 : 0; }
        catch (Throwable t) { return 0; }
    }

    private static long getUtcMillis() {
        try {
            IFrameworkAccess fw = CarPlayHook.getFrameworkAccess();
            if (fw != null) return fw.getUTCTime();
        } catch (Throwable t) {}
        return System.currentTimeMillis();
    }

    private static long convertUtcToLocalMs(long utcMs) {
        try {
            IFrameworkAccess fw = CarPlayHook.getFrameworkAccess();
            if (fw != null) return fw.convertUTCTimeToLocalTime(utcMs);
        } catch (Throwable t) {}
        return utcMs;
    }

    private static String limitUtf8(String s, int maxBytes) {
        if (s == null || maxBytes <= 0) return "";
        try {
            byte[] raw = s.getBytes("UTF-8");
            if (raw.length <= maxBytes) return s;
            int lo = 0, hi = s.length();
            while (lo < hi) {
                int mid = (lo + hi + 1) / 2;
                if (s.substring(0, mid).getBytes("UTF-8").length <= maxBytes) lo = mid;
                else hi = mid - 1;
            }
            return s.substring(0, lo);
        } catch (Throwable t) {
            return s.length() <= maxBytes ? s : s.substring(0, maxBytes);
        }
    }

    private static final class FormattedDistance {
        final int value, unit;
        FormattedDistance(int value, int unit) { this.value = value; this.unit = unit; }
    }

    private static final class SilentLogChannel extends LogChannel {
        public void log(int level, String pattern, Object a, Object b, Object c, Object d,
                        long l1, long l2, long l3, int flags, Throwable t) {}
        public void log(int level, int messageId, Object a, Object b, Object c, Object d,
                        long l1, long l2, long l3, int flags, Throwable t) {}
    }
}

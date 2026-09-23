/*
 * V3.3 OEM lower-bar bridge.
 *
 * Partial takeover only:
 *   FctID 19 CurrentPositionInfo      -> CarPlay only while a valid road exists
 *   FctID 21 DistanceToDestination   -> CarPlay only while a valid distance exists
 *   FctID 22 TimeToDestination       -> CarPlay only while a valid ETA exists
 *
 * Invalid/missing CarPlay data always fails open to the stock Audi producer.
 * FctID 45 MapScale is never written here.
 *
 * Java 1.2 compatible.
 */
package com.luka.carplay.routeguidance;

import com.luka.carplay.CarPlayHook;
import com.luka.carplay.framework.Log;
import de.audi.atip.base.IFrameworkAccess;
import de.audi.atip.interapp.combi.bap.navi.CombiBAPServiceNavi;
import de.audi.atip.log.LogChannel;
import de.audi.atip.metrics.DateMetric;
import de.audi.atip.metrics.Distance;
import de.audi.tghu.navi.app.Navigation;
import de.audi.tghu.navi.app.cluster.BAPDistanceFormatter;
import de.audi.tghu.navi.app.cluster.ClusterService;

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
        lastEtaSeconds = -1L;
        lastRemainingSeconds = -1L;
        lastRemainingSampleUtcSeconds = -1L;
        Log.i(TAG, "LOWER_BAR_SESSION=ACTIVE takeover=LAZY_PER_FIELD"
            + " stock_passthrough=19,21,22");
    }

    public void onStop() {
        /* Actual release is centralized in onShutdown(). */
    }

    public void onShutdown() {
        sessionActive = false;
        releaseAllFields("shutdown", true);
        lastEtaSeconds = -1L;
        lastRemainingSeconds = -1L;
        lastRemainingSampleUtcSeconds = -1L;
        Log.i(TAG, "LOWER_BAR_SESSION=INACTIVE synthetic_clear=NO"
            + " stock_listener_restore=BEST_EFFORT");
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
            appConnectorNavi.updateCurrentPositionInfo(road);
            Log.i(TAG, "OEM_FCT19 source=CARPLAY current_road=" + road);
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
            appConnectorNavi.updateDistanceToDestination(fd.value, fd.unit, false);
            Log.i(TAG, "OEM_FCT21 source=CARPLAY dist_m=" + meters
                + " bap_value=" + fd.value + " bap_unit=" + fd.unit);
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
            appConnectorNavi.updateTimeToDestination(1, timeFormat, localSeconds);
            Log.i(TAG, "OEM_FCT22 source=CARPLAY eta_utc=" + utcSeconds
                + " eta_local=" + localSeconds + " format=" + timeFormat);
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

        setFieldOwned(fct, false);
        syncGateBlocks();
        Log.i(TAG, "LOWER_BAR_FIELD=FCT" + fct
            + " action=RELEASE reason=" + reason
            + " stock_passthrough=YES synthetic_clear=NO");
        if (!anyFieldOwned()) restoreStockListenerIfOwned("no_owned_fields");
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
        if (restoreListener) restoreStockListenerIfOwned(reason);
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
                syncGateBlocks();
                return true;
            }

            if (current instanceof GatedCombiService) {
                gate = (GatedCombiService)current;
                syncGateBlocks();
                Log.w(TAG, "LOWER_BAR_GATE=ADOPTED existing_gate=YES");
                return true;
            }

            boolean replacingDetachedGate = gate != null;
            gate = new GatedCombiService(current);
            syncGateBlocks();
            cs.setCombiBAPListenerCombiService(gate);
            if (replacingDetachedGate)
                Log.w(TAG, "LOWER_BAR_GATE=REINSTALLED reason=cluster_listener_replaced");
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
        if (gate != null)
            gate.setBlockedFields(ownFct19, ownFct21, ownFct22);
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

/*
 * V3.3 OEM lower-bar bridge.
 *
 * Owns only:
 *   FctID 19 CurrentPositionInfo      -> current road
 *   FctID 21 DistanceToDestination   -> remaining distance
 *   FctID 22 TimeToDestination       -> absolute arrival time
 *
 * FctID 45 MapScale is deliberately never written here.  It remains the
 * vehicle's native OEM scale readout.  Touch, wheel zoom, Type111 rendering,
 * compass and all other navigation functions are outside this class.
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

    private CombiBAPServiceNavi appConnectorNavi;
    private GatedCombiService gate;
    private final BAPDistanceFormatter distanceFormatter =
        new BAPDistanceFormatter(new SilentLogChannel());

    private boolean initialized;
    private boolean ownershipRequested;
    private boolean ownershipActive;
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
            /* Install early with the gate open, so normal stock behavior is unchanged. */
            ensureGateInstalled();
            Log.i(TAG, "Initialized fields=19,21,22 mapScale=stock");
            return true;
        } catch (Throwable t) {
            Log.e(TAG, "Init failed", t);
            return false;
        }
    }

    public void onStart() {
        ownershipRequested = true;
        ownershipActive = false;
        if (ensureLowerBarOwnership()) {
            Log.i(TAG, "LOWER_BAR_OWNERSHIP=ACQUIRED fct=19,21,22 fct45=STOCK");
        } else {
            Log.w(TAG, "LOWER_BAR_OWNERSHIP=PENDING reason=gate_unavailable");
        }
    }

    public void onStop() {
        /* Actual release is centralized in onShutdown(). */
    }

    public void onShutdown() {
        /*
         * Clear V3.3-owned fields while the stock producer is still gated.
         * Only do this after ownership was actually acquired: clearing an
         * never-owned lower bar could overwrite valid OEM navigation data.
         */
        boolean hadOwnership = ownershipActive;
        boolean cleared = false;
        /*
         * Revalidate the live ClusterService listener before teardown.  The
         * HMI may replace its listener at runtime; clearing through a detached
         * gate would otherwise race a newly restored stock producer.
         */
        if (hadOwnership && ensureGateInstalled()) {
            gate.setLowerBarBlocked(true);
            clearLowerBar();
            cleared = true;
        }

        ownershipRequested = false;
        ownershipActive = false;
        if (gate != null) gate.setLowerBarBlocked(false);
        lastEtaSeconds = -1L;
        lastRemainingSeconds = -1L;
        lastRemainingSampleUtcSeconds = -1L;
        Log.i(TAG, "LOWER_BAR_OWNERSHIP=RELEASED stock_restored=YES"
            + " cleared=" + (cleared ? "YES" : "NO"));
    }

    public void update(RouteGuidance.State s) {
        if (!initialized || !ownershipRequested || s == null) return;
        if (!ensureLowerBarOwnership()) return;

        try {
            int dirty = s.dirtyMask;

            if ((dirty & RouteGuidance.State.DIRTY_CURRENT_ROAD) != 0) {
                String road = limitUtf8(s.currentRoad, 96);
                /*
                 * Empty is meaningful: unnamed roads must clear the previous
                 * Fct19 value rather than leaving stale text on the VC.
                 */
                appConnectorNavi.updateCurrentPositionInfo(road);
                Log.i(TAG, "OEM_FCT19 current_road="
                    + (road.length() == 0 ? "<empty>" : road));
            }

            if ((dirty & RouteGuidance.State.DIRTY_DIST_DEST) != 0) {
                sendDistanceToDestination(s.distDestM);
            }

            if ((dirty & RouteGuidance.State.DIRTY_ETA) != 0) {
                lastEtaSeconds = s.etaSeconds;
            }
            if ((dirty & RouteGuidance.State.DIRTY_TIME_REMAINING) != 0) {
                lastRemainingSeconds = s.timeRemainingSeconds;
                lastRemainingSampleUtcSeconds = getUtcMillis() / 1000L;
            }
            if ((dirty & (RouteGuidance.State.DIRTY_ETA
                        | RouteGuidance.State.DIRTY_TIME_REMAINING)) != 0) {
                sendArrivalTime();
            }

        } catch (Throwable t) {
            Log.e(TAG, "lower-bar update failed", t);
        }
    }

    private boolean ensureLowerBarOwnership() {
        if (!ownershipRequested) return false;
        /*
         * Do not trust a cached gate reference. ClusterService can replace its
         * listener during an HMI lifecycle transition; re-read the live
         * listener before every owned publication and wrap it again if needed.
         */
        if (!ensureGateInstalled()) {
            ownershipActive = false;
            return false;
        }
        gate.setLowerBarBlocked(true);
        ownershipActive = true;
        return true;
    }

    private boolean ensureGateInstalled() {
        try {
            Navigation nav = Navigation.getInstance();
            if (nav == null) return false;
            ClusterService cs = nav.getClusterService();
            if (cs == null) return false;

            CombiBAPServiceNavi current = cs.getCombiBAPListenerCombiService();
            if (current == null) return false;

            if (current instanceof GatedCombiService) {
                gate = (GatedCombiService)current;
            } else {
                boolean replacingDetachedGate = gate != null;
                gate = new GatedCombiService(current);
                cs.setCombiBAPListenerCombiService(gate);
                if (replacingDetachedGate) {
                    Log.w(TAG, "LOWER_BAR_GATE=REINSTALLED reason=cluster_listener_replaced");
                }
            }
            return true;
        } catch (Throwable t) {
            Log.w(TAG, "gate install failed: " + t);
            return false;
        }
    }

    private void sendDistanceToDestination(int meters) {
        if (meters <= 0) {
            sendDistanceToDestinationRaw(0, false);
            Log.i(TAG, "OEM_FCT21 dist_m=" + meters + " action=CLEAR");
            return;
        }
        FormattedDistance fd = formatDistanceToDestination(meters);
        if (fd.value < 0) return;
        appConnectorNavi.updateDistanceToDestination(fd.value, fd.unit, false);
        Log.i(TAG, "OEM_FCT21 dist_m=" + meters
            + " bap_value=" + fd.value + " bap_unit=" + fd.unit);
    }

    private void sendDistanceToDestinationRaw(int value, boolean stopover) {
        appConnectorNavi.updateDistanceToDestination(value, 0, stopover);
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

    private void sendArrivalTime() {
        long utcSeconds = currentArrivalSeconds();
        if (utcSeconds < 0L) {
            clearArrivalTime();
            return;
        }

        long localSeconds = convertUtcToLocalMs(utcSeconds * 1000L) / 1000L;
        int timeFormat = getHuNavigationTimeFormat();
        /* Type 1 is the AU491 absolute-arrival clock widget. */
        appConnectorNavi.updateTimeToDestination(1, timeFormat, localSeconds);
        Log.i(TAG, "OEM_FCT22 eta_utc=" + utcSeconds
            + " eta_local=" + localSeconds + " format=" + timeFormat);
    }

    private void clearArrivalTime() {
        appConnectorNavi.updateTimeToDestination(0, 0, -1L);
        Log.i(TAG, "OEM_FCT22 action=CLEAR");
    }

    private void clearLowerBar() {
        try {
            appConnectorNavi.updateCurrentPositionInfo("");
            sendDistanceToDestinationRaw(0, false);
            appConnectorNavi.updateTimeToDestination(0, 0, -1L);
            Log.i(TAG, "OEM_LOWER_BAR_CLEAR fct=19,21,22 result=OK");
        } catch (Throwable t) {
            Log.w(TAG, "OEM lower-bar clear failed: " + t);
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
        } catch (Throwable t) {
            return true;
        }
    }

    private static int getHuNavigationTimeFormat() {
        try {
            return DateMetric.timeFormat == 11 ? 1 : 0;
        } catch (Throwable t) {
            return 0;
        }
    }

    private static long getUtcMillis() {
        try {
            IFrameworkAccess fw = CarPlayHook.getFrameworkAccess();
            if (fw != null) return fw.getUTCTime();
        } catch (Throwable t) {
            /* fall through */
        }
        return System.currentTimeMillis();
    }

    private static long convertUtcToLocalMs(long utcMs) {
        try {
            IFrameworkAccess fw = CarPlayHook.getFrameworkAccess();
            if (fw != null) return fw.convertUTCTimeToLocalTime(utcMs);
        } catch (Throwable t) {
            /* fall through */
        }
        return utcMs;
    }

    private static String limitUtf8(String s, int maxBytes) {
        if (s == null || maxBytes <= 0) return "";
        try {
            byte[] raw = s.getBytes("UTF-8");
            if (raw.length <= maxBytes) return s;
            int lo = 0;
            int hi = s.length();
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
        final int value;
        final int unit;
        FormattedDistance(int value, int unit) {
            this.value = value;
            this.unit = unit;
        }
    }

    private static final class SilentLogChannel extends LogChannel {
        public void log(int level, String pattern,
                        Object a, Object b, Object c, Object d,
                        long l1, long l2, long l3, int flags, Throwable t) {
        }
        public void log(int level, int messageId,
                        Object a, Object b, Object c, Object d,
                        long l1, long l2, long l3, int flags, Throwable t) {
        }
    }
}

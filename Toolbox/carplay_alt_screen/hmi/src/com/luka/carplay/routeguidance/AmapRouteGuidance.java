/*
 * V3.3 Amap lower-bar lifecycle compatibility.
 * Java 1.2 compatible.
 */
package com.luka.carplay.routeguidance;

import com.luka.carplay.framework.CarplayBus;
import com.luka.carplay.framework.Log;

public final class AmapRouteGuidance extends RouteGuidance {
    private static final String TAG = "AmapRouteGuidanceV33";
    private static final long SOFT_INACTIVE_GRACE_MS = 5000L;

    private int rawRouteState = -1;
    private int rawManeuverCount = 0;
    private int rawVisibleInApp = -1;
    private int rawSourceSupportsRg = -1;
    private int rawDistDestM = -1;
    private int rawEtaSeconds = -1;
    private long rawTimeRemainingSeconds = -1L;
    private String rawCurrentRoad;
    private String sourceName;

    private boolean activeRouteSeen;
    private boolean softExpired;
    private boolean softTimerRunning;
    private long softDeadlineMs;
    private int softGeneration;

    public synchronized void start() {
        resetCompatState();
        super.start();
    }

    public synchronized void stop() {
        resetCompatState();
        super.stop();
    }

    public synchronized void onFrame(int type, int flags, byte[] payload, int len) {
        if (type != CarplayBus.EVT_RGD_UPDATE || payload == null || len <= 0) {
            super.onFrame(type, flags, payload, len);
            return;
        }

        CarplayBus.Data d = CarplayBus.parseText(payload, len);
        if (d == null) {
            super.onFrame(type, flags, payload, len);
            return;
        }

        if (d.has("source_name")) {
            String v = d.str("source_name", null);
            if (v != null && v.trim().length() > 0) sourceName = v.trim();
        }

        boolean guidanceChanged = updateRawState(d);
        boolean hardClear = rawRouteState == 0
            || rawSourceSupportsRg == 0
            || (d.has("disconnect_reason")
                && d.str("disconnect_reason", null) != null);

        if (hardClear) {
            cancelSoftTimer();
            activeRouteSeen = false;
            softExpired = false;
            super.onFrame(type, flags, payload, len);
            return;
        }

        if (rawRouteState > 1 || rawManeuverCount > 0 || rawVisibleInApp == 1
                || (rawRouteState == 1 && rawVisibleInApp < 0
                    && rawSourceSupportsRg != 0)) {
            activeRouteSeen = true;
        }

        if (sourceName != null && sourceName.length() > 0
                && !isAmapSourceName(sourceName)) {
            cancelSoftTimer();
            softExpired = false;
            super.onFrame(type, flags, payload, len);
            return;
        }

        boolean softInactive = isAmapSourceName(sourceName)
            && activeRouteSeen
            && rawRouteState == 1
            && rawManeuverCount == 0
            && rawVisibleInApp == 0
            && rawSourceSupportsRg != 0;

        if (!softInactive) {
            cancelSoftTimer();
            softExpired = false;
            super.onFrame(type, flags, payload, len);
            return;
        }

        long now = System.currentTimeMillis();
        if (softExpired) {
            if (!guidanceChanged) {
                Log.d(TAG, "drop unchanged Amap soft-inactive frame after grace expiry");
                return;
            }
            softExpired = false;
            Log.i(TAG, "Amap guidance changed after soft-inactive expiry; re-arm grace");
        }

        if (!softTimerRunning) {
            softDeadlineMs = now + SOFT_INACTIVE_GRACE_MS;
            ensureSoftTimer();
            Log.i(TAG, "Amap soft-inactive grace started");
        } else if (guidanceChanged) {
            softDeadlineMs = now + SOFT_INACTIVE_GRACE_MS;
            Log.d(TAG, "Amap soft-inactive grace extended by fresh guidance");
        }

        super.onFrame(type, flags, payload, len);
    }

    private boolean updateRawState(CarplayBus.Data d) {
        boolean changed = false;
        if (d.has("route_state")) rawRouteState = d.num("route_state", -1);
        if (d.has("maneuver_count")) rawManeuverCount = d.num("maneuver_count", 0);
        if (d.has("visible_in_app")) {
            int v = d.num("visible_in_app", -1);
            rawVisibleInApp = (v == 0 || v == 1) ? v : -1;
        }
        if (d.has("source_supports_rg"))
            rawSourceSupportsRg = d.num("source_supports_rg", -1);

        if (d.has("dist_dest_m")) {
            int v = d.num("dist_dest_m", -1);
            if (v != rawDistDestM) changed = true;
            rawDistDestM = v;
        }
        if (d.has("eta_seconds")) {
            int v = d.num("eta_seconds", -1);
            if (v != rawEtaSeconds) changed = true;
            rawEtaSeconds = v;
        }
        if (d.has("time_remaining_seconds")) {
            long v = d.num64("time_remaining_seconds", -1L);
            if (v != rawTimeRemainingSeconds) changed = true;
            rawTimeRemainingSeconds = v;
        }
        if (d.has("current_road")) {
            String v = d.str("current_road", "");
            if (!strEq(rawCurrentRoad, v)) changed = true;
            rawCurrentRoad = v;
        }
        if (rawRouteState > 1 || rawManeuverCount > 0 || rawVisibleInApp == 1)
            changed = true;
        return changed;
    }

    private void ensureSoftTimer() {
        if (softTimerRunning) return;
        softTimerRunning = true;
        final int generation = ++softGeneration;
        Thread t = new Thread(new Runnable() {
            public void run() { runSoftTimer(generation); }
        }, "AmapSoftInactiveV33");
        t.setDaemon(true);
        t.start();
    }

    private void runSoftTimer(int generation) {
        while (true) {
            long sleep;
            synchronized (this) {
                if (!softTimerRunning || generation != softGeneration) return;
                sleep = softDeadlineMs - System.currentTimeMillis();
                if (sleep <= 0L) {
                    softTimerRunning = false;
                    softExpired = true;
                    Log.i(TAG, "Amap soft-inactive grace expired; release OEM lower bar");
                    expireCompatibilitySoftInactive("amap_soft_inactive_timeout");
                    return;
                }
            }
            try { Thread.sleep(sleep); }
            catch (InterruptedException e) { return; }
        }
    }

    private void cancelSoftTimer() {
        if (softTimerRunning) softGeneration++;
        softTimerRunning = false;
        softDeadlineMs = 0L;
    }

    private void resetCompatState() {
        cancelSoftTimer();
        rawRouteState = -1;
        rawManeuverCount = 0;
        rawVisibleInApp = -1;
        rawSourceSupportsRg = -1;
        rawDistDestM = -1;
        rawEtaSeconds = -1;
        rawTimeRemainingSeconds = -1L;
        rawCurrentRoad = null;
        sourceName = null;
        activeRouteSeen = false;
        softExpired = false;
    }

    private static boolean isAmapSourceName(String value) {
        if (value == null) return false;
        String text = value.trim();
        if (text.length() == 0) return false;
        String lower = text.toLowerCase();
        return text.indexOf("高德") >= 0
            || lower.indexOf("amap") >= 0
            || lower.indexOf("gaode") >= 0;
    }

    private static boolean strEq(String a, String b) {
        return a == null ? b == null : a.equals(b);
    }
}

/*
 * V3.3 CarPlay route-guidance metadata controller.
 *
 * Deliberately narrow: this class consumes the existing RGI bus only for the
 * OEM Virtual Cockpit lower navigation bar.  Maneuver rendering, lane guidance
 * and custom RGI video are intentionally out of scope for V3.3.
 *
 * Java 1.2 compatible.
 */
package com.luka.carplay.routeguidance;

import com.luka.carplay.framework.CarplayBus;
import com.luka.carplay.framework.Log;

public class RouteGuidance implements CarplayBus.Listener {
    private static final String TAG = "RouteGuidanceV33";

    private static final int ROUTE_STATE_NO_ROUTE_SET = 0;
    private static final int ROUTE_STATE_ROUTE_SET = 1;

    private BAPBridge bap;
    private volatile boolean running;
    private boolean rgActive;
    private State state = new State();

    public static class State {
        /* Keep the historical bit numbers for the fields V3.3 still consumes. */
        public static final int DIRTY_ROUTE_STATE = 1 << 0;
        public static final int DIRTY_DIST_DEST = 1 << 4;
        public static final int DIRTY_ETA = 1 << 10;
        public static final int DIRTY_TIME_REMAINING = 1 << 11;
        public static final int DIRTY_CURRENT_ROAD = 1 << 12;
        public static final int DIRTY_DISCONNECT = 1 << 14;
        public static final int DIRTY_VISIBLE_IN_APP = 1 << 17;
        public static final int DIRTY_SOURCE_SUPPORTS_RG = 1 << 20;

        public int dirtyMask;
        public int routeState;
        public int visibleInApp;
        public int sourceSupportsRg;
        public int distDestM;
        public int etaSeconds;
        public long timeRemainingSeconds;
        public String currentRoad;
        public String disconnectReason;

        public State() { reset(); }

        public void reset() {
            dirtyMask = 0;
            routeState = -1;
            visibleInApp = -1;
            sourceSupportsRg = -1;
            distDestM = -1;
            etaSeconds = -1;
            timeRemainingSeconds = -1L;
            currentRoad = null;
            disconnectReason = null;
        }

        public void clearDirty() { dirtyMask = 0; }
        public void markDirty(int flag) { dirtyMask |= flag; }

        public boolean hasUsefulLowerBarData() {
            return (currentRoad != null && currentRoad.length() > 0)
                || distDestM > 0 || etaSeconds >= 0 || timeRemainingSeconds >= 0L;
        }
    }

    public boolean init(Object naviService) {
        bap = new BAPBridge();
        if (!bap.init(naviService)) {
            Log.e(TAG, "BAPBridge init failed");
            bap = null;
            return false;
        }
        Log.i(TAG, "Initialized OEM lower-bar bridge");
        return true;
    }

    public void start() {
        if (running) return;
        running = true;
        rgActive = false;
        state.reset();

        CarplayBus bus = CarplayBus.getInstance();
        bus.on(CarplayBus.EVT_RGD_UPDATE, this);
        bus.start();
        Log.i(TAG, "Started; waiting for CarPlay RGI metadata");
    }

    public void stop() {
        if (!running) return;
        running = false;
        CarplayBus.getInstance().off(CarplayBus.EVT_RGD_UPDATE);
        if (bap != null) {
            bap.onStop();
            bap.onShutdown();
        }
        rgActive = false;
        state.reset();
        Log.i(TAG, "Stopped; OEM lower-bar ownership released");
    }

    public boolean isRunning() { return running; }

    public void onFrame(int type, int flags, byte[] payload, int len) {
        if (!running || type != CarplayBus.EVT_RGD_UPDATE) return;

        CarplayBus.Data data = CarplayBus.parseText(payload, len);
        if (data == null) return;
        parse(data);
        if (state.dirtyMask == 0) return;

        if (state.disconnectReason != null) {
            deactivate("disconnect=" + state.disconnectReason);
            state.reset();
            return;
        }

        int activationMask = State.DIRTY_ROUTE_STATE
            | State.DIRTY_VISIBLE_IN_APP
            | State.DIRTY_SOURCE_SUPPORTS_RG;

        if ((state.dirtyMask & activationMask) != 0 || !rgActive) {
            boolean wantActive;
            if (state.visibleInApp >= 0) {
                wantActive = state.visibleInApp != 0;
            } else if (state.routeState >= 0) {
                wantActive = state.routeState >= ROUTE_STATE_ROUTE_SET;
            } else {
                /* Sticky RGI replay can deliver useful fields before authority. */
                wantActive = state.hasUsefulLowerBarData();
            }

            if (state.sourceSupportsRg == 0) wantActive = false;
            /* Current native RGI transport debounces transient route_state=0. */
            if (state.routeState == ROUTE_STATE_NO_ROUTE_SET) wantActive = false;

            if (wantActive && !rgActive) {
                if (bap != null) bap.onStart();
                rgActive = true;
                Log.i(TAG, "OEM lower bar active route_state=" + state.routeState
                    + " visible=" + state.visibleInApp
                    + " source_rg=" + state.sourceSupportsRg);
            } else if (!wantActive && rgActive) {
                deactivate("authority");
            }
        }

        if (rgActive && bap != null) bap.update(state);
        state.clearDirty();
    }

    private void deactivate(String reason) {
        if (bap != null) {
            bap.onStop();
            bap.onShutdown();
        }
        rgActive = false;
        Log.i(TAG, "OEM lower bar inactive reason=" + reason);
    }

    private void parse(CarplayBus.Data d) {
        state.clearDirty();

        if (d.has("disconnect_reason")) {
            String v = d.str("disconnect_reason");
            if (!strEq(state.disconnectReason, v)) {
                state.disconnectReason = v;
                state.markDirty(State.DIRTY_DISCONNECT);
            }
        } else if (state.disconnectReason != null && d.size() > 0) {
            state.disconnectReason = null;
            state.markDirty(State.DIRTY_DISCONNECT);
        }

        if (d.has("source_supports_rg")) {
            int v = d.num("source_supports_rg", -1);
            if (v != state.sourceSupportsRg) {
                state.sourceSupportsRg = v;
                state.markDirty(State.DIRTY_SOURCE_SUPPORTS_RG);
            }
        }

        if (d.has("visible_in_app")) {
            int raw = d.num("visible_in_app", -1);
            int v = (raw == 0 || raw == 1) ? raw : -1;
            if (v != state.visibleInApp) {
                state.visibleInApp = v;
                state.markDirty(State.DIRTY_VISIBLE_IN_APP);
            }
        }

        if (d.has("route_state")) {
            int v = d.num("route_state", -1);
            if (v != state.routeState) {
                state.routeState = v;
                state.markDirty(State.DIRTY_ROUTE_STATE);
            }
        }

        if (d.has("dist_dest_m")) {
            int v = d.num("dist_dest_m", -1);
            if (v != state.distDestM) {
                state.distDestM = v;
                state.markDirty(State.DIRTY_DIST_DEST);
            }
        }

        if (d.has("eta_seconds")) {
            int v = d.num("eta_seconds", -1);
            if (v != state.etaSeconds) {
                state.etaSeconds = v;
                state.markDirty(State.DIRTY_ETA);
            }
        }

        if (d.has("time_remaining_seconds")) {
            long v = d.num64("time_remaining_seconds", -1L);
            if (v != state.timeRemainingSeconds) {
                state.timeRemainingSeconds = v;
                state.markDirty(State.DIRTY_TIME_REMAINING);
            }
        }

        if (d.has("current_road")) {
            String v = d.str("current_road", "");
            if (!strEq(state.currentRoad, v)) {
                state.currentRoad = v;
                state.markDirty(State.DIRTY_CURRENT_ROAD);
            }
        }
    }

    private static boolean strEq(String a, String b) {
        return a == null ? b == null : a.equals(b);
    }
}

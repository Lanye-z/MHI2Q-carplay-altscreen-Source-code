/*
 * V3.1 CarPlay cluster wheel-zoom bridge.
 *
 * The Audi stock magnification path remains authoritative.  The OEM navigation
 * stack carries signed "steps" into a delayed zoom handler instead of replaying
 * every wheel detent as an immediate renderer command.  Mirror that model here:
 * publish one signed-step intent per magnification callback and let the native
 * private111 control plane accumulate, cancel and pace those intents before
 * emitting CarPlay changeMapZoomLevel commands.
 *
 * No local UV/destination scaling is performed here.
 *
 * Java 1.2 compatible: no generics, enums, autoboxing or NIO.
 */
package com.luka.carplay.cluster;

import com.luka.carplay.framework.Log;

import java.io.File;
import java.io.FileOutputStream;

public final class WheelZoomBridge {
    private static final String TAG = "WheelZoom";
    private static final String EVENT_FILE = "/tmp/mmi-mirror-wheel-zoom.events";
    private static final String LOG_FILE = "/tmp/mmi-mirror-wheel-zoom.log";
    private static final long MAX_EVENT_BYTES = 262144L;
    private static final long MAX_LOG_BYTES = 262144L;
    private static final int MAX_STEPS_PER_CALLBACK = 16;

    private static boolean haveMagnification;
    private static int lastMagnification;
    private static int sequence;
    private static int eventEpoch = initialEpoch();
    private static boolean epochQueuePrepared;

    private WheelZoomBridge() {}

    public static synchronized void onMagnificationChanged(int magnification) {
        prepareEpochQueue();
        if (!haveMagnification) {
            haveMagnification = true;
            lastMagnification = magnification;
            diag("WHEEL_ZOOM_INPUT seed=1 magnification=" + magnification
                + " action=NONE");
            return;
        }

        int delta = magnification - lastMagnification;
        lastMagnification = magnification;
        if (delta == 0) return;

        if (!ClusterStateController.isClusterOwned()) {
            diag("WHEEL_ZOOM_INPUT magnification=" + magnification
                + " delta=" + delta
                + " action=IGNORED reason=cluster_not_owned");
            return;
        }

        int steps = delta < 0 ? -delta : delta;
        if (steps > MAX_STEPS_PER_CALLBACK) {
            diag("WHEEL_ZOOM_INPUT magnification=" + magnification
                + " delta=" + delta
                + " action=IGNORED reason=delta_outlier max_steps="
                + MAX_STEPS_PER_CALLBACK);
            return;
        }

        int direction = delta < 0 ? 0 : 1;
        String action = direction == 0 ? "ZOOM_IN" : "ZOOM_OUT";

        /*
         * OEM-style step intent: one callback becomes one queue record even
         * when the stock magnification jumps by multiple steps.  V3 expanded
         * delta=+N into N adjacent records, which the 100 ms native poll could
         * flush within 1-2 ms and overload slower CarPlay map renderers.
         */
        if (sequence == Integer.MAX_VALUE) {
            sequence = 0;
            eventEpoch = eventEpoch == Integer.MAX_VALUE ? 1 : eventEpoch + 1;
            try { new File(EVENT_FILE).delete(); } catch (Throwable ignored) {}
            diag("WHEEL_ZOOM_EPOCH reason=sequence_wrap epoch=" + eventEpoch
                + " queue=reset");
        }
        ++sequence;
        boolean ok = appendEvent(
            sequence, direction, magnification, delta, steps);
        diag("WHEEL_ZOOM_INPUT magnification=" + magnification
            + " delta=" + delta
            + " action=" + action
            + " direction=" + direction
            + " seq=" + sequence
            + " steps=" + steps
            + " model=OEM_STEPS_V1"
            + " publish=" + (ok ? "queued" : "dropped"));
    }

    public static synchronized void reset() {
        haveMagnification = false;
        lastMagnification = 0;
        try { new File(EVENT_FILE).delete(); } catch (Throwable ignored) {}
        diag("WHEEL_ZOOM_RESET queue=cleared epoch=" + eventEpoch
            + " sequence_preserved=" + sequence);
    }

    private static int initialEpoch() {
        int value = (int)(System.currentTimeMillis() & 0x7fffffffL);
        return value == 0 ? 1 : value;
    }

    private static void prepareEpochQueue() {
        if (epochQueuePrepared) return;
        try { new File(EVENT_FILE).delete(); } catch (Throwable ignored) {}
        epochQueuePrepared = true;
        diag("WHEEL_ZOOM_EPOCH reason=java_process_start epoch=" + eventEpoch
            + " queue=reset");
    }

    private static boolean appendEvent(int seq, int direction,
                                       int magnification, int delta,
                                       int steps) {
        FileOutputStream out = null;
        try {
            File f = new File(EVENT_FILE);
            if (f.exists() && f.length() > MAX_EVENT_BYTES) {
                diag("WHEEL_ZOOM_QUEUE result=dropped reason=queue_size_limit"
                    + " bytes=" + f.length() + " seq=" + seq);
                return false;
            }
            String line = "epoch=" + eventEpoch
                + " seq=" + seq
                + " direction=" + direction
                + " magnification=" + magnification
                + " delta=" + delta
                + " step=0"
                + " steps=" + steps
                + " model=OEM_STEPS_V1"
                + " commit=" + seq + "\n";
            out = new FileOutputStream(EVENT_FILE, true);
            out.write(line.getBytes("UTF-8"));
            out.flush();
            out.close();
            out = null;
            return true;
        } catch (Throwable t) {
            try { if (out != null) out.close(); } catch (Throwable ignored) {}
            diag("WHEEL_ZOOM_QUEUE result=dropped reason=write_failed error=" + t);
            return false;
        }
    }

    private static void diag(String message) {
        try { Log.i(TAG, message); } catch (Throwable ignored) {}
        FileOutputStream out = null;
        try {
            File f = new File(LOG_FILE);
            if (f.exists() && f.length() > MAX_LOG_BYTES) {
                FileOutputStream reset = new FileOutputStream(f, false);
                reset.write(("--- wheel log reset at "
                    + System.currentTimeMillis() + " ---\n").getBytes("UTF-8"));
                reset.close();
            }
            out = new FileOutputStream(f, true);
            String line = System.currentTimeMillis() + " " + message + "\n";
            out.write(line.getBytes("UTF-8"));
            out.flush();
            out.close();
            out = null;
        } catch (Throwable t) {
            try { if (out != null) out.close(); } catch (Throwable ignored) {}
        }
    }
}

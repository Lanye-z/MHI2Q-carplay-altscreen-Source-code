/*
 * V3.1 CarPlay cluster wheel-zoom bridge.
 *
 * The Audi stock magnification path remains authoritative.  The OEM navigation
 * stack carries signed "steps" into a delayed zoom handler instead of replaying
 * every wheel detent as an immediate renderer command.  Mirror that model here:
 * publish one signed-step intent per magnification callback and let the native
 * private111 control plane retarget and pace those intents before emitting
 * CarPlay changeMapZoomLevel commands. Native bounds only the outstanding
 * target error; completed movement is rebased so long sessions never hit a
 * cumulative artificial zoom ceiling.
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

    /* Diagnostics-only counters. Never used for gating or wheel behavior. */
    private static int callbackCount;
    private static int seedCount;
    private static int queuedCount;
    private static int ignoredNotOwnedCount;

    private WheelZoomBridge() {}

    public static synchronized void onMagnificationChanged(int magnification) {
        ++callbackCount;
        /*
         * Raw callback marker: this is the first business action after the
         * proven ClusterService callback enters WheelZoomBridge. It is emitted
         * before queue preparation, seed handling, ownership checks, delta
         * filtering or any native scheduling decision.
         */
        diag("WHEEL_CALLBACK_RAW magnification=" + magnification
            + " callback_count=" + callbackCount
            + " have_magnification=" + (haveMagnification ? "1" : "0")
            + " last_magnification=" + lastMagnification
            + " sequence=" + sequence
            + " epoch=" + eventEpoch);
        prepareEpochQueue();
        if (!haveMagnification) {
            ++seedCount;
            haveMagnification = true;
            lastMagnification = magnification;
            diag("WHEEL_ZOOM_INPUT seed=1 magnification=" + magnification
                + " action=NONE" + counterSummary());
            return;
        }

        int delta = magnification - lastMagnification;
        lastMagnification = magnification;
        if (delta == 0) return;

        if (!ClusterStateController.isClusterOwned()) {
            ++ignoredNotOwnedCount;
            diag("WHEEL_ZOOM_INPUT magnification=" + magnification
                + " delta=" + delta
                + " action=IGNORED reason=cluster_not_owned"
                + counterSummary());
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
         * delta=+N into N adjacent records, which the old native drain could
         * flush too aggressively and overload slower CarPlay map renderers.
         *
         * Keep the append-only queue bounded for long CarPlay sessions.  A
         * size rotation advances the epoch and starts a new file so the native
         * reader can discard the retired history without permanently dropping
         * all future wheel input once 256 KiB is reached.
         */
        if (!rotateEventQueueIfNeeded()) {
            diag("WHEEL_ZOOM_INPUT magnification=" + magnification
                + " delta=" + delta
                + " action=IGNORED reason=queue_rotate_failed");
            return;
        }
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
        if (ok) ++queuedCount;
        diag("WHEEL_ZOOM_INPUT magnification=" + magnification
            + " delta=" + delta
            + " action=" + action
            + " direction=" + direction
            + " seq=" + sequence
            + " steps=" + steps
            + " model=OEM_STEPS_V1"
            + " publish=" + (ok ? "queued" : "dropped")
            + counterSummary());
    }

    /*
     * Session-transition observability only. This method intentionally does
     * not seed, reset, arm, re-arm, delete queues, change ownership, or touch
     * any native target-follow state.
     */
    public static synchronized void logCarPlayLifecycle(boolean active) {
        diag("WHEEL_LIFECYCLE carplay_session=" + (active ? "1" : "0")
            + " action=OBSERVE_ONLY"
            + " have_magnification=" + (haveMagnification ? "1" : "0")
            + " last_magnification=" + lastMagnification
            + " sequence=" + sequence
            + " epoch=" + eventEpoch
            + counterSummary());
    }

    private static String counterSummary() {
        return " callback_count=" + callbackCount
            + " seed_count=" + seedCount
            + " queued_count=" + queuedCount
            + " ignored_not_owned=" + ignoredNotOwnedCount;
    }

    public static synchronized void reset() {
        haveMagnification = false;
        lastMagnification = 0;
        try { new File(EVENT_FILE).delete(); } catch (Throwable ignored) {}
        diag("WHEEL_ZOOM_RESET queue=cleared epoch=" + eventEpoch
            + " sequence_preserved=" + sequence
            + counterSummary());
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

    private static boolean rotateEventQueueIfNeeded() {
        try {
            File f = new File(EVENT_FILE);
            if (!f.exists() || f.length() <= MAX_EVENT_BYTES) return true;

            int nextEpoch =
                eventEpoch == Integer.MAX_VALUE ? 1 : eventEpoch + 1;
            if (!f.delete()) {
                diag("WHEEL_ZOOM_QUEUE result=dropped"
                    + " reason=queue_size_rotate_delete_failed"
                    + " bytes=" + f.length()
                    + " epoch=" + eventEpoch);
                return false;
            }

            eventEpoch = nextEpoch;
            sequence = 0;
            diag("WHEEL_ZOOM_EPOCH reason=queue_size_rotate"
                + " epoch=" + eventEpoch
                + " queue=reset");
            return true;
        } catch (Throwable t) {
            diag("WHEEL_ZOOM_QUEUE result=dropped"
                + " reason=queue_size_rotate_failed error=" + t);
            return false;
        }
    }

    private static boolean appendEvent(int seq, int direction,
                                       int magnification, int delta,
                                       int steps) {
        FileOutputStream out = null;
        try {
            File f = new File(EVENT_FILE);
            if (f.exists() && f.length() > MAX_EVENT_BYTES) {
                diag("WHEEL_ZOOM_QUEUE result=dropped"
                    + " reason=queue_size_race"
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

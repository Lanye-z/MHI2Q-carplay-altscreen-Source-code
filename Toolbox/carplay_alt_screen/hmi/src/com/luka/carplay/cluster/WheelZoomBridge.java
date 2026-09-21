/*
 * V3 true CarPlay cluster wheel-zoom bridge.
 *
 * The Audi stock magnification path remains authoritative. This observer only
 * mirrors signed magnification deltas into an append-only event queue consumed
 * by the native private111 control plane. No local UV/destination scaling is
 * performed here.
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
    private static final int MAX_STEPS_PER_CALLBACK = 16;

    private static boolean haveMagnification;
    private static int lastMagnification;
    private static int sequence;

    private WheelZoomBridge() {}

    public static synchronized void onMagnificationChanged(int magnification) {
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
        int i;
        for (i = 1; i <= steps; ++i) {
            if (sequence == Integer.MAX_VALUE) sequence = 0;
            ++sequence;
            boolean ok = appendEvent(
                sequence, direction, magnification, delta, i, steps);
            diag("WHEEL_ZOOM_INPUT magnification=" + magnification
                + " delta=" + delta
                + " action=" + action
                + " direction=" + direction
                + " seq=" + sequence
                + " step=" + i + "/" + steps
                + " publish=" + (ok ? "queued" : "dropped"));
        }
    }

    public static synchronized void reset() {
        haveMagnification = false;
        lastMagnification = 0;
        try { new File(EVENT_FILE).delete(); } catch (Throwable ignored) {}
        diag("WHEEL_ZOOM_RESET queue=cleared sequence_preserved=" + sequence);
    }

    private static boolean appendEvent(int seq, int direction,
                                       int magnification, int delta,
                                       int step, int steps) {
        FileOutputStream out = null;
        try {
            File f = new File(EVENT_FILE);
            if (f.exists() && f.length() > MAX_EVENT_BYTES) {
                diag("WHEEL_ZOOM_QUEUE result=dropped reason=queue_size_limit"
                    + " bytes=" + f.length() + " seq=" + seq);
                return false;
            }
            String line = "seq=" + seq
                + " direction=" + direction
                + " magnification=" + magnification
                + " delta=" + delta
                + " step=" + step
                + " steps=" + steps
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
            out = new FileOutputStream(LOG_FILE, true);
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

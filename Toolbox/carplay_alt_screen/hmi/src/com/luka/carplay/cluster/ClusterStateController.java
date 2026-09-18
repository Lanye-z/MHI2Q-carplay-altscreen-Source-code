/*
 * Context80 readback controller for the CarPlay Type111 experiment.
 *
 * Vehicle contract:
 *   - Java is the sole terminal1 context writer.
 *   - ctx80={98,101,102,3}.
 *   - BaseVideo demand is active+destination-ready.
 *   - every ctx80 acquisition is confirmed by getCurrentContextID(1)
 *     before compositeApplied becomes true.
 *
 * Platform/HMI calls are deliberately made through reflection so this one
 * class can be rebuilt without vendoring the proprietary lsd.jar. The public
 * ABI remains compatible with the existing unified carplay_hook.jar.
 */
package com.luka.carplay.cluster;

import de.audi.atip.base.IFrameworkAccess;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

public final class ClusterStateController {
    public static final int TERMINAL_CLUSTER = 1;
    public static final int CTX_STOCK = 74;
    public static final int CTX_BOUNCE = 72;
    public static final int CTX_COMPOSITE = 80;

    /* Compatibility seams used by newer geometry-aware unified JARs. */
    public static final int VIEWAREA_FULLSCREEN = 0;
    public static final int VIEWAREA_SMALLSCREEN = 1;

    private static final long POLL_MS = 100L;
    private static final long RECONCILE_MS = 250L;
    private static final long BOUNCE_MS = 180L;
    private static final long VERIFY_STEP_MS = 50L;
    private static final int VERIFY_ATTEMPTS = 7;
    private static final long CIRCUIT_BREAKER_MS = 2000L;
    private static final int CONTEXT_FAILURE_LIMIT = 3;
    private static final long DIAG_MAX_BYTES = 131072L;

    private static final String HMI_STATE_FILE = "/tmp/mmi-mirror-hmi.state";
    private static final String BASEVIDEO_ACTIVE_FILE = "/tmp/mmi-mirror-active";
    private static final String BASEVIDEO_READY_FILE = "/tmp/mmi-mirror-basevideo.ready";
    private static final String CONTEXT_MODE_FILE = "/tmp/mmi-mirror-context.mode";
    private static final String STARTED_FILE = "/tmp/mmi-mirror-controller.started";
    private static final String DIAG_FILE = "/tmp/mmi-mirror-controller.log";
    private static final String MODE_JAVA80 = "JAVA80";

    private static final Object LOCK = new Object();
    private static final Object DIAG_LOCK = new Object();

    private static volatile IFrameworkAccess frameworkAccess;
    private static volatile Thread worker;
    private static volatile Thread contextWriterThread;
    private static volatile boolean ownershipIntent;
    private static volatile boolean compositeApplied;
    private static volatile boolean carPlaySessionActive;
    private static volatile boolean rgiPresentationActive;
    private static volatile boolean smallScreenViewArea;

    private static String lastStateSignature = "";
    private static String lastContextMode = "";
    private static String lastObserverStatus = "";
    private static long lastReconcileMs;
    private static int contextWriteFailures;
    private static long circuitOpenUntilMs;
    private static int navViewSizeChoiceId = Integer.MIN_VALUE;
    private static boolean navViewSizeChoiceResolved;
    private static boolean geometryClassMissing;

    private ClusterStateController() {}

    public static void start(IFrameworkAccess fw) {
        if (fw != null) frameworkAccess = fw;
        synchronized (LOCK) {
            if (worker != null && worker.isAlive()) {
                LOCK.notifyAll();
                return;
            }
            try {
                writeStartedMarker();
                diag("controller start requested; frameworkAccess="
                    + (frameworkAccess != null ? "ok" : "null")
                    + " ctx_readback=getCurrentContextID(1)");
                Thread t = new Thread(new Runnable() {
                    public void run() { runLoop(); }
                }, "cluster-state-controller");
                t.setDaemon(true);
                t.start();
                worker = t;
            } catch (Throwable t) {
                diag("ERROR worker start failed: " + describe(t));
            }
        }
    }

    public static void setCarPlaySessionActive(boolean active) {
        if (carPlaySessionActive == active) return;
        carPlaySessionActive = active;
        lastStateSignature = "";
        diag("carplay_session=" + (active ? "1" : "0"));
    }

    public static void setRgiPresentationActive(boolean active) {
        if (rgiPresentationActive == active) return;
        rgiPresentationActive = active;
        lastStateSignature = "";
        diag("rgi_active=" + (active ? "1" : "0"));
    }

    public static boolean isRgiPresentationActive() {
        return rgiPresentationActive;
    }

    public static boolean isClusterOwned() {
        return ownershipIntent;
    }

    public static boolean isContextWriterThread() {
        return Thread.currentThread() == contextWriterThread;
    }

    /* Kept for older DisplayManager guards. Absent/unknown mode defaults JAVA80. */
    public static boolean isCompositeModeRequested() {
        return MODE_JAVA80.equals(readContextMode());
    }

    public static boolean isSmallScreenViewArea() {
        return smallScreenViewArea;
    }

    public static void setViewAreaMode(int mode) {
        boolean small = mode == VIEWAREA_SMALLSCREEN;
        if (smallScreenViewArea == small) return;
        smallScreenViewArea = small;
        geometryReapply("view-area-change");
    }

    private static void runLoop() {
        contextWriterThread = Thread.currentThread();
        diag("worker running; writerThread=" + contextWriterThread.getName());
        while (true) {
            try {
                pollHmiState();
                pollContextPolicy();
            } catch (Throwable t) {
                diag("ERROR poll failed: " + describe(t));
            }
            sleep(POLL_MS);
        }
    }

    private static void pollHmiState() {
        Object fw = frameworkAccess;
        if (fw == null) {
            observerStatus("frameworkAccess=null");
            return;
        }

        Object hmi;
        try {
            hmi = invokeNoArg(fw, "getHMIService");
        } catch (Throwable t) {
            observerStatus("getHMIService failed: " + describe(t));
            return;
        }
        if (hmi == null) {
            observerStatus("HMIService=null");
            return;
        }

        int choiceId = resolveNavViewSizeChoiceId();
        if (choiceId < 0) {
            observerStatus("NAV_VIEW_SIZE_CHOICE id unresolved");
            return;
        }

        boolean small;
        String choiceClass;
        int choiceValue;
        try {
            Object model = invokeInt(hmi, "getModel", choiceId);
            if (model == null) {
                observerStatus("NAV_VIEW_SIZE_CHOICE model=null");
                return;
            }
            choiceClass = model.getClass().getName();
            Object value = invokeNoArg(model, "getValue");
            if (!(value instanceof Integer)) {
                observerStatus("NAV_VIEW_SIZE_CHOICE value non-int class=" + choiceClass);
                return;
            }
            choiceValue = ((Integer)value).intValue();
            small = choiceValue == 1;
            setViewAreaMode(small ? VIEWAREA_SMALLSCREEN : VIEWAREA_FULLSCREEN);
        } catch (Throwable t) {
            observerStatus("NAV_VIEW_SIZE_CHOICE read failed: " + describe(t));
            return;
        }

        String layoutName = "unknown";
        int smallDx = 0;
        int smallDy = 0;
        try {
            Object terminal = invokeInt(hmi, "getHMITerminal", TERMINAL_CLUSTER);
            if (terminal == null) {
                observerStatus("getHMITerminal(1)=null; choice=" + choiceValue
                    + " class=" + choiceClass);
                return;
            }
            Object layout = invokeNoArg(terminal, "getLayout");
            if (layout == null) {
                observerStatus("terminal1 layout=null; choice=" + choiceValue
                    + " class=" + choiceClass);
                return;
            }
            layoutName = layout.getClass().getName();
            Method getInt = layout.getClass().getMethod(
                "getIntegerConstant", new Class[]{Integer.TYPE});
            smallDx = ((Integer)getInt.invoke(
                layout, new Object[]{new Integer(80)})).intValue();
            smallDy = ((Integer)getInt.invoke(
                layout, new Object[]{new Integer(81)})).intValue();
        } catch (Throwable t) {
            observerStatus("terminal/layout read failed: " + describe(t)
                + " choice=" + choiceValue + " class=" + choiceClass);
            return;
        }

        String lower = layoutName.toLowerCase();
        boolean sport = lower.indexOf("sport") >= 0 || smallDx != 0 || smallDy != 0;
        String layout = sport ? "SPORT" : "CLASSIC";
        String view = small ? "SMALL" : "FULL";
        observerStatus("ok choice=" + choiceValue + " choiceClass=" + choiceClass
            + " layoutClass=" + layoutName + " c80=" + smallDx + " c81=" + smallDy
            + " -> " + layout + "_" + view);

        String signature = layout + "/" + view + "/" + layoutName + "/"
            + smallDx + "/" + smallDy
            + "/cp=" + (carPlaySessionActive ? "1" : "0")
            + "/rgi=" + (rgiPresentationActive ? "1" : "0");
        if (!signature.equals(lastStateSignature)) {
            lastStateSignature = signature;
            if (writeHmiState(layout, view, layoutName, smallDx, smallDy)) {
                diag("state published: " + layout + "_" + view
                    + " layoutClass=" + layoutName
                    + " c80=" + smallDx + " c81=" + smallDy);
            }
        }
    }

    private static void pollContextPolicy() {
        String mode = readContextMode();
        if (!mode.equals(lastContextMode)) {
            diag("context mode " + lastContextMode + " -> " + mode);
            lastContextMode = mode;
        }
        if (!MODE_JAVA80.equals(mode)) return;

        boolean baseActive = new File(BASEVIDEO_ACTIVE_FILE).exists();
        boolean baseReady = new File(BASEVIDEO_READY_FILE).exists();
        boolean wantComposite = (baseActive && baseReady) || rgiPresentationActive;

        if (!wantComposite) {
            if (ownershipIntent || compositeApplied) {
                ownershipIntent = false;
                Object dm = displayManager();
                boolean ok = dm != null && selectContext(dm, CTX_STOCK, "release");
                compositeApplied = false;
                contextWriteFailures = 0;
                if (ok) {
                    if (!verifyContext(dm, CTX_STOCK, "release")) {
                        diag("CTX74_VERIFY_WARN desired=74");
                    }
                    geometryReapply("ctx74-release");
                    diag("ownership released -> ctx74");
                }
            }
            return;
        }

        long now = nowMs();
        if (now < circuitOpenUntilMs) return;

        ownershipIntent = true;
        Object dm = displayManager();
        if (dm == null) {
            contextFailure("DisplayManager unavailable");
            return;
        }

        if (!compositeApplied) {
            int actual = currentContext(dm);
            diag("ownership acquire requested; base=" + (baseActive ? "1" : "0")
                + "/" + (baseReady ? "1" : "0")
                + " rgi=" + (rgiPresentationActive ? "1" : "0")
                + " actual=" + actual);

            String verifyReason = "already-active";
            if (actual != CTX_COMPOSITE) {
                if (!selectContext(dm, CTX_BOUNCE, "enter-bounce")) {
                    contextFailure("ctx72 bounce failed");
                    return;
                }
                sleep(BOUNCE_MS);
                if (!ownershipIntent) return;
                if (!selectContext(dm, CTX_COMPOSITE, "enter-composite")) {
                    contextFailure("ctx80 enter failed");
                    return;
                }
                verifyReason = "enter-composite";
            }

            if (!verifyContext(dm, CTX_COMPOSITE, verifyReason)) {
                contextFailure("ctx80 readback verification failed");
                return;
            }

            compositeApplied = true;
            contextWriteFailures = 0;
            lastReconcileMs = nowMs();
            geometryReapply("ctx80-acquired");
            diag("ownership acquired -> ctx80 verified=1");
            return;
        }

        now = nowMs();
        if (now - lastReconcileMs < RECONCILE_MS) return;
        lastReconcileMs = now;

        int actual = currentContext(dm);
        if (actual >= 0 && actual != CTX_COMPOSITE) {
            diag("physical context drift actual=" + actual
                + " desired=80 -> Java reconcile");
            if (!selectContext(dm, CTX_COMPOSITE, "reconcile")) {
                contextFailure("ctx80 reconcile failed");
                return;
            }
            if (!verifyContext(dm, CTX_COMPOSITE, "reconcile")) {
                contextFailure("ctx80 reconcile readback failed");
                return;
            }
            contextWriteFailures = 0;
            geometryReapply("ctx80-reconcile");
        }
    }

    private static Object displayManager() {
        try {
            Object fw = frameworkAccess;
            if (fw == null) return null;
            Object hmi = invokeNoArg(fw, "getHMIService");
            if (hmi == null) return null;
            return invokeNoArg(hmi, "getDisplayManager");
        } catch (Throwable t) {
            diag("DisplayManager lookup failed: " + describe(t));
            return null;
        }
    }

    private static int currentContext(Object dm) {
        if (dm == null) return -1;
        try {
            Method m = dm.getClass().getMethod(
                "getCurrentContextID", new Class[]{Integer.TYPE});
            Object value = m.invoke(dm, new Object[]{new Integer(TERMINAL_CLUSTER)});
            if (!(value instanceof Integer)) {
                diag("currentContext read returned non-int");
                return -1;
            }
            return ((Integer)value).intValue();
        } catch (Throwable t) {
            diag("currentContext read failed: " + describe(t));
            return -1;
        }
    }

    private static boolean selectContext(Object dm, int context, String reason) {
        if (dm == null) return false;
        try {
            Method[] methods = dm.getClass().getMethods();
            Method target = null;
            int i;
            for (i = 0; i < methods.length; ++i) {
                Method m = methods[i];
                if (!"switchContext".equals(m.getName())) continue;
                Class[] p = m.getParameterTypes();
                if (p.length == 3 && p[0] == Integer.TYPE && p[1] == Integer.TYPE) {
                    target = m;
                    break;
                }
            }
            if (target == null) {
                diag("ERROR switchContext(int,int,*) method not found");
                return false;
            }
            diag(reason + " -> ctx" + context);
            target.invoke(dm, new Object[]{
                new Integer(context),
                new Integer(TERMINAL_CLUSTER),
                null
            });
            return true;
        } catch (Throwable t) {
            diag("ERROR switch ctx" + context + " failed: " + describe(t));
            return false;
        }
    }

    private static boolean verifyContext(Object dm, int desired, String reason) {
        int actual = -1;
        int attempt;
        for (attempt = 1; attempt <= VERIFY_ATTEMPTS; ++attempt) {
            actual = currentContext(dm);
            if (actual == desired) {
                if (desired == CTX_COMPOSITE) {
                    diag("CTX80_OBSERVED actual=80 desired=80 reason=" + reason
                        + " attempts=" + attempt
                        + " source=IDisplayManager.getCurrentContextID");
                } else {
                    diag("CTX_OBSERVED actual=" + actual + " desired=" + desired
                        + " reason=" + reason + " attempts=" + attempt);
                }
                return true;
            }
            if (attempt < VERIFY_ATTEMPTS) sleep(VERIFY_STEP_MS);
        }
        if (desired == CTX_COMPOSITE) {
            diag("CTX80_VERIFY_FAIL actual=" + actual + " desired=80 reason=" + reason
                + " attempts=" + VERIFY_ATTEMPTS);
        } else {
            diag("CTX_VERIFY_FAIL actual=" + actual + " desired=" + desired
                + " reason=" + reason + " attempts=" + VERIFY_ATTEMPTS);
        }
        return false;
    }

    private static void contextFailure(String reason) {
        ++contextWriteFailures;
        diag("context failure " + contextWriteFailures + "/"
            + CONTEXT_FAILURE_LIMIT + ": " + reason);
        if (contextWriteFailures < CONTEXT_FAILURE_LIMIT) return;
        ownershipIntent = false;
        compositeApplied = false;
        circuitOpenUntilMs = nowMs() + CIRCUIT_BREAKER_MS;
        contextWriteFailures = 0;
        diag("context circuit breaker OPEN for " + CIRCUIT_BREAKER_MS
            + " ms; ownership released");
    }

    private static int resolveNavViewSizeChoiceId() {
        if (navViewSizeChoiceResolved) return navViewSizeChoiceId;
        navViewSizeChoiceResolved = true;
        try {
            Class bank = Class.forName("de.audi.atip.model.ICoreNaviModelBank");
            Field f = bank.getField("NAV_VIEW_SIZE_CHOICE");
            navViewSizeChoiceId = f.getInt(null);
        } catch (Throwable t) {
            navViewSizeChoiceId = -1;
            diag("NAV_VIEW_SIZE_CHOICE reflection failed: " + describe(t));
        }
        return navViewSizeChoiceId;
    }

    private static Object invokeNoArg(Object target, String name) throws Exception {
        if (target == null) return null;
        Method m = target.getClass().getMethod(name, new Class[0]);
        return m.invoke(target, new Object[0]);
    }

    private static Object invokeInt(Object target, String name, int value)
        throws Exception {
        if (target == null) return null;
        Method m = target.getClass().getMethod(name, new Class[]{Integer.TYPE});
        return m.invoke(target, new Object[]{new Integer(value)});
    }

    private static void geometryReapply(String reason) {
        if (geometryClassMissing) return;
        try {
            Class c = Class.forName("com.luka.carplay.cluster.ClusterLayerController");
            Method m = c.getMethod("reapply", new Class[0]);
            m.invoke(null, new Object[0]);
        } catch (ClassNotFoundException e) {
            geometryClassMissing = true;
        } catch (NoSuchMethodException e) {
            geometryClassMissing = true;
        } catch (Throwable t) {
            diag("WARN geometry reapply failed reason=" + reason + ": " + describe(t));
        }
    }

    private static boolean writeHmiState(String layout, String view,
                                         String layoutName,
                                         int smallDx, int smallDy) {
        File tmp = new File(HMI_STATE_FILE + ".tmp");
        File dst = new File(HMI_STATE_FILE);
        FileOutputStream out = null;
        try {
            out = new FileOutputStream(tmp);
            String text = "layout=" + layout + "\n"
                + "view=" + view + "\n"
                + "layout_name=" + layoutName + "\n"
                + "small_stage_dx=" + smallDx + "\n"
                + "small_stage_dy=" + smallDy + "\n"
                + "carplay_session=" + (carPlaySessionActive ? "1" : "0") + "\n"
                + "rgi_active=" + (rgiPresentationActive ? "1" : "0") + "\n";
            out.write(text.getBytes("UTF-8"));
            out.flush();
            out.close();
            out = null;
            if (dst.exists() && !dst.delete()) {
                diag("WARN could not delete old state file before replace");
            }
            if (!tmp.renameTo(dst)) {
                copyFile(tmp, dst);
                tmp.delete();
            }
            return true;
        } catch (Throwable t) {
            diag("ERROR state write failed: " + describe(t));
            try { if (out != null) out.close(); } catch (Throwable ignored) {}
            return false;
        }
    }

    private static void observerStatus(String status) {
        if (status.equals(lastObserverStatus)) return;
        lastObserverStatus = status;
        diag("observer: " + status);
    }

    private static String readContextMode() {
        BufferedReader reader = null;
        try {
            File f = new File(CONTEXT_MODE_FILE);
            if (!f.exists()) return MODE_JAVA80;
            reader = new BufferedReader(
                new InputStreamReader(new FileInputStream(f), "UTF-8"));
            String line = reader.readLine();
            reader.close();
            reader = null;
            if (line != null && MODE_JAVA80.equals(
                line.trim().toUpperCase())) return MODE_JAVA80;
        } catch (Throwable t) {
            try { if (reader != null) reader.close(); }
            catch (Throwable ignored) {}
            diag("context mode read failed; default JAVA80: " + describe(t));
        }
        return MODE_JAVA80;
    }

    private static void writeStartedMarker() {
        FileOutputStream out = null;
        try {
            out = new FileOutputStream(STARTED_FILE);
            String text = "started=1\n"
                + "time_ms=" + nowMs() + "\n"
                + "mode=JAVA80\n"
                + "ctx=80\n"
                + "ctx_readback=getCurrentContextID(1)\n";
            out.write(text.getBytes("UTF-8"));
            out.close();
        } catch (Throwable t) {
            try { if (out != null) out.close(); } catch (Throwable ignored) {}
        }
    }

    private static void diag(String text) {
        synchronized (DIAG_LOCK) {
            FileOutputStream out = null;
            try {
                File f = new File(DIAG_FILE);
                if (f.exists() && f.length() > DIAG_MAX_BYTES) {
                    FileOutputStream reset = new FileOutputStream(f, false);
                    reset.write(("--- log reset at " + nowMs() + " ---\n")
                        .getBytes("UTF-8"));
                    reset.close();
                }
                out = new FileOutputStream(f, true);
                String line = nowMs() + " " + text + "\n";
                out.write(line.getBytes("UTF-8"));
                out.close();
            } catch (Throwable ignored) {
                try { if (out != null) out.close(); } catch (Throwable ignored2) {}
            }
        }
    }

    private static String describe(Throwable t) {
        if (t == null) return "unknown";
        String m = t.getMessage();
        return t.getClass().getName() + (m == null ? "" : ": " + m);
    }

    private static void copyFile(File src, File dst) throws Exception {
        FileInputStream in = new FileInputStream(src);
        FileOutputStream out = new FileOutputStream(dst);
        byte[] buf = new byte[512];
        int n;
        while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        in.close();
        out.close();
    }

    private static long nowMs() {
        return System.currentTimeMillis();
    }

    private static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}

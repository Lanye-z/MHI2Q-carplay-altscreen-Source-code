package com.luka.carplay.routeguidance;

import de.audi.atip.interapp.combi.bap.navi.CombiBAPServiceNavi;
import de.audi.tghu.navi.app.Navigation;
import de.audi.tghu.navi.app.cluster.ClusterService;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;

public final class BAPGateReinstallTest {
    private static void require(boolean value, String message) {
        if (!value) throw new RuntimeException(message);
    }

    private static CombiBAPServiceNavi fakeService() {
        return (CombiBAPServiceNavi)Proxy.newProxyInstance(
            BAPGateReinstallTest.class.getClassLoader(),
            new Class[] { CombiBAPServiceNavi.class },
            new InvocationHandler() {
                public Object invoke(Object proxy, Method method, Object[] args) {
                    Class type = method.getReturnType();
                    if (type == Boolean.TYPE) return Boolean.FALSE;
                    if (type == Integer.TYPE) return new Integer(0);
                    if (type == Long.TYPE) return new Long(0L);
                    return null;
                }
            });
    }

    public static void main(String[] args) throws Exception {
        CombiBAPServiceNavi first = fakeService();
        ClusterService cluster = new ClusterService(first);
        Navigation.setInstance(new Navigation(cluster));

        BAPBridge bridge = new BAPBridge();
        require(bridge.init(first), "BAPBridge init failed");
        require(cluster.getCombiBAPListenerCombiService() instanceof GatedCombiService,
            "initial gate not installed");

        bridge.onStart();
        GatedCombiService firstGate =
            (GatedCombiService)cluster.getCombiBAPListenerCombiService();
        require(firstGate.isLowerBarBlocked(), "initial gate not blocked");

        CombiBAPServiceNavi replacement = fakeService();
        cluster.setCombiBAPListenerCombiService(replacement);

        bridge.update(new RouteGuidance.State());
        require(cluster.getCombiBAPListenerCombiService() instanceof GatedCombiService,
            "gate not reinstalled after listener replacement");
        GatedCombiService secondGate =
            (GatedCombiService)cluster.getCombiBAPListenerCombiService();
        require(secondGate != firstGate, "detached gate was reused");
        require(secondGate.real == replacement, "replacement stock listener not wrapped");
        require(secondGate.isLowerBarBlocked(), "reinstalled gate not blocked");

        bridge.onShutdown();
        require(!secondGate.isLowerBarBlocked(), "gate not released on shutdown");

        Navigation.setInstance(null);
        System.out.println("BAP_GATE_REINSTALL=PASS");
    }
}

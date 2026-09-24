package com.luka.carplay.routeguidance;

import de.audi.atip.interapp.combi.bap.navi.CombiBAPServiceNavi;
import de.audi.tghu.navi.app.Navigation;
import de.audi.tghu.navi.app.cluster.ClusterService;
import java.lang.reflect.*;

public final class BAPPresentationContextTest {
    private static void require(boolean value,String message){
        if(!value)throw new RuntimeException(message);
    }
    private static final class Calls implements InvocationHandler {
        int rgOn,rgOff,rgType,descriptor,nextDistance,exitView,lane,maneuverState,fct22;
        int lastTimeType=-1;
        public Object invoke(Object p,Method m,Object[] a){
            String n=m.getName();
            if(n.equals("updateRGStatus")){
                int v=((Integer)a[0]).intValue();
                if(v==1)rgOn++; else if(v==0)rgOff++;
            } else if(n.equals("updateActiveRGType")) rgType++;
            else if(n.equals("updateManeuverDescriptor")) descriptor++;
            else if(n.equals("updateDistanceToNextManeuver")) nextDistance++;
            else if(n.equals("updateExitView")) exitView++;
            else if(n.equals("updateLaneGuidance")) lane++;
            else if(n.equals("updateManeuverState")) maneuverState++;
            else if(n.equals("updateTimeToDestination")){
                fct22++; lastTimeType=((Integer)a[0]).intValue();
            }
            Class t=m.getReturnType();
            if(t==Boolean.TYPE)return Boolean.FALSE;
            if(t==Integer.TYPE)return new Integer(0);
            if(t==Long.TYPE)return new Long(0L);
            return null;
        }
    }
    public static void main(String[] args)throws Exception{
        Calls calls=new Calls();
        CombiBAPServiceNavi raw=(CombiBAPServiceNavi)Proxy.newProxyInstance(
            BAPPresentationContextTest.class.getClassLoader(),
            new Class[]{CombiBAPServiceNavi.class},calls);
        ClusterService cluster=new ClusterService(raw);
        Navigation.setInstance(new Navigation(cluster));

        BAPBridge bridge=new BAPBridge();
        require(bridge.init(raw),"init failed");
        bridge.onStart();

        require(cluster.getTestDsiContainer().isRgActive(),"OEM rgActive not forced");
        require(cluster.isRgiDataValidForTest(),"OEM rgiDataValid not forced");
        require(cluster.getCombiBAPListenerCombiService() instanceof GatedCombiService,
            "presentation gate missing");
        GatedCombiService gate=(GatedCombiService)cluster.getCombiBAPListenerCombiService();
        require(gate.isPresentationContextBlocked(),"presentation fields not blocked");
        require(calls.rgOn>=1&&calls.rgType>=1,"RGStatus/ActiveRGType sync missing");
        require(calls.descriptor>=1&&calls.nextDistance>=1&&calls.exitView>=1,
            "sync(0) neutral group incomplete");
        require(calls.lane>=1&&calls.maneuverState>=1,
            "neutral lane/maneuver state missing");

        RouteGuidance.State eta=new RouteGuidance.State();
        eta.dirtyMask=RouteGuidance.State.DIRTY_ETA;
        eta.etaSeconds=2000000000;
        bridge.update(eta);
        require(calls.fct22>=1,"Fct22 not published");
        require(calls.lastTimeType==1,"Fct22 must remain absolute ETA Type1");

        bridge.onShutdown();
        require(!cluster.getTestDsiContainer().isRgActive(),"OEM rgActive not restored");
        require(!cluster.isRgiDataValidForTest(),"OEM rgiDataValid not restored");
        require(cluster.getCombiBAPListenerCombiService()==raw,"stock listener not restored");
        require(calls.rgOff>=1,"RGStatus(0) teardown missing");

        Navigation.setInstance(null);
        System.out.println("BAP_PRESENTATION_CONTEXT=PASS policy=MINIMAL_NEUTRAL_SYNC_F17_39_23_18_49");
    }
}

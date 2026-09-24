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
        int rgStatus,rgType,descriptor,nextDistance,exitView,lane,maneuverState;
        int fct19,fct21,fct22;
        int lastTimeType=-1;
        public Object invoke(Object p,Method m,Object[] a){
            String n=m.getName();
            if(n.equals("updateRGStatus")) rgStatus++;
            else if(n.equals("updateActiveRGType")) rgType++;
            else if(n.equals("updateManeuverDescriptor")) descriptor++;
            else if(n.equals("updateDistanceToNextManeuver")) nextDistance++;
            else if(n.equals("updateExitView")) exitView++;
            else if(n.equals("updateLaneGuidance")) lane++;
            else if(n.equals("updateManeuverState")) maneuverState++;
            else if(n.equals("updateCurrentPositionInfo")) fct19++;
            else if(n.equals("updateDistanceToDestination")) fct21++;
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

        require(!cluster.getTestDsiContainer().isRgActive(),
            "wrong-window regression: rgActive must remain untouched");
        require(!cluster.isRgiDataValidForTest(),
            "wrong-window regression: rgiDataValid must remain untouched");
        require(cluster.getCombiBAPListenerCombiService()==raw,
            "gate should stay lazy until a lower-bar field is owned");

        RouteGuidance.State s=new RouteGuidance.State();
        s.dirtyMask=RouteGuidance.State.DIRTY_CURRENT_ROAD
            |RouteGuidance.State.DIRTY_DIST_DEST
            |RouteGuidance.State.DIRTY_ETA;
        s.currentRoad="CarPlay Road";
        s.distDestM=3200;
        s.etaSeconds=2000000000;
        bridge.update(s);

        require("CarPlay Road".equals(cluster.getTestCurrentStreet()),
            "KOMO current street not updated");
        require(cluster.getTestDistanceMeters()==3200,
            "KOMO distance not updated");
        require(cluster.isTestArrivalValid(),
            "KOMO ETA not marked valid");
        require(cluster.getTestArrivalMillis()==2000000000L*1000L,
            "KOMO ETA must receive UTC milliseconds");
        require(cluster.getTestFollowInfoFlushCount()>=2,
            "KOMO follow-info not flushed");
        require(calls.fct19>=1&&calls.fct21>=1&&calls.fct22>=1,
            "BAP lower-bar fields not retained");
        require(calls.lastTimeType==1,"Fct22 must remain absolute ETA Type1");

        require(calls.rgStatus==0&&calls.rgType==0&&calls.descriptor==0
            &&calls.nextDistance==0&&calls.exitView==0
            &&calls.lane==0&&calls.maneuverState==0,
            "wrong-window regression: RGI/maneuver presentation call emitted");
        require(!cluster.getTestDsiContainer().isRgActive(),
            "rgActive changed after gray-bar update");
        require(!cluster.isRgiDataValidForTest(),
            "rgiDataValid changed after gray-bar update");

        bridge.onShutdown();
        require(cluster.getCombiBAPListenerCombiService()==raw,
            "stock listener not restored");
        require(calls.rgStatus==0,"shutdown must not synthesize RGStatus");

        Navigation.setInstance(null);
        System.out.println(
            "BAP_PRESENTATION_CONTEXT=PASS policy=KOMO_GRAY_BAR_NO_RGI_PRESENTATION wrong_window=BLOCKED");
    }
}

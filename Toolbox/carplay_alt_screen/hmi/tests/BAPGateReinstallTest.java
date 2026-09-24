package com.luka.carplay.routeguidance;

import de.audi.atip.interapp.combi.bap.navi.CombiBAPServiceNavi;
import de.audi.tghu.navi.app.Navigation;
import de.audi.tghu.navi.app.cluster.ClusterService;
import java.lang.reflect.*;

public final class BAPGateReinstallTest {
    private static void require(boolean v,String m){if(!v)throw new RuntimeException(m);}

    private static final class Calls implements InvocationHandler {
        int rgOn;
        int rgOff;
        int distanceToDestination;
        int timeToDestination;
        int currentPosition;

        public Object invoke(Object p,Method m,Object[] a){
            String n=m.getName();
            if(n.equals("updateRGStatus")){
                int v=((Integer)a[0]).intValue();
                if(v==1)rgOn++; else if(v==0)rgOff++;
            } else if(n.equals("updateDistanceToDestination")){
                distanceToDestination++;
            } else if(n.equals("updateTimeToDestination")){
                timeToDestination++;
            } else if(n.equals("updateCurrentPositionInfo")){
                currentPosition++;
            }
            Class t=m.getReturnType();
            if(t==Boolean.TYPE)return Boolean.FALSE;
            if(t==Integer.TYPE)return new Integer(0);
            if(t==Long.TYPE)return new Long(0L);
            return null;
        }
    }

    private static CombiBAPServiceNavi fakeService(Calls calls){
        return (CombiBAPServiceNavi)Proxy.newProxyInstance(
            BAPGateReinstallTest.class.getClassLoader(),
            new Class[]{CombiBAPServiceNavi.class},calls);
    }

    private static RouteGuidance.State field(int d){
        RouteGuidance.State s=new RouteGuidance.State();
        s.dirtyMask=d;
        return s;
    }

    public static void main(String[] a)throws Exception{
        Calls firstCalls=new Calls();
        CombiBAPServiceNavi first=fakeService(firstCalls);
        ClusterService cluster=new ClusterService(first);
        Navigation.setInstance(new Navigation(cluster));
        BAPBridge bridge=new BAPBridge();

        require(bridge.init(first),"init failed");
        require(cluster.getCombiBAPListenerCombiService()==first,"init installed gate");
        bridge.onStart();
        require(cluster.getCombiBAPListenerCombiService() instanceof GatedCombiService,
            "start did not install presentation gate");
        GatedCombiService startGate=(GatedCombiService)cluster.getCombiBAPListenerCombiService();
        require(startGate.isPresentationContextBlocked(),"presentation context not blocked");

        RouteGuidance.State road=field(RouteGuidance.State.DIRTY_CURRENT_ROAD);
        road.currentRoad="CarPlay Road";
        bridge.update(road);
        GatedCombiService g1=(GatedCombiService)cluster.getCombiBAPListenerCombiService();
        require(g1.isFct19Blocked(),"19 not owned");
        require(!g1.isFct21Blocked()&&!g1.isFct22Blocked(),"unowned fields blocked");
        require(g1.isPresentationContextBlocked(),"presentation gate lost");
        require(firstCalls.currentPosition>0,"initial road was not published to first service");

        Calls replacementCalls=new Calls();
        CombiBAPServiceNavi replacement=fakeService(replacementCalls);
        cluster.setCombiBAPListenerCombiService(replacement);

        RouteGuidance.State dist=field(RouteGuidance.State.DIRTY_DIST_DEST);
        dist.distDestM=1200;
        bridge.update(dist);

        GatedCombiService g2=(GatedCombiService)cluster.getCombiBAPListenerCombiService();
        require(g2!=g1&&g2.real==replacement,"replacement listener not wrapped");
        require(g2.isFct19Blocked()&&g2.isFct21Blocked()&&!g2.isFct22Blocked(),
            "ownership not preserved");
        require(g2.isPresentationContextBlocked(),"presentation context not preserved");
        require(replacementCalls.rgOn>0,
            "presentation sync was not replayed to replacement service");
        require(replacementCalls.distanceToDestination>0,
            "distance still published to detached service");

        RouteGuidance.State empty=field(RouteGuidance.State.DIRTY_CURRENT_ROAD);
        empty.currentRoad="";
        bridge.update(empty);
        require(!g2.isFct19Blocked()&&g2.isFct21Blocked(),"empty road did not release 19");

        RouteGuidance.State eta=field(RouteGuidance.State.DIRTY_ETA);
        eta.etaSeconds=2000000000;
        bridge.update(eta);
        require(g2.isFct22Blocked(),"eta did not acquire 22");
        require(replacementCalls.timeToDestination>0,
            "ETA still published to detached service");

        RouteGuidance.State nod=field(RouteGuidance.State.DIRTY_DIST_DEST);
        nod.distDestM=0;
        bridge.update(nod);
        require(!g2.isFct21Blocked()&&g2.isFct22Blocked(),"zero distance release wrong");

        RouteGuidance.State noe=field(
            RouteGuidance.State.DIRTY_ETA|RouteGuidance.State.DIRTY_TIME_REMAINING);
        noe.etaSeconds=-1;
        noe.timeRemainingSeconds=-1L;
        bridge.update(noe);
        require(cluster.getCombiBAPListenerCombiService()==g2,
            "presentation context should keep gate installed");

        bridge.update(road);
        require(cluster.getCombiBAPListenerCombiService() instanceof GatedCombiService,
            "reacquire failed");

        bridge.onShutdown();
        require(cluster.getCombiBAPListenerCombiService()==replacement,
            "shutdown did not restore replacement stock listener");
        require(replacementCalls.rgOff>0,
            "shutdown RGStatus(0) did not reach replacement service");

        Navigation.setInstance(null);
        System.out.println(
            "BAP_GATE_REINSTALL=PASS policy=LAZY_PER_FIELD_FAIL_OPEN current_service_refresh=YES");
    }
}

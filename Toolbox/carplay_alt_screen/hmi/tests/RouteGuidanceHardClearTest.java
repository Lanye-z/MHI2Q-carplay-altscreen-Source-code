package com.luka.carplay.routeguidance;
import com.luka.carplay.framework.CarplayBus;
import java.lang.reflect.Field;
public final class RouteGuidanceHardClearTest {
    private static void req(boolean b,String m){if(!b)throw new RuntimeException(m);}
    private static Field f(String n)throws Exception{Field x=RouteGuidance.class.getDeclaredField(n);x.setAccessible(true);return x;}
    private static RouteGuidance.State s(RouteGuidance r)throws Exception{return (RouteGuidance.State)f("state").get(r);}
    private static void feed(RouteGuidance r,String x)throws Exception{byte[] p=x.getBytes("UTF-8");r.onFrame(CarplayBus.EVT_RGD_UPDATE,0,p,p.length);}
    private static void cleared(RouteGuidance.State s,String w){req(s.routeState==0,w+" route");req(s.currentRoad==null,w+" road");req(s.distDestM==-1,w+" dist");req(s.etaSeconds==-1,w+" eta");req(s.timeRemainingSeconds==-1L,w+" rem");}
    public static void main(String[] a)throws Exception{
        RouteGuidance r=new RouteGuidance(); f("running").setBoolean(r,true);
        feed(r,"@routeguidance\nroute_state:n:1\nsource_supports_rg:n:1\ncurrent_road:s:Old\ndist_dest_m:n:4400\neta_seconds:n:2000000000\ntime_remaining_seconds:n:900\n");
        req(f("rgActive").getBoolean(r),"not active"); req(s(r).hasUsefulLowerBarData(),"cache empty");
        feed(r,"@routeguidance\nsource_supports_rg:n:0\n"); cleared(s(r),"source0"); req(!f("rgActive").getBoolean(r),"source0 owns");
        feed(r,"@routeguidance\nsource_supports_rg:n:1\n"); req(!f("rgActive").getBoolean(r),"stale resurrection"); cleared(s(r),"reenable");
        feed(r,"@routeguidance\nroute_state:n:1\ncurrent_road:s:New\ndist_dest_m:n:1200\neta_seconds:n:2000001000\n");
        req(f("rgActive").getBoolean(r),"new route inactive");
        feed(r,"@routeguidance\nroute_state:n:0\n"); cleared(s(r),"route0"); req(!f("rgActive").getBoolean(r),"route0 owns");
        System.out.println("ROUTE_GUIDANCE_HARD_CLEAR=PASS");
    }
}

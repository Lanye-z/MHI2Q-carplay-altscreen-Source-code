package com.luka.carplay.routeguidance;
import com.luka.carplay.framework.CarplayBus;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
public final class AmapSoftInactiveTest {
    private static void req(boolean b,String m){if(!b)throw new RuntimeException(m);}
    private static Field own(String n)throws Exception{Field f=AmapRouteGuidance.class.getDeclaredField(n);f.setAccessible(true);return f;}
    private static Field base(String n)throws Exception{Field f=RouteGuidance.class.getDeclaredField(n);f.setAccessible(true);return f;}
    private static void feed(AmapRouteGuidance r,String s)throws Exception{byte[] p=s.getBytes("UTF-8");r.onFrame(CarplayBus.EVT_RGD_UPDATE,0,p,p.length);}
    public static void main(String[] a)throws Exception{
        AmapRouteGuidance r=new AmapRouteGuidance();
        base("running").setBoolean(r,true);
        feed(r,"@routeguidance\nroute_state:n:1\nsource_supports_rg:n:1\nvisible_in_app:n:1\nmaneuver_count:n:1\ncurrent_road:s:Road\ndist_dest_m:n:3000\neta_seconds:n:2000000000\n");
        req(base("rgActive").getBoolean(r),"baseline route inactive");
        feed(r,"@routeguidance\nroute_state:n:1\nsource_supports_rg:n:1\nvisible_in_app:n:0\nmaneuver_count:n:0\ncurrent_road:s:Road\ndist_dest_m:n:3000\neta_seconds:n:2000000000\n");
        req(own("softTimerRunning").getBoolean(r),"unknown-source behavior probe not armed");
        int gen=own("softGeneration").getInt(r);
        own("softDeadlineMs").setLong(r,System.currentTimeMillis()-1L);
        Method m=AmapRouteGuidance.class.getDeclaredMethod("runSoftTimer",new Class[]{Integer.TYPE});
        m.setAccessible(true);
        m.invoke(r,new Object[]{new Integer(gen)});
        req(!base("rgActive").getBoolean(r),"soft timeout retained lower-bar ownership");
        RouteGuidance.State st=(RouteGuidance.State)base("state").get(r);
        req(st.routeState==0,"soft timeout did not force route end");
        req(st.currentRoad==null&&st.distDestM==-1&&st.etaSeconds==-1,"soft timeout left stale lower-bar cache");
        System.out.println("AMAP_SOFT_INACTIVE_UNKNOWN_SOURCE=PASS");
    }
}

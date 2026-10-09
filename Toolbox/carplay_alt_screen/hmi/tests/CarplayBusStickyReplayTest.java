package com.luka.carplay.framework;
import java.lang.reflect.Method;
public final class CarplayBusStickyReplayTest {
    private static final class Capture implements CarplayBus.Listener {
        int count; int flags; String road;
        public void onFrame(int type,int f,byte[] p,int len) {
            count++; flags=f; road=CarplayBus.parseText(p,len).str("current_road",null);
        }
    }
    private static void req(boolean b,String m){if(!b)throw new RuntimeException(m);}
    private static void dispatch(CarplayBus b,String text,int seq)throws Exception{
        byte[] p=text.getBytes("UTF-8");
        Method m=CarplayBus.class.getDeclaredMethod("dispatch",
          new Class[]{Integer.TYPE,Integer.TYPE,byte[].class,Integer.TYPE,Integer.TYPE});
        m.setAccessible(true);
        m.invoke(b,new Object[]{new Integer(CarplayBus.EVT_RGD_UPDATE),
          new Integer(CarplayBus.FLAG_STICKY),p,new Integer(p.length),new Integer(seq)});
    }
    public static void main(String[] a)throws Exception{
        CarplayBus b=CarplayBus.getInstance(); b.off(CarplayBus.EVT_RGD_UPDATE);
        dispatch(b,"@routeguidance\ncurrent_road:s:Old Road\n",10);
        Capture x=new Capture(); b.on(CarplayBus.EVT_RGD_UPDATE,x);
        req(x.count==1,"late replay missing"); req("Old Road".equals(x.road),"wrong old replay");
        req((x.flags&CarplayBus.FLAG_REPLAY)!=0,"replay flag missing");
        dispatch(b,"@routeguidance\ncurrent_road:s:New Road\n",11);
        req(x.count==2&&"New Road".equals(x.road),"live frame missing");
        b.off(CarplayBus.EVT_RGD_UPDATE); Capture y=new Capture();
        b.on(CarplayBus.EVT_RGD_UPDATE,y);
        req(y.count==1&&"New Road".equals(y.road),"latest sticky not replayed");
        b.off(CarplayBus.EVT_RGD_UPDATE);
        System.out.println("CARPLAY_BUS_STICKY_REPLAY=PASS");
    }
}

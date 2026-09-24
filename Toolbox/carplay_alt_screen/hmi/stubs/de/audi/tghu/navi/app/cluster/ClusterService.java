package de.audi.tghu.navi.app.cluster;

import de.audi.atip.interapp.combi.bap.navi.CombiBAPServiceNavi;

/* Compile/test descriptor stub only; vehicle class is supplied by lsd.jxe/JAR patch. */
public class ClusterService {
    private CombiBAPServiceNavi service;
    private boolean rgiDataValid;
    private final TestDsiContainer dsi = new TestDsiContainer();

    public ClusterService() {}
    public ClusterService(CombiBAPServiceNavi value) { service = value; }

    public CombiBAPServiceNavi getCombiBAPListenerCombiService() { return service; }
    public void setCombiBAPListenerCombiService(CombiBAPServiceNavi value) { service = value; }

    public Object getDSIResponseContainer() { return dsi; }
    public void updateRGIString(short[] value) {
        rgiDataValid = value != null && value.length > 0;
    }
    public void updateRgActive(boolean value) {}
    public boolean isRgiDataValidForTest() { return rgiDataValid; }
    public TestDsiContainer getTestDsiContainer() { return dsi; }

    public static final class TestDsiContainer {
        private boolean rgActive;
        public boolean isRgActive() { return rgActive; }
        public void setRgActive(boolean value) { rgActive = value; }
    }
}

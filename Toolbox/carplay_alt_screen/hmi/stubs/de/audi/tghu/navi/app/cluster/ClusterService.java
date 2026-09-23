package de.audi.tghu.navi.app.cluster;

import de.audi.atip.interapp.combi.bap.navi.CombiBAPServiceNavi;

/* Compile/test descriptor stub only; vehicle class is supplied by lsd.jxe/JAR patch. */
public class ClusterService {
    private CombiBAPServiceNavi service;

    public ClusterService() {}
    public ClusterService(CombiBAPServiceNavi value) { service = value; }

    public CombiBAPServiceNavi getCombiBAPListenerCombiService() { return service; }
    public void setCombiBAPListenerCombiService(CombiBAPServiceNavi value) { service = value; }
}

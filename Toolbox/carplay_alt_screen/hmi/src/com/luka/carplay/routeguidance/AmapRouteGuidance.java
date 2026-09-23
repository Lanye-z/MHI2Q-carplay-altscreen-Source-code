/*
 * V3.3 compatibility shell.
 *
 * CarPlayHook historically constructs AmapRouteGuidance.  V3.3 intentionally
 * uses the same OEM lower-bar metadata path for Apple Maps, Amap and other RGI
 * providers, so no app-specific rendering policy remains here.
 */
package com.luka.carplay.routeguidance;

public final class AmapRouteGuidance extends RouteGuidance {
    public AmapRouteGuidance() { super(); }
}
